// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AssetRegistry} from "../AssetRegistry.sol";

/// @notice Vault-side boundary for personal investment escrows.
interface IAsyncVault {
    function settlementAsset() external view returns (IERC20);
    function registry() external view returns (AssetRegistry);
    function basketAssets() external view returns (address[] memory);
    function basketWeightsBps() external view returns (uint16[] memory);
    function settlementDecimals() external view returns (uint8);
    function maxSlippageBps() external view returns (uint16);
    function totalSupply() external view returns (uint256);
    function investmentVersion() external view returns (bytes32);
    function previewInvestment(uint256[] calldata available)
        external
        view
        returns (uint256 shares, uint256[] memory amounts, uint256 valueReceived);
    function integrateInvestment(address owner, uint256[] calldata amounts, uint256 acquisitionCost)
        external
        returns (uint256 shares);
}
