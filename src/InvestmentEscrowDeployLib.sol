// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AssetRegistry} from "./AssetRegistry.sol";
import {InvestmentEscrow} from "./InvestmentEscrow.sol";

/// @notice Deployment helper called by EquiVault's constructor through DELEGATECALL.
/// @dev `address(this)` is the constructing vault in that context, avoiding a constructor callback into it.
library InvestmentEscrowDeployLib {
    function deploy(IERC20 settlement, AssetRegistry registry) external returns (address) {
        return address(new InvestmentEscrow(address(this), settlement, registry));
    }
}
