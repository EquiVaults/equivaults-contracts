// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AssetRegistry} from "./AssetRegistry.sol";
import {EquiVault} from "./EquiVault.sol";

/// @notice Creation-parameter validation externalized from EquiVault's constructor.
/// @dev The constructor DELEGATECALLs this library, so the validation bytecode lives here instead
/// of in the vault initcode. That initcode is embedded in `VaultFactory` (which deploys vaults with
/// `new EquiVault`), and keeping it small enough keeps the factory under the EIP-170 code-size
/// limit on standard EVM chains. Errors keep the exact signatures of the vault's own errors so
/// reverts stay ABI-compatible (identical selectors and payloads).
library InitLib {
    // Creation bounds, mirroring EquiVault's public constants (referencing `EquiVault.X` directly
    // is not resolved because of the EquiVault <-> InitLib import cycle). The vault bounds tests
    // cover these values.
    uint16 private constant MAX_FEE_BPS = 2_000; // 20 %
    uint16 private constant MAX_SLIPPAGE_BPS = 3_000; // 30 %
    uint256 private constant MIN_TIMELOCK_DELAY = 1 days;
    uint256 private constant MAX_TIMELOCK_DELAY = 7 days;
    uint16 private constant MIN_DRIFT_BPS = 100; // 1 point
    uint16 private constant MAX_DRIFT_BPS = 1_000; // 10 points
    uint16 private constant DEFAULT_DRIFT_BPS = 300; // 3 points
    uint16 private constant MIN_REBALANCE_SLIPPAGE_BPS = 10; // 0.1 %
    uint16 private constant MAX_REBALANCE_SLIPPAGE_BPS = 300; // 3 %
    uint16 private constant DEFAULT_REBALANCE_SLIPPAGE_BPS = 100; // 1 %

    error InvalidAddress();
    error InvalidFee(uint16 feeBps);
    error InvalidSlippage(uint16 slippageBps);
    error InvalidTimelockDelay(uint256 delay);
    error InvalidAumCap(uint256 capAum, uint256 bound);
    error InvalidDriftThreshold(uint16 driftBps);
    error InvalidRebalanceSlippage(uint16 slippageBps);

    /// @dev Validates every creation bound except the basket (validated by `_initBasket` in the
    /// vault) and returns the effective rebalance parameters (0 = protocol defaults).
    function validate(
        address manager_,
        AssetRegistry registry_,
        uint16 feeBps_,
        uint16 maxSlippageBps_,
        EquiVault.TimelockMode timelockMode_,
        uint256 timelockDelay_,
        uint256 capAum_,
        uint256 aumBound_,
        uint16 driftThresholdBps_,
        uint16 rebalanceSlippageBps_
    ) external pure returns (uint16 driftThresholdBps, uint16 rebalanceSlippageBps) {
        if (manager_ == address(0)) revert InvalidAddress();
        if (address(registry_) == address(0)) revert InvalidAddress();
        if (feeBps_ > MAX_FEE_BPS) revert InvalidFee(feeBps_);
        if (maxSlippageBps_ > MAX_SLIPPAGE_BPS) revert InvalidSlippage(maxSlippageBps_);
        // `timelockMode_` cannot be out of range: Solidity bounds-checks enum values on conversion
        // and on ABI decoding, so an invalid mode is rejected with Panic(0x21) before this code.
        if (timelockMode_ == EquiVault.TimelockMode.Delayed) {
            if (timelockDelay_ < MIN_TIMELOCK_DELAY || timelockDelay_ > MAX_TIMELOCK_DELAY) {
                revert InvalidTimelockDelay(timelockDelay_);
            }
        } else if (timelockDelay_ != 0) {
            revert InvalidTimelockDelay(timelockDelay_);
        }

        if (capAum_ == 0 || capAum_ > aumBound_) revert InvalidAumCap(capAum_, aumBound_);

        if (driftThresholdBps_ != 0) {
            if (driftThresholdBps_ < MIN_DRIFT_BPS || driftThresholdBps_ > MAX_DRIFT_BPS) {
                revert InvalidDriftThreshold(driftThresholdBps_);
            }
        }
        if (rebalanceSlippageBps_ != 0) {
            if (
                rebalanceSlippageBps_ < MIN_REBALANCE_SLIPPAGE_BPS || rebalanceSlippageBps_ > MAX_REBALANCE_SLIPPAGE_BPS
                    || rebalanceSlippageBps_ > maxSlippageBps_
            ) revert InvalidRebalanceSlippage(rebalanceSlippageBps_);
        }

        driftThresholdBps = driftThresholdBps_ == 0 ? DEFAULT_DRIFT_BPS : driftThresholdBps_;
        rebalanceSlippageBps = rebalanceSlippageBps_ == 0
            ? (maxSlippageBps_ < DEFAULT_REBALANCE_SLIPPAGE_BPS ? maxSlippageBps_ : DEFAULT_REBALANCE_SLIPPAGE_BPS)
            : rebalanceSlippageBps_;
    }
}
