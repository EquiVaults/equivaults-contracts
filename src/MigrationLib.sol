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
    /// the settlement asset, then reinvests the freed balance into the new basket by target-weight
    /// deficit (kept and added assets alike), so no settlement is ever left idle outside
    /// `totalAssets()` (B001). Kept assets already at or above their target weight are not sold;
    /// residual drift is left to the rebalance engine. Approves each newly-added liquidity route.
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

        // New-basket buy leg: reinvest the freed settlement toward the target weights by deficit
        // (kept and added assets alike), in `newAssets` order. `buyMinOuts` is indexed on the new
        // basket when non-empty; 0 (or an empty array) falls back to the vault default bound.
        if (buyMinOuts.length != 0 && buyMinOuts.length != newAssets.length) {
            revert MinOutsLengthMismatch(newAssets.length, buyMinOuts.length);
        }

        address settlement = vault.asset();
        // Approve the routes of assets that are not part of the current basket (kept assets were
        // approved at construction or by a previous migration).
        uint256 keptValue;
        uint256[] memory currentValues = new uint256[](newAssets.length);
        for (uint256 i = 0; i < newAssets.length; ++i) {
            address a = newAssets[i];
            bool kept;
            for (uint256 j = 0; j < currentAssets.length; ++j) {
                if (currentAssets[j] == a) {
                    kept = true;
                    break;
                }
            }
            if (!kept) {
                address route = vault.registry().assetConfig(a).liquidityRoute;
                SafeERC20.forceApprove(IERC20(settlement), route, type(uint256).max);
                SafeERC20.forceApprove(IERC20(a), route, type(uint256).max);
            }
            uint256 bal = IERC20(a).balanceOf(address(vault));
            currentValues[i] = _valueSettlement(vault, a, bal);
            keptValue += currentValues[i];
        }

        uint256 settlementBalance = IERC20(settlement).balanceOf(address(vault));
        uint256 navBasis = keptValue + settlementBalance; // value the freed settlement must reach
        uint256 totalDeficit;
        uint256[] memory deficits = new uint256[](newAssets.length);
        for (uint256 i = 0; i < newAssets.length; ++i) {
            uint256 target = navBasis.mulDiv(newWeightsBps[i], BPS_DENOMINATOR);
            if (target > currentValues[i]) {
                deficits[i] = target - currentValues[i];
                totalDeficit += deficits[i];
            }
        }

        // Sum of deficits >= freed settlement (any overweight kept asset only adds to it), so the
        // proportional allocation below always spends the full balance, down to sub-wei dust.
        for (uint256 i = 0; i < newAssets.length; ++i) {
            if (deficits[i] == 0) continue;
            uint256 alloc = settlementBalance.mulDiv(deficits[i], totalDeficit);
            if (alloc == 0) continue;
            uint256 minOut = buyMinOuts.length != 0 ? buyMinOuts[i] : 0;
            ISwapRouter(vault.registry().assetConfig(newAssets[i]).liquidityRoute).swapExactIn(
                settlement, newAssets[i], alloc, minOut == 0 ? _buyMinOut(vault, newAssets[i], alloc) : minOut
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
