// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {EquiVault} from "./EquiVault.sol";

/// @notice Permissionless, non-custodial rebalance coordinator for EquiVault vaults.
/// @dev The engine measures basket drift through the vault's public views and forwards rebalances
/// to the vault, which re-validates every guarantee on-chain (drift threshold, deadline, slippage
/// bounds, gas-rebate cap). The engine never holds funds and cannot relax any vault rule: external
/// automation (Chainlink Automation, Gelato, custom keepers) can use it as a stable entry point
/// without gaining any power over vault assets. The gas reimbursement the vault pays is forwarded
/// to the caller so the engine stays economically neutral.
contract RebalanceEngine {
    using SafeERC20 for IERC20;

    error VaultPaused();
    error DriftBelowThreshold(uint256 maxDeviationBps, uint16 thresholdBps);

    /// @notice True when the vault can be rebalanced: not paused and drift above its threshold.
    function needsRebalance(EquiVault vault) external view returns (bool) {
        if (vault.paused()) return false;
        (, bool aboveThreshold) = vault.measureDrift();
        return aboveThreshold;
    }

    /// @notice Max absolute basket deviation (bps of NAV) and whether it exceeds the threshold.
    function measureDrift(EquiVault vault) external view returns (uint256 maxDeviationBps, bool aboveThreshold) {
        return vault.measureDrift();
    }

    /// @notice Forwards a rebalance to the vault once the drift is confirmed above threshold, and
    /// forwards the gas reimbursement to the caller.
    function rebalance(EquiVault vault, EquiVault.RebalanceParams calldata params)
        external
        returns (uint256 gasRebate)
    {
        if (vault.paused()) revert VaultPaused();
        (uint256 maxDeviationBps, bool aboveThreshold) = vault.measureDrift();
        if (!aboveThreshold) revert DriftBelowThreshold(maxDeviationBps, vault.driftThresholdBps());

        gasRebate = vault.rebalance(params);
        if (gasRebate > 0) {
            IERC20(vault.asset()).safeTransfer(msg.sender, gasRebate);
        }
    }
}
