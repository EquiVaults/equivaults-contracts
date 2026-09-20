// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {EntryPoint} from "../lib/account-abstraction/contracts/core/EntryPoint.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {InvestmentExecutionFactory} from "../src/InvestmentExecutionFactory.sol";

/// @notice Adds personal execution accounts to an existing local vault deployment without moving investments.
contract DeployExecutionLocal is Script {
    function run() public {
        require(block.chainid == 31337, "Local Anvil only");
        VaultFactory factory = VaultFactory(vm.envAddress("EXECUTION_VAULT_FACTORY"));
        require(address(factory).code.length > 0 && factory.protocolVersion() == 2, "Invalid v2 factory");
        vm.startBroadcast();
        EntryPoint entryPoint = new EntryPoint();
        new InvestmentExecutionFactory(entryPoint, factory);
        vm.stopBroadcast();
    }
}
