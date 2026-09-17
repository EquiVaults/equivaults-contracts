// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AssetRegistry} from "./AssetRegistry.sol";
import {IAsyncVault} from "./interfaces/IAsyncVault.sol";

/// @notice Complete-tranche admission and net-value mint calculation.
/// @dev Executed by delegatecall; never writes vault storage. Only standard, non-rebasing,
/// non-taxed tokens are supported. Prices and holdings are sampled once per settlement.
library AsyncEntryLib {
    using Math for uint256;
    using SafeERC20 for IERC20;

    uint256 private constant BPS = 10_000;
    uint256 private constant VIRTUAL_SHARES = 1e6;
    uint256 private constant VIRTUAL_ASSETS = 1;
    // System admission bound, not a personal execution preference: rounding may cost at most 1 bp.
    uint256 public constant MAX_ROUNDING_BPS = 1;

    error InvalidTranche();
    error ExcessiveRounding();
    error UnsupportedTransfer(address token);
    error InvestmentPaused();

    struct Snapshot {
        address[] assets;
        uint256[] holdings;
        uint256[] numerators;
        uint256[] denominators;
        uint256 supply;
        uint256 nav;
    }

    function preview(IAsyncVault vault, uint256[] memory available)
        external
        view
        returns (uint256 shares, uint256[] memory amounts, uint256 valueReceived)
    {
        Snapshot memory s = _snapshot(vault);
        if (available.length != s.assets.length) revert InvalidTranche();
        amounts = new uint256[](available.length);
        uint256 roundingValue;
        if (s.supply == 0) {
            uint16[] memory weights = vault.basketWeightsBps();
            uint256 budget = type(uint256).max;
            for (uint256 i; i < available.length; ++i) {
                budget = Math.min(budget, _value(s, i, available[i]).mulDiv(BPS, weights[i]));
            }
            for (uint256 i; i < available.length; ++i) {
                uint256 target = budget.mulDiv(weights[i], BPS);
                if (target == 0) revert InvalidTranche();
                amounts[i] = target.mulDiv(s.denominators[i], s.numerators[i], Math.Rounding.Ceil);
                if (amounts[i] > available[i]) revert InvalidTranche();
                if (mulmod(budget, weights[i], BPS) != 0) ++roundingValue;
                if (mulmod(target, s.denominators[i], s.numerators[i]) != 0) {
                    roundingValue += _unitValue(s, i);
                }
            }
        } else {
            if (s.nav == 0) revert InvalidTranche();
            uint256 proportionalShares = type(uint256).max;
            for (uint256 i; i < available.length; ++i) {
                if (s.holdings[i] > 0) {
                    proportionalShares = Math.min(proportionalShares, available[i].mulDiv(s.supply, s.holdings[i]));
                }
            }
            if (proportionalShares == 0 || proportionalShares == type(uint256).max) revert InvalidTranche();
            for (uint256 i; i < available.length; ++i) {
                amounts[i] = proportionalShares.mulDiv(s.holdings[i], s.supply, Math.Rounding.Ceil);
                if (mulmod(proportionalShares, s.holdings[i], s.supply) != 0) {
                    roundingValue += _unitValue(s, i);
                }
            }
        }
        (shares, valueReceived) = _quote(s, amounts);
        // Token-value floors and share quantization also cost the depositor real value,
        // even when every token transfer is exactly proportional. Count conservative
        // settlement-unit bounds instead of letting tiny tranches bypass the dust guard.
        for (uint256 i; i < amounts.length; ++i) {
            if (mulmod(amounts[i], s.numerators[i], s.denominators[i]) != 0) ++roundingValue;
        }
        uint256 creditedValue = shares.mulDiv(s.nav + VIRTUAL_ASSETS, s.supply + VIRTUAL_SHARES);
        if (creditedValue < valueReceived) roundingValue += valueReceived - creditedValue;
        if (roundingValue > valueReceived.mulDiv(MAX_ROUNDING_BPS, BPS)) revert ExcessiveRounding();
    }

    /// @dev Caller authenticates the escrow; amounts are the preview-selected complete tranche.
    function receiveTranche(IAsyncVault vault, address escrow, uint256[] memory amounts)
        external
        returns (uint256 shares, uint256 valueReceived, uint256 navBefore, uint256 supplyBefore)
    {
        Snapshot memory s = _snapshot(vault);
        if (amounts.length != s.assets.length) revert InvalidTranche();
        (shares, valueReceived) = _quote(s, amounts);
        for (uint256 i; i < amounts.length; ++i) {
            if (amounts[i] == 0) continue;
            IERC20 token = IERC20(s.assets[i]);
            token.safeTransferFrom(escrow, address(vault), amounts[i]);
            if (token.balanceOf(address(vault)) != s.holdings[i] + amounts[i]) {
                revert UnsupportedTransfer(s.assets[i]);
            }
        }
        return (shares, valueReceived, s.nav, s.supply);
    }

    function _snapshot(IAsyncVault vault) private view returns (Snapshot memory s) {
        s.assets = vault.basketAssets();
        s.holdings = new uint256[](s.assets.length);
        s.numerators = new uint256[](s.assets.length);
        s.denominators = new uint256[](s.assets.length);
        s.supply = vault.totalSupply();
        AssetRegistry registry = vault.registry();
        uint256 scale = 10 ** vault.settlementDecimals();
        for (uint256 i; i < s.assets.length; ++i) {
            address asset = s.assets[i];
            if (!registry.canOpenExposure(asset)) revert InvestmentPaused();
            (uint256 price,) = registry.getPrice(asset, address(vault.settlementAsset()));
            s.numerators[i] = price * scale;
            s.denominators[i] = (10 ** registry.assetConfig(asset).decimals) * 1e18;
            s.holdings[i] = IERC20(asset).balanceOf(address(vault));
            s.nav += _value(s, i, s.holdings[i]);
        }
    }

    function _quote(Snapshot memory s, uint256[] memory amounts)
        private
        pure
        returns (uint256 shares, uint256 valueReceived)
    {
        for (uint256 i; i < amounts.length; ++i) {
            valueReceived += _value(s, i, amounts[i]);
        }
        shares = valueReceived.mulDiv(s.supply + VIRTUAL_SHARES, s.nav + VIRTUAL_ASSETS);
        if (s.supply > 0) {
            if (s.nav == 0) revert InvalidTranche();
            // Also preserve every existing holder's per-asset entitlement; the NAV cap alone
            // does not establish proportional admission when virtual offsets are material.
            for (uint256 i; i < amounts.length; ++i) {
                if (s.holdings[i] > 0) shares = Math.min(shares, amounts[i].mulDiv(s.supply, s.holdings[i]));
                else if (amounts[i] != 0) revert InvalidTranche();
            }
        } else {
            for (uint256 i; i < amounts.length; ++i) {
                if (amounts[i] == 0) revert InvalidTranche();
            }
        }
        if (shares == 0 || valueReceived == 0) revert InvalidTranche();
    }

    function _value(Snapshot memory s, uint256 i, uint256 amount) private pure returns (uint256) {
        return amount.mulDiv(s.numerators[i], s.denominators[i]);
    }

    function _unitValue(Snapshot memory s, uint256 i) private pure returns (uint256) {
        return Math.ceilDiv(s.numerators[i], s.denominators[i]);
    }
}
