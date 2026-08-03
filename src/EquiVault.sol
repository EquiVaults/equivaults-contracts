// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20, IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {AssetRegistry} from "./AssetRegistry.sol";
import {ISwapRouter} from "./interfaces/ISwapRouter.sol";

/// @notice USDC-settled ERC-4626 vault holding a fixed basket of registered assets.
/// @dev Deposits buy the basket immediately through each asset's liquidity route; redemptions
/// withdraw the exact proportional share of every asset and let the user pick, per asset, between
/// receiving the token and selling it to USDC. Shares are non-transferable. A performance fee on
/// realized gain (0-20 %, immutable) is charged only at withdrawal, 90 % to the manager and 10 %
/// to the protocol treasury. If both price sources of any basket asset fail, this vault pauses.
/// The OpenZeppelin inflation-attack mitigation (virtual shares/assets via `_decimalsOffset`, set to
/// 6 for a stronger virtual-share buffer) is preserved.
contract EquiVault is ERC4626, ReentrancyGuard {
    using Math for uint256;
    using SafeERC20 for IERC20;

    uint16 public constant BPS_DENOMINATOR = 10_000;
    uint16 public constant MAX_BASKET_SIZE = 5;
    uint16 public constant MIN_WEIGHT_BPS = 500; // 5 %
    uint16 public constant MAX_FEE_BPS = 2_000; // 20 %
    uint16 public constant MAX_SLIPPAGE_BPS = 3_000; // 30 %
    uint16 public constant MANAGER_FEE_SHARE_BPS = 9_000; // 90 %

    address public immutable manager;
    uint16 public immutable feeBps;
    uint16 public immutable maxSlippageBps;
    AssetRegistry public immutable registry;
    uint8 private immutable _usdcDecimals;

    address[] private _basketAssets;
    uint16[] private _basketWeightsBps;

    /// @notice Cumulative USDC contributed by each shareholder, minus the realized cost of redeemed shares.
    /// @dev Average cost basis per share = costBasis[account] / balanceOf(account); shares are
    /// non-transferable so this mapping always matches the share balance it accounts for.
    mapping(address account => uint256 amount) public costBasis;

    error InvalidAddress();
    error InvalidFee(uint16 feeBps);
    error InvalidSlippage(uint16 slippageBps);
    error InvalidBasketSize(uint256 size);
    error BasketLengthMismatch(uint256 assets, uint256 weights);
    error InvalidWeight(uint16 weightBps);
    error WeightsMustSumTo10000(uint256 sum);
    error DuplicateAsset(address asset);
    error SettlementAssetInBasket(address asset);
    error AssetNotRegistered(address asset);
    error MinOutsLengthMismatch(uint256 expected, uint256 actual);
    error SellFlagsLengthMismatch(uint256 expected, uint256 actual);
    error VaultPaused();
    error SharesNonTransferable();

    event PerformanceFeeCollected(
        address indexed manager,
        address indexed treasury,
        uint256 amount,
        uint256 managerShare,
        uint256 treasuryShare
    );

    constructor(
        IERC20 usdc,
        AssetRegistry registry_,
        address manager_,
        address[] memory assets,
        uint16[] memory weightsBps,
        uint16 feeBps_,
        uint16 maxSlippageBps_
    ) ERC4626(usdc) ERC20("EquiVault", "EQV") {
        if (manager_ == address(0)) revert InvalidAddress();
        if (address(registry_) == address(0)) revert InvalidAddress();
        if (feeBps_ > MAX_FEE_BPS) revert InvalidFee(feeBps_);
        if (maxSlippageBps_ > MAX_SLIPPAGE_BPS) revert InvalidSlippage(maxSlippageBps_);

        uint256 n = assets.length;
        if (n == 0 || n > MAX_BASKET_SIZE) revert InvalidBasketSize(n);
        if (n != weightsBps.length) revert BasketLengthMismatch(n, weightsBps.length);

        uint256 weightSum;
        for (uint256 i = 0; i < n; ++i) {
            address asset = assets[i];
            if (asset == address(0)) revert InvalidAddress();
            if (asset == address(usdc)) revert SettlementAssetInBasket(asset);
            for (uint256 j = 0; j < i; ++j) {
                if (assets[j] == asset) revert DuplicateAsset(asset);
            }
            bool registered;
            try registry_.assetConfig(asset) returns (AssetRegistry.AssetConfig memory config) {
                registered = true;
                // Allow the registered liquidity route to pull settlement and basket tokens on swap.
                SafeERC20.forceApprove(usdc, config.liquidityRoute, type(uint256).max);
                SafeERC20.forceApprove(IERC20(asset), config.liquidityRoute, type(uint256).max);
            } catch {}
            if (!registered) revert AssetNotRegistered(asset);

            uint16 weight = weightsBps[i];
            if (weight < MIN_WEIGHT_BPS) revert InvalidWeight(weight);
            weightSum += weight;

            _basketAssets.push(asset);
            _basketWeightsBps.push(weight);
        }
        if (weightSum != BPS_DENOMINATOR) revert WeightsMustSumTo10000(weightSum);

        manager = manager_;
        registry = registry_;
        feeBps = feeBps_;
        maxSlippageBps = maxSlippageBps_;

        // Settlement asset decimals drive the NAV scale: `priceE18` follows the USD/Chainlink
        // convention (dollars per whole token at 1e18), so USDC wei value needs rescaling.
        (bool ok, uint8 usdcDecimals) = SafeERC20.tryGetDecimals(usdc);
        _usdcDecimals = ok ? usdcDecimals : 18;
    }

    // ---------------------------------------------------------------------
    // ERC-4626 overrides
    // ---------------------------------------------------------------------

    /// @notice NAV of the vault expressed in USDC: each basket asset valued at its live registry
    /// price (primary oracle, then fallback). The settlement balance is deliberately excluded:
    /// exits distribute only the basket, so counting uninvested USDC would break the link between
    /// share price and redemption value (e.g. under a donation attack).
    function totalAssets() public view override returns (uint256) {
        uint256 nav;
        uint256 n = _basketAssets.length;
        for (uint256 i = 0; i < n; ++i) {
            address a = _basketAssets[i];
            nav += _valueUsdc(a, IERC20(a).balanceOf(address(this)));
        }
        return nav;
    }

    /// @dev Stronger inflation-attack mitigation: virtual shares/assets scale with `10 ** _decimalsOffset()`
    /// (OpenZeppelin mechanism, offset 6 as in the historical v4.9 default). Keeps the vault usable for
    /// later depositors even after a deliberate donation.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256 shares) {
        _requireCanDeposit();
        shares = previewDeposit(assets);
        _enter(_msgSender(), receiver, assets, shares, new uint256[](0));
    }

    /// @dev `minAmountsOut` applies per basket asset in order; 0 falls back to the vault default bound.
    function deposit(uint256 assets, address receiver, uint256[] calldata minAmountsOut)
        external
        nonReentrant
        returns (uint256 shares)
    {
        _requireCanDeposit();
        shares = previewDeposit(assets);
        _enter(_msgSender(), receiver, assets, shares, minAmountsOut);
    }

    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256 assets) {
        _requireCanDeposit();
        assets = previewMint(shares);
        _enter(_msgSender(), receiver, assets, shares, new uint256[](0));
    }

    /// @dev `minAmountsOut` applies per basket asset in order; 0 falls back to the vault default bound.
    function mint(uint256 shares, address receiver, uint256[] calldata minAmountsOut)
        external
        nonReentrant
        returns (uint256 assets)
    {
        _requireCanDeposit();
        assets = previewMint(shares);
        _enter(_msgSender(), receiver, assets, shares, minAmountsOut);
    }

    function withdraw(uint256 assets, address receiver, address owner)
        public
        override
        nonReentrant
        returns (uint256 shares)
    {
        _requireCanExit();
        shares = previewWithdraw(assets);
        _exit(_msgSender(), receiver, owner, shares, new bool[](0));
    }

    /// @dev `sellTokens[i]` = true sells asset i to USDC, false transfers the token to `receiver`.
    function withdraw(uint256 assets, address receiver, address owner, bool[] calldata sellTokens)
        external
        nonReentrant
        returns (uint256 shares)
    {
        _requireCanExit();
        shares = previewWithdraw(assets);
        _exit(_msgSender(), receiver, owner, shares, sellTokens);
    }

    function redeem(uint256 shares, address receiver, address owner)
        public
        override
        nonReentrant
        returns (uint256 assets)
    {
        assets = _exit(_msgSender(), receiver, owner, shares, new bool[](0));
    }

    /// @dev `sellTokens[i]` = true sells asset i to USDC, false transfers the token to `receiver`.
    function redeem(uint256 shares, address receiver, address owner, bool[] calldata sellTokens)
        external
        nonReentrant
        returns (uint256 assets)
    {
        assets = _exit(_msgSender(), receiver, owner, shares, sellTokens);
    }

    // ---------------------------------------------------------------------
    // Vault views
    // ---------------------------------------------------------------------

    /// @notice True while any basket asset cannot currently be priced (both oracles invalid).
    function paused() public view returns (bool) {
        uint256 n = _basketAssets.length;
        for (uint256 i = 0; i < n; ++i) {
            if (!_isPriced(_basketAssets[i])) return true;
        }
        return false;
    }

    function basketAssets() external view returns (address[] memory) {
        return _basketAssets;
    }

    function basketWeightsBps() external view returns (uint16[] memory) {
        return _basketWeightsBps;
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    function _enter(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares,
        uint256[] memory minAmountsOut
    ) internal {
        _requireCanDeposit();
        _transferIn(caller, assets);
        _buyBasket(assets, minAmountsOut);
        costBasis[receiver] += assets;
        _mint(receiver, shares);
        emit Deposit(caller, receiver, assets, shares);
    }

    /// @dev Sells the proportional share of every basket asset, charges the performance fee on
    /// realized gain, then distributes per-asset token or USDC proceeds to `receiver`.
    function _exit(address caller, address receiver, address owner, uint256 shares, bool[] memory sellTokens)
        internal
        returns (uint256 assetsOut)
    {
        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }
        uint256 sharesBefore = balanceOf(owner);
        if (shares > sharesBefore) revert ERC4626ExceededMaxRedeem(owner, shares, sharesBefore);
        _requireCanExit();

        uint256 totalShares = totalSupply();
        uint256 n = _basketAssets.length;
        if (sellTokens.length != 0 && sellTokens.length != n) revert SellFlagsLengthMismatch(n, sellTokens.length);
        bool explicitFlags = sellTokens.length != 0;

        // Exact proportional share of each asset, valued at live prices.
        uint256[] memory amounts = new uint256[](n);
        uint256 valueWithdrawn = _computeExitAmounts(amounts, shares, totalShares);

        // Realized gain on the withdrawn fraction; fee only on positive gain.
        uint256 realizedCost = costBasis[owner].mulDiv(shares, sharesBefore);
        costBasis[owner] -= realizedCost;
        uint256 fee;
        if (valueWithdrawn > realizedCost) {
            fee = (valueWithdrawn - realizedCost).mulDiv(feeBps, BPS_DENOMINATOR);
        }

        _burn(owner, shares);

        _settleFee(_distribute(receiver, amounts, sellTokens, explicitFlags, fee, valueWithdrawn));

        emit Withdraw(caller, receiver, owner, valueWithdrawn, shares);
        return valueWithdrawn;
    }

    /// @dev Fills `amounts` with the proportional share of each asset and returns its USDC value.
    function _computeExitAmounts(uint256[] memory amounts, uint256 shares, uint256 totalShares)
        internal
        view
        returns (uint256 valueWithdrawn)
    {
        uint256 n = _basketAssets.length;
        for (uint256 i = 0; i < n; ++i) {
            address a = _basketAssets[i];
            uint256 amount = IERC20(a).balanceOf(address(this)).mulDiv(shares, totalShares);
            amounts[i] = amount;
            valueWithdrawn += _valueUsdc(a, amount);
        }
    }

    /// @dev Collects the fee by selling a proportional slice of every asset (even token exits),
    /// then distributes the remainder per user choice. Returns the USDC fee pot collected.
    function _distribute(
        address receiver,
        uint256[] memory amounts,
        bool[] memory sellTokens,
        bool explicitFlags,
        uint256 fee,
        uint256 valueWithdrawn
    ) internal returns (uint256 feePot) {
        uint256 n = _basketAssets.length;
        for (uint256 i = 0; i < n; ++i) {
            address a = _basketAssets[i];
            uint256 toSell = amounts[i];
            if (fee > 0) {
                uint256 feeSlice = amounts[i].mulDiv(fee, valueWithdrawn, Math.Rounding.Ceil);
                if (feeSlice > amounts[i]) feeSlice = amounts[i];
                feePot += _sell(a, feeSlice, _sellMinOut(a, feeSlice));
                toSell = amounts[i] - feeSlice;
            }
            if (explicitFlags ? sellTokens[i] : true) {
                uint256 usdcOut = _sell(a, toSell, _sellMinOut(a, toSell));
                IERC20(asset()).safeTransfer(receiver, usdcOut);
            } else {
                IERC20(a).safeTransfer(receiver, toSell);
            }
        }
    }

    /// @dev Splits the collected fee pot 90 % (manager) / 10 % (treasury) and transfers it.
    function _settleFee(uint256 feePot) internal {
        if (feePot > 0) {
            uint256 managerShare = feePot.mulDiv(MANAGER_FEE_SHARE_BPS, BPS_DENOMINATOR);
            uint256 treasuryShare = feePot - managerShare;
            address treasury = registry.treasury();
            IERC20(asset()).safeTransfer(manager, managerShare);
            IERC20(asset()).safeTransfer(treasury, treasuryShare);
            emit PerformanceFeeCollected(manager, treasury, feePot, managerShare, treasuryShare);
        }
    }

    function _buyBasket(uint256 assets, uint256[] memory minAmountsOut) internal {
        uint256 n = _basketAssets.length;
        if (minAmountsOut.length != 0 && minAmountsOut.length != n) {
            revert MinOutsLengthMismatch(n, minAmountsOut.length);
        }
        bool explicitMins = minAmountsOut.length != 0;
        for (uint256 i = 0; i < n; ++i) {
            address a = _basketAssets[i];
            uint256 alloc = assets.mulDiv(_basketWeightsBps[i], BPS_DENOMINATOR);
            uint256 minOut = explicitMins ? minAmountsOut[i] : _buyMinOut(a, alloc);
            ISwapRouter(registry.assetConfig(a).liquidityRoute).swapExactIn(asset(), a, alloc, minOut);
        }
    }

    function _sell(address a, uint256 tokenAmount, uint256 minOut) internal returns (uint256 usdcOut) {
        usdcOut = ISwapRouter(registry.assetConfig(a).liquidityRoute).swapExactIn(a, asset(), tokenAmount, minOut);
    }

    /// @dev Token quote (natural units) for a USDC buy, discounted by the vault default slippage bound.
    function _buyMinOut(address a, uint256 usdcAmount) internal view returns (uint256) {
        uint256 quoted = _buyQuote(a, usdcAmount);
        return quoted.mulDiv(BPS_DENOMINATOR - maxSlippageBps, BPS_DENOMINATOR);
    }

    /// @dev USDC quote for a token sell, discounted by the vault default slippage bound.
    function _sellMinOut(address a, uint256 tokenAmount) internal view returns (uint256) {
        uint256 quoted = _valueUsdc(a, tokenAmount);
        return quoted.mulDiv(BPS_DENOMINATOR - maxSlippageBps, BPS_DENOMINATOR);
    }

    /// @dev USDC wei value of `amount` natural units of basket asset `a` at its live price.
    /// `priceE18` is dollars per whole token (Chainlink-style), so the USDC quote rescales by
    /// the settlement decimals and the base token's own decimals.
    function _valueUsdc(address a, uint256 amount) internal view returns (uint256) {
        uint256 baseScale = 10 ** uint256(registry.assetConfig(a).decimals);
        return amount.mulDiv(_priceOf(a) * (10 ** _usdcDecimals), baseScale * 1e18);
    }

    /// @dev Natural-unit token quote for a USDC buy amount.
    function _buyQuote(address a, uint256 usdcAmount) internal view returns (uint256) {
        uint256 baseScale = 10 ** uint256(registry.assetConfig(a).decimals);
        return usdcAmount.mulDiv(baseScale * 1e18, _priceOf(a) * (10 ** _usdcDecimals));
    }

    function _priceOf(address a) internal view returns (uint256) {
        (uint256 price,) = registry.getPrice(a, asset());
        return price;
    }

    function _isPriced(address a) internal view returns (bool) {
        try registry.getPrice(a, asset()) returns (uint256 price, uint256) {
            return price != 0;
        } catch {
            return false;
        }
    }

    function _requireCanDeposit() internal view {
        uint256 n = _basketAssets.length;
        for (uint256 i = 0; i < n; ++i) {
            address a = _basketAssets[i];
            if (!registry.canOpenExposure(a) || !_isPriced(a)) revert VaultPaused();
        }
    }

    function _requireCanExit() internal view {
        uint256 n = _basketAssets.length;
        for (uint256 i = 0; i < n; ++i) {
            address a = _basketAssets[i];
            if (!registry.canExit(a) || !_isPriced(a)) revert VaultPaused();
        }
    }

    // ---------------------------------------------------------------------
    // Non-transferable shares
    // ---------------------------------------------------------------------

    function transfer(address, uint256) public pure override(ERC20, IERC20) returns (bool) {
        revert SharesNonTransferable();
    }

    function transferFrom(address, address, uint256) public pure override(ERC20, IERC20) returns (bool) {
        revert SharesNonTransferable();
    }
}
