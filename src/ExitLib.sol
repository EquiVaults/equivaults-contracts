// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {AssetRegistry} from "./AssetRegistry.sol";
import {EquiVault} from "./EquiVault.sol";
import {ISwapRouter} from "./interfaces/ISwapRouter.sol";

/// @notice Exit distribution logic externalized from EquiVault.
/// @dev The vault DELEGATECALLs this library, so swaps and token transfers carry the vault as
/// `msg.sender` and the vault's route allowances apply. Keeping this logic out of the vault shrinks
/// its runtime and therefore the vault initcode embedded in `VaultFactory`, bringing the factory
/// back under the EIP-170 code-size limit on standard EVM chains. The library never writes the
/// vault's storage (cost basis, share balances): the vault keeps those writes.
library ExitLib {
    using Math for uint256;
    using SafeERC20 for IERC20;

    uint16 internal constant BPS_DENOMINATOR = 10_000;

    /// @dev Fills the returned `amounts` with the proportional share of each basket asset and
    /// returns their combined settlement value.
    function computeExitAmounts(EquiVault vault, uint256 shares, uint256 totalShares)
        external
        view
        returns (uint256[] memory amounts, uint256 valueWithdrawn)
    {
        address[] memory assets = vault.basketAssets();
        uint256 n = assets.length;
        amounts = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            address a = assets[i];
            uint256 amount = IERC20(a).balanceOf(address(vault)).mulDiv(shares, totalShares);
            amounts[i] = amount;
            valueWithdrawn += _valueSettlement(vault, a, amount);
        }
    }

    /// @dev Collects the fee by selling a proportional slice of every asset (even token exits),
    /// then distributes the remainder per user choice: sell to the settlement asset or transfer
    /// the token. Returns the settlement fee pot collected.
    function distribute(
        EquiVault vault,
        address receiver,
        uint256[] calldata amounts,
        bool[] calldata sellTokens,
        bool explicitFlags,
        uint256 fee,
        uint256 valueWithdrawn
    ) external returns (uint256 feePot) {
        address[] memory assets = vault.basketAssets();
        uint256 n = assets.length;
        address settlement = vault.asset();
        for (uint256 i = 0; i < n; ++i) {
            address a = assets[i];
            uint256 toSell = amounts[i];
            if (fee > 0) {
                uint256 feeSlice = amounts[i].mulDiv(fee, valueWithdrawn, Math.Rounding.Ceil);
                if (feeSlice > amounts[i]) feeSlice = amounts[i];
                feePot += _sell(vault, a, feeSlice, _sellMinOut(vault, a, feeSlice));
                toSell = amounts[i] - feeSlice;
            }
            if (explicitFlags ? sellTokens[i] : true) {
                uint256 settlementOut = _sell(vault, a, toSell, _sellMinOut(vault, a, toSell));
                IERC20(settlement).safeTransfer(receiver, settlementOut);
            } else {
                IERC20(a).safeTransfer(receiver, toSell);
            }
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

    function _valueSettlement(EquiVault vault, address a, uint256 amount) private view returns (uint256) {
        AssetRegistry.AssetConfig memory config = vault.registry().assetConfig(a);
        uint256 baseScale = 10 ** uint256(config.decimals);
        uint256 price = _priceOf(vault, a);
        return amount.mulDiv(price * (10 ** vault.settlementDecimals()), baseScale * 1e18);
    }

    function _priceOf(EquiVault vault, address a) private view returns (uint256) {
        (uint256 price,) = vault.registry().getPrice(a, vault.asset());
        return price;
    }
}
