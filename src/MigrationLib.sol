// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {AssetRegistry} from "./AssetRegistry.sol";
import {EquiVault} from "./EquiVault.sol";
import {ISwapRouter} from "./interfaces/ISwapRouter.sol";

/// @notice Basket-migration execution logic externalized from EquiVault.
/// @dev The vault DELEGATECALLs this library, so swaps and approvals carry the vault as
/// `msg.sender` and the vault's route allowances apply. Keeping this logic out of the vault shrinks
/// its runtime and therefore the vault initcode embedded in `VaultFactory`, bringing the factory
/// back under the EIP-170 code-size limit on standard EVM chains. The library never writes the
/// vault's basket storage: the vault reassigns its arrays after the migration succeeds.
library MigrationLib {
    using Math for uint256;
    using SafeERC20 for IERC20;

    uint16 internal constant BPS_DENOMINATOR = 10_000;

    /// @dev Same signature as `EquiVault.MinOutsLengthMismatch` so reverts stay ABI-compatible.
    error MinOutsLengthMismatch(uint256 expected, uint256 actual);

    /// @dev Migrates the held basket toward the proposal target: sells removed assets entirely to
    /// the settlement asset, buys added assets proportionally to their target weights from the
    /// freed balance, and approves each new liquidity route. Kept assets keep their positions;
    /// weight drift is left to the rebalance engine.
    function migrate(
        EquiVault vault,
        address[] calldata newAssets,
        uint16[] calldata newWeightsBps,
        uint256[] calldata sellMinOuts,
        uint256[] calldata buyMinOuts
    ) external {
        address[] memory currentAssets = vault.basketAssets();

        // Removed assets, in current basket order.
        address[] memory removed = new address[](currentAssets.length);
        uint256 nRemoved;
        for (uint256 i = 0; i < currentAssets.length; ++i) {
            bool keep;
            for (uint256 j = 0; j < newAssets.length; ++j) {
                if (currentAssets[i] == newAssets[j]) {
                    keep = true;
                    break;
                }
            }
            if (!keep) removed[nRemoved++] = currentAssets[i];
        }
        if (sellMinOuts.length != 0 && sellMinOuts.length != nRemoved) {
            revert MinOutsLengthMismatch(nRemoved, sellMinOuts.length);
        }

        for (uint256 i = 0; i < nRemoved; ++i) {
            address a = removed[i];
            uint256 balance = IERC20(a).balanceOf(address(vault));
            if (balance == 0) continue;
            uint256 minOut = sellMinOuts.length != 0 ? sellMinOuts[i] : 0;
            _sell(vault, a, balance, minOut == 0 ? _sellMinOut(vault, a, balance) : minOut);
        }

        // Added assets, in target order, with their target weights.
        address[] memory added = new address[](newAssets.length);
        uint16[] memory addedWeights = new uint16[](newAssets.length);
        uint256 nAdded;
        for (uint256 i = 0; i < newAssets.length; ++i) {
            bool present;
            for (uint256 j = 0; j < currentAssets.length; ++j) {
                if (currentAssets[j] == newAssets[i]) {
                    present = true;
                    break;
                }
            }
            if (!present) {
                added[nAdded] = newAssets[i];
                addedWeights[nAdded] = newWeightsBps[i];
                nAdded++;
            }
        }
        if (buyMinOuts.length != 0 && buyMinOuts.length != nAdded) {
            revert MinOutsLengthMismatch(nAdded, buyMinOuts.length);
        }

        address settlement = vault.asset();
        // The buy leg needs the route to pull the settlement asset, and later sells/withdrawals
        // need the token leg.
        for (uint256 i = 0; i < nAdded; ++i) {
            address a = added[i];
            address route = vault.registry().assetConfig(a).liquidityRoute;
            SafeERC20.forceApprove(IERC20(settlement), route, type(uint256).max);
            SafeERC20.forceApprove(IERC20(a), route, type(uint256).max);
        }

        uint256 addedWeightSum;
        for (uint256 i = 0; i < nAdded; ++i) addedWeightSum += addedWeights[i];
        uint256 settlementBalance = IERC20(settlement).balanceOf(address(vault));
        for (uint256 i = 0; i < nAdded; ++i) {
            address a = added[i];
            uint256 alloc = settlementBalance.mulDiv(addedWeights[i], addedWeightSum);
            if (alloc == 0) continue;
            uint256 minOut = buyMinOuts.length != 0 ? buyMinOuts[i] : 0;
            ISwapRouter(vault.registry().assetConfig(a).liquidityRoute).swapExactIn(
                settlement, a, alloc, minOut == 0 ? _buyMinOut(vault, a, alloc) : minOut
            );
        }
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    function _sell(EquiVault vault, address a, uint256 tokenAmount, uint256 minOut) private returns (uint256) {
        address route = vault.registry().assetConfig(a).liquidityRoute;
        return ISwapRouter(route).swapExactIn(a, vault.asset(), tokenAmount, minOut);
    }

    /// @dev Settlement quote for a token sell, discounted by the vault default slippage bound.
    function _sellMinOut(EquiVault vault, address a, uint256 tokenAmount) private view returns (uint256) {
        return _valueSettlement(vault, a, tokenAmount).mulDiv(BPS_DENOMINATOR - vault.maxSlippageBps(), BPS_DENOMINATOR);
    }

    /// @dev Token quote for a settlement buy, discounted by the vault default slippage bound.
    function _buyMinOut(EquiVault vault, address a, uint256 settlementAmount) private view returns (uint256) {
        return _buyQuote(vault, a, settlementAmount).mulDiv(BPS_DENOMINATOR - vault.maxSlippageBps(), BPS_DENOMINATOR);
    }

    function _valueSettlement(EquiVault vault, address a, uint256 amount) private view returns (uint256) {
        AssetRegistry.AssetConfig memory config = vault.registry().assetConfig(a);
        uint256 baseScale = 10 ** uint256(config.decimals);
        uint256 price = _priceOf(vault, a);
        return amount.mulDiv(price * (10 ** vault.settlementDecimals()), baseScale * 1e18);
    }

    function _buyQuote(EquiVault vault, address a, uint256 settlementAmount) private view returns (uint256) {
        AssetRegistry.AssetConfig memory config = vault.registry().assetConfig(a);
        uint256 baseScale = 10 ** uint256(config.decimals);
        uint256 price = _priceOf(vault, a);
        return settlementAmount.mulDiv(baseScale * 1e18, price * (10 ** vault.settlementDecimals()));
    }

    function _priceOf(EquiVault vault, address a) private view returns (uint256) {
        (uint256 price,) = vault.registry().getPrice(a, vault.asset());
        return price;
    }
}
