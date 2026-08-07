// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {AssetRegistry} from "./AssetRegistry.sol";
import {EquiVault} from "./EquiVault.sol";
import {ISwapRouter} from "./interfaces/ISwapRouter.sol";

/// @notice Rebalance execution logic externalized from EquiVault to keep its runtime small.
/// @dev The vault DELEGATECALLs this library, so the code runs in the vault's context: external
/// calls (liquidity routes) carry the vault as `msg.sender` and the vault's route allowances
/// apply. Keeping the rebalance logic out of the vault shrinks its runtime, which also shrinks the
/// vault initcode embedded in `VaultFactory` (it deploys vaults with `new EquiVault`), bringing the
/// factory back under the EIP-170 code-size limit on standard EVM chains. The library is
/// deliberately callable by anyone: outside the vault context its swaps revert because the caller
/// holds no route allowances, so it cannot move vault funds.
library RebalanceLib {
    using Math for uint256;

    uint16 internal constant BPS_DENOMINATOR = 10_000;
    uint256 internal constant MAX_GAS_REBATE = 5e6; // absolute settlement cap per rebalance (5 units)
    uint256 internal constant ETH_SETTLEMENT_PRICE_CAP = 5_000e6; // fixed ETH price cap in settlement wei per ETH

    /// @dev Same signature as `EquiVault.RebalanceMinTooPermissive` so reverts stay ABI-compatible
    /// with the vault (identical selector and payload).
    error RebalanceMinTooPermissive(uint256 index, uint256 minOut, uint256 defaultMinOut);

    /// @dev Max absolute deviation (in bps of NAV) of any basket asset from its target weight.
    /// The basket is rebalanceable when `maxDeviationBps` exceeds the vault's drift threshold.
    function measureDrift(EquiVault vault) external view returns (uint256 maxDeviationBps, bool aboveThreshold) {
        uint256 nav = vault.totalAssets();
        address[] memory assets = vault.basketAssets();
        uint16[] memory weights = vault.basketWeightsBps();
        uint256 n = assets.length;
        if (nav == 0) return (0, false);
        for (uint256 i = 0; i < n; ++i) {
            uint256 value = _valueSettlement(vault, assets[i], IERC20(assets[i]).balanceOf(address(vault)));
            uint256 target = nav.mulDiv(weights[i], BPS_DENOMINATOR);
            uint256 dev = value > target ? value - target : target - value;
            uint256 devBps = dev.mulDiv(BPS_DENOMINATOR, nav);
            if (devBps > maxDeviationBps) maxDeviationBps = devBps;
        }
        aboveThreshold = maxDeviationBps > vault.driftThresholdBps();
    }

    /// @dev Gas reimbursement in settlement wei for `gasUsed` (measured by the vault itself, never
    /// here: `gasleft()` inside a DELEGATECALL library is amputated by the EIP-150 63/64 rule, so
    /// measuring here would overestimate the rebate). Times the transaction gas price, converted at
    /// the fixed ETH price cap and clamped to `MAX_GAS_REBATE`.
    function computeRebate(uint256 gasUsed) external view returns (uint256) {
        uint256 rebateSettlement = gasUsed * tx.gasprice * ETH_SETTLEMENT_PRICE_CAP / 1e18;
        return rebateSettlement > MAX_GAS_REBATE ? MAX_GAS_REBATE : rebateSettlement;
    }

    /// @dev Current basket weights in bps of NAV (0 when the NAV is 0), for the history event.
    function weightsBpsOf(EquiVault vault, uint256 nav) external view returns (uint256[] memory weightsBps) {
        address[] memory assets = vault.basketAssets();
        uint256 n = assets.length;
        weightsBps = new uint256[](n);
        if (nav == 0) return weightsBps;
        for (uint256 i = 0; i < n; ++i) {
            weightsBps[i] =
                _valueSettlement(vault, assets[i], IERC20(assets[i]).balanceOf(address(vault))).mulDiv(BPS_DENOMINATOR, nav);
        }
    }

    /// @dev Sells each overweight asset down to its target weight; returns the settlement actually
    /// received. Reverts if an explicit min out is more permissive than the vault default.
    function sellOverweight(EquiVault vault, uint256 nav, uint256[] calldata minAmountsOut)
        external
        returns (uint256 soldValueSettlement)
    {
        address[] memory assets = vault.basketAssets();
        uint16[] memory weights = vault.basketWeightsBps();
        uint256 n = assets.length;
        bool explicitMins = minAmountsOut.length != 0;
        for (uint256 i = 0; i < n; ++i) {
            address a = assets[i];
            uint256 value = _valueSettlement(vault, a, IERC20(a).balanceOf(address(vault)));
            uint256 target = nav.mulDiv(weights[i], BPS_DENOMINATOR);
            if (value <= target) continue;
            uint256 tokensToSell = _buyQuote(vault, a, value - target);
            if (tokensToSell == 0) continue;
            uint256 defaultMin = _rebalanceSellMinOut(vault, a, tokensToSell);
            uint256 minOut = explicitMins && minAmountsOut[i] != 0 ? minAmountsOut[i] : defaultMin;
            if (minOut < defaultMin) revert RebalanceMinTooPermissive(i, minOut, defaultMin);
            soldValueSettlement += _sell(vault, a, tokensToSell, minOut);
        }
    }

    /// @dev Buys each underweight asset back toward its target weight, distributing the vault's
    /// available settlement proportionally to the deficits. Reverts if an explicit min out is more
    /// permissive than the vault default.
    function buyUnderweight(EquiVault vault, uint256 nav, uint256[] calldata minAmountsOut)
        external
        returns (uint256 boughtValueSettlement)
    {
        address[] memory assets = vault.basketAssets();
        uint16[] memory weights = vault.basketWeightsBps();
        uint256 n = assets.length;
        address settlement = vault.asset();
        uint256 pool = IERC20(settlement).balanceOf(address(vault));
        if (pool == 0) return 0;

        uint256 totalDeficit;
        uint256[] memory deficits = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            address a = assets[i];
            uint256 value = _valueSettlement(vault, a, IERC20(a).balanceOf(address(vault)));
            uint256 target = nav.mulDiv(weights[i], BPS_DENOMINATOR);
            if (value < target) {
                deficits[i] = target - value;
                totalDeficit += deficits[i];
            }
        }
        if (totalDeficit == 0) return 0;

        bool explicitMins = minAmountsOut.length != 0;
        for (uint256 i = 0; i < n; ++i) {
            uint256 deficit = deficits[i];
            if (deficit == 0) continue;
            address a = assets[i];
            uint256 alloc = pool.mulDiv(deficit, totalDeficit);
            if (alloc == 0) continue;
            uint256 defaultMin = _rebalanceBuyMinOut(vault, a, alloc);
            uint256 minOut = explicitMins && minAmountsOut[i] != 0 ? minAmountsOut[i] : defaultMin;
            if (minOut < defaultMin) revert RebalanceMinTooPermissive(i, minOut, defaultMin);
            address route = vault.registry().assetConfig(a).liquidityRoute;
            ISwapRouter(route).swapExactIn(settlement, a, alloc, minOut);
            boughtValueSettlement += alloc;
        }
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    /// @dev Settlement wei value of `amount` natural units of basket asset `a` at its live price,
    /// identical to `EquiVault._valueSettlement` (Chainlink-style priceE18 rescaled by decimals).
    function _valueSettlement(EquiVault vault, address a, uint256 amount) private view returns (uint256) {
        AssetRegistry.AssetConfig memory config = vault.registry().assetConfig(a);
        uint256 baseScale = 10 ** uint256(config.decimals);
        uint256 price = _priceOf(vault, a);
        return amount.mulDiv(price * (10 ** vault.settlementDecimals()), baseScale * 1e18);
    }

    /// @dev Natural-unit token quote for a settlement buy, identical to `EquiVault._buyQuote`.
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

    function _sell(EquiVault vault, address a, uint256 tokenAmount, uint256 minOut) private returns (uint256) {
        address route = vault.registry().assetConfig(a).liquidityRoute;
        return ISwapRouter(route).swapExactIn(a, vault.asset(), tokenAmount, minOut);
    }

    /// @dev Settlement quote for a token sell, discounted by the collective rebalance slippage bound.
    function _rebalanceSellMinOut(EquiVault vault, address a, uint256 tokenAmount) private view returns (uint256) {
        return _valueSettlement(vault, a, tokenAmount).mulDiv(BPS_DENOMINATOR - vault.rebalanceSlippageBps(), BPS_DENOMINATOR);
    }

    /// @dev Token quote for a settlement buy, discounted by the collective rebalance slippage bound.
    function _rebalanceBuyMinOut(EquiVault vault, address a, uint256 settlementAmount) private view returns (uint256) {
        return _buyQuote(vault, a, settlementAmount).mulDiv(BPS_DENOMINATOR - vault.rebalanceSlippageBps(), BPS_DENOMINATOR);
    }
}
