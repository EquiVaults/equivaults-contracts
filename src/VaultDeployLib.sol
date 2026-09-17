// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AssetRegistry} from "./AssetRegistry.sol";
import {EquiVault} from "./EquiVault.sol";

/// @notice Keeps vault initcode out of the factory runtime's EIP-170 budget.
/// @dev Delegatecall preserves the factory as the creator. No storage writes.
library VaultDeployLib {
    function deploy(
        IERC20 settlement,
        AssetRegistry registry,
        address manager,
        address[] memory assets,
        uint16[] memory weights,
        uint16 feeBps,
        uint16 slippageBps,
        EquiVault.TimelockMode mode,
        uint256 delay,
        uint16 driftBps,
        uint16 rebalanceSlippageBps
    ) external returns (address) {
        return address(
            new EquiVault(
                settlement,
                registry,
                manager,
                assets,
                weights,
                feeBps,
                slippageBps,
                mode,
                delay,
                driftBps,
                rebalanceSlippageBps
            )
        );
    }
}
