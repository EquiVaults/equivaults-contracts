// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {InvestmentEscrow} from "./InvestmentEscrow.sol";
import {EquiVault} from "./EquiVault.sol";
import {VaultFactory} from "./VaultFactory.sol";
import {InvestmentExecutionAccount} from "./InvestmentExecutionAccount.sol";
import {IEntryPoint} from "../lib/account-abstraction/contracts/interfaces/IEntryPoint.sol";

/// @notice Deploys one investor-owned, self-funded execution account for each authenticated escrow request.
contract InvestmentExecutionFactory {
    IEntryPoint public immutable entryPoint;
    VaultFactory public immutable vaultFactory;

    mapping(address escrow => mapping(uint256 requestId => address account)) public accounts;

    error InvalidAddress();
    error InvalidEscrow(address escrow);
    error NotRequestOwner(address caller, address owner);
    error AccountAlreadyExists(address account);

    event AccountCreated(
        address indexed account,
        address indexed escrow,
        uint256 indexed requestId,
        address owner,
        address executor,
        uint256 initialFunding
    );

    constructor(IEntryPoint entryPoint_, VaultFactory vaultFactory_) {
        if (address(entryPoint_) == address(0) || address(vaultFactory_) == address(0)) revert InvalidAddress();
        entryPoint = entryPoint_;
        vaultFactory = vaultFactory_;
    }

    function createAccount(
        address escrow_,
        uint256 requestId,
        address executor,
        InvestmentExecutionAccount.Policy calldata policy
    ) external payable returns (InvestmentExecutionAccount account) {
        InvestmentEscrow escrow = InvestmentEscrow(escrow_);
        address vault = address(escrow.vault());
        if (!vaultFactory.isVault(vault) || EquiVault(vault).investmentEscrow() != escrow_) revert InvalidEscrow(escrow_);
        InvestmentEscrow.Request memory request = escrow.getRequest(requestId);
        if (request.owner != msg.sender) revert NotRequestOwner(msg.sender, request.owner);
        if (accounts[escrow_][requestId] != address(0)) revert AccountAlreadyExists(accounts[escrow_][requestId]);

        account = new InvestmentExecutionAccount{value: msg.value}(entryPoint, escrow, requestId, msg.sender, executor, policy);
        accounts[escrow_][requestId] = address(account);
        emit AccountCreated(address(account), escrow_, requestId, msg.sender, executor, msg.value);
    }
}
