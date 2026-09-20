// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {AssetRegistry} from "../src/AssetRegistry.sol";
import {EquiVault} from "../src/EquiVault.sol";
import {InvestmentEscrow} from "../src/InvestmentEscrow.sol";
import {InvestmentExecutionAccount} from "../src/InvestmentExecutionAccount.sol";
import {InvestmentExecutionFactory} from "../src/InvestmentExecutionFactory.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {IEntryPoint} from "../lib/account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "../lib/account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {EntryPoint} from "../lib/account-abstraction/contracts/core/EntryPoint.sol";
import {MockOracle, MockOracleRoute, MockToken} from "./mocks/Mocks.sol";

contract InvestmentExecutionAccountTest is Test {
    using MessageHashUtils for bytes32;

    uint256 private constant UNIT = 1e6;
    uint256 private constant EXECUTOR_KEY = 0xA11CE;
    address private constant ALICE = address(0xA11CE0);
    address private constant BOB = address(0xB0B0);
    address private constant BUNDLER = address(0xB0D1E);
    address private constant BENEFICIARY = address(0xBEEF);

    EntryPoint private entryPoint;
    AssetRegistry private registry;
    MockToken private settlement;
    MockToken private tokenA;
    MockToken private tokenB;
    VaultFactory private vaultFactory;
    InvestmentExecutionFactory private accountFactory;
    InvestmentEscrow private escrow;
    address private executor;

    function setUp() public {
        executor = vm.addr(EXECUTOR_KEY);
        vm.deal(ALICE, 10 ether);
        vm.deal(BOB, 10 ether);
        vm.deal(BUNDLER, 10 ether);
        entryPoint = new EntryPoint();
        registry = new AssetRegistry(address(this), address(this));
        settlement = new MockToken(6);
        tokenA = new MockToken(18);
        tokenB = new MockToken(18);
        MockOracle oracleA = new MockOracle();
        MockOracle oracleB = new MockOracle();
        MockOracleRoute routeA = new MockOracleRoute(registry, settlement, 0);
        MockOracleRoute routeB = new MockOracleRoute(registry, settlement, 0);
        registry.registerAsset(address(tokenA), oracleA, oracleA, address(routeA), 1 days);
        registry.registerAsset(address(tokenB), oracleB, oracleB, address(routeB), 1 days);
        oracleA.setPrice(1e18, block.timestamp);
        oracleB.setPrice(1e18, block.timestamp);
        tokenA.mint(address(routeA), 1_000_000e18);
        tokenB.mint(address(routeB), 1_000_000e18);

        vaultFactory = new VaultFactory(settlement, registry);
        address[] memory assets = new address[](2);
        assets[0] = address(tokenA);
        assets[1] = address(tokenB);
        uint16[] memory weights = new uint16[](2);
        weights[0] = 5_000;
        weights[1] = 5_000;
        EquiVault vault = EquiVault(
            vaultFactory.createVault(address(this), assets, weights, 0, 100, EquiVault.TimelockMode.Immutable, 0, 0, 0)
        );
        escrow = InvestmentEscrow(vault.investmentEscrow());
        accountFactory = new InvestmentExecutionFactory(entryPoint, vaultFactory);
        settlement.mint(ALICE, 1_000 * UNIT);
        settlement.mint(BOB, 1_000 * UNIT);
        vm.prank(ALICE);
        settlement.approve(address(escrow), type(uint256).max);
        vm.prank(BOB);
        settlement.approve(address(escrow), type(uint256).max);
    }

    function testHandleOpsExecutesOnlyTheBoundRequestAndChargesOnlyItsDeposit() public {
        uint256 aliceRequest = _request(ALICE);
        uint256 bobRequest = _request(BOB);
        InvestmentExecutionAccount aliceAccount = _account(ALICE, aliceRequest, 1 ether);
        InvestmentExecutionAccount bobAccount = _account(BOB, bobRequest, 1 ether);
        uint256 bobBudget = bobAccount.getBudget();

        PackedUserOperation memory operation = _operation(
            aliceAccount,
            abi.encodeCall(InvestmentExecutionAccount.executeFill, (0, 50 * UNIT, 0, block.timestamp + 1 days)),
            0,
            0,
            EXECUTOR_KEY
        );
        _handle(operation);

        InvestmentEscrow.Request memory alice = escrow.getRequest(aliceRequest);
        InvestmentEscrow.Request memory bob = escrow.getRequest(bobRequest);
        assertEq(alice.spent, 50 * UNIT);
        assertEq(bob.spent, 0);
        assertLt(aliceAccount.getBudget(), 1 ether);
        assertEq(bobAccount.getBudget(), bobBudget);
        assertEq(aliceAccount.attempts(), 1);
        assertFalse(aliceAccount.paused());
    }

    function test_FailedPaidOperationStaysPausedAndCannotBeRepeated() public {
        uint256 requestId = _request(ALICE);
        InvestmentExecutionAccount account = _account(ALICE, requestId, 1 ether);
        escrow.fill(requestId, 0, 50 * UNIT, 0, block.timestamp + 1 days);
        PackedUserOperation memory stale = _operation(
            account,
            abi.encodeCall(InvestmentExecutionAccount.executeFill, (1, 50 * UNIT, 0, block.timestamp + 1 days)),
            0,
            0,
            EXECUTOR_KEY
        );
        _handle(stale);
        assertTrue(account.paused());
        assertEq(account.attempts(), 1);
        assertEq(account.policyEpoch(), 1);

        vm.expectRevert();
        _handle(stale);
        assertTrue(account.paused());
        assertEq(account.attempts(), 1);
    }

    function testWrongSignerAndArbitraryCallAreRejectedBeforeAnyAttempt() public {
        uint256 requestId = _request(ALICE);
        InvestmentExecutionAccount account = _account(ALICE, requestId, 1 ether);
        PackedUserOperation memory wrongSigner = _operation(
            account,
            abi.encodeCall(InvestmentExecutionAccount.executeFill, (0, 50 * UNIT, 0, block.timestamp + 1 days)),
            0,
            0,
            0xB0B
        );
        vm.expectRevert();
        _handle(wrongSigner);
        assertEq(account.attempts(), 0);

        PackedUserOperation memory arbitrary = _operation(account, abi.encodeCall(InvestmentExecutionAccount.topUp, ()), 0, 0, EXECUTOR_KEY);
        vm.expectRevert();
        _handle(arbitrary);
        assertEq(account.attempts(), 0);
        assertFalse(account.paused());
    }

    function testOwnerWithdrawalInvalidatesOldSignatureAndNeverResetsAttempts() public {
        uint256 requestId = _request(ALICE);
        InvestmentExecutionAccount account = _account(ALICE, requestId, 1 ether);
        PackedUserOperation memory oldOperation = _operation(
            account,
            abi.encodeCall(InvestmentExecutionAccount.executeFill, (0, 50 * UNIT, 0, block.timestamp + 1 days)),
            0,
            0,
            EXECUTOR_KEY
        );
        vm.prank(ALICE);
        account.withdrawBudget(0.1 ether);
        assertTrue(account.paused());
        assertEq(account.policyEpoch(), 1);
        vm.expectRevert();
        _handle(oldOperation);
        vm.prank(ALICE);
        account.resume();
        assertEq(account.attempts(), 0);
        assertEq(account.policyEpoch(), 2);
    }

    function _request(address investor) private returns (uint256) {
        bytes32 version = EquiVault(address(escrow.vault())).investmentVersion();
        vm.prank(investor);
        return escrow.createRequest(100 * UNIT, version, block.timestamp + 1 days);
    }

    function _account(address investor, uint256 requestId, uint256 funding)
        private
        returns (InvestmentExecutionAccount account)
    {
        InvestmentExecutionAccount.Policy memory policy = InvestmentExecutionAccount.Policy({
            maxFeePerGas: uint128(1 gwei),
            maxAttemptFee: uint128(0.01 ether),
            maxAttempts: 3,
            validUntil: uint48(block.timestamp + 1 days),
            minFillAmount: 10 * UNIT
        });
        vm.prank(investor);
        account = accountFactory.createAccount{value: funding}(address(escrow), requestId, executor, policy);
        assertEq(accountFactory.accounts(address(escrow), requestId), address(account));
    }

    function _operation(
        InvestmentExecutionAccount account,
        bytes memory callData,
        uint192 epoch,
        uint64 sequence,
        uint256 signingKey
    ) private returns (PackedUserOperation memory operation) {
        operation.sender = address(account);
        operation.nonce = (uint256(epoch) << 64) | sequence;
        operation.callData = callData;
        operation.accountGasLimits = bytes32((uint256(250_000) << 128) | 400_000);
        operation.preVerificationGas = 50_000;
        operation.gasFees = bytes32((uint256(1 gwei) << 128) | 1 gwei);
        bytes32 digest = entryPoint.getUserOpHash(operation).toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signingKey, digest);
        operation.signature = abi.encodePacked(r, s, v);
    }

    function _handle(PackedUserOperation memory operation) private {
        PackedUserOperation[] memory operations = new PackedUserOperation[](1);
        operations[0] = operation;
        vm.prank(BUNDLER, BUNDLER);
        entryPoint.handleOps(operations, payable(BENEFICIARY));
    }
}
