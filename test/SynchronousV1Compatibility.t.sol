// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {AssetRegistry} from "../src/AssetRegistry.sol";
import {EquiVault} from "../src/EquiVault.sol";
import {InvestmentEscrow} from "../src/InvestmentEscrow.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {LegacyEquiVault} from "./fixtures/synchronous-v1/LegacyEquiVault.sol";
import {LegacyVaultFactory} from "./fixtures/synchronous-v1/LegacyVaultFactory.sol";
import {MockOracle, MockPool, MockToken} from "./mocks/Mocks.sol";

/// @notice Local coexistence coverage for the published v2 deployment and the retained v1 fixture.
contract SynchronousV1CompatibilityTest is Test {
    uint48 internal constant MAX_PRICE_AGE = 1 hours;
    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal manager = makeAddr("manager");
    address internal alice = makeAddr("alice");

    MockToken internal settlement;
    MockToken internal tokenA;
    MockToken internal tokenB;
    AssetRegistry internal registry;
    VaultFactory internal v2Factory;
    LegacyVaultFactory internal v1Factory;
    EquiVault internal v2Vault;
    LegacyEquiVault internal v1Vault;

    function setUp() public {
        vm.warp(1_000_000);
        settlement = new MockToken(6);
        tokenA = new MockToken(18);
        tokenB = new MockToken(6);
        MockOracle primaryA = new MockOracle();
        MockOracle fallbackA = new MockOracle();
        MockOracle primaryB = new MockOracle();
        MockOracle fallbackB = new MockOracle();
        primaryA.setPrice(100e18, block.timestamp);
        fallbackA.setPrice(99e18, block.timestamp);
        primaryB.setPrice(50e18, block.timestamp);
        fallbackB.setPrice(49e18, block.timestamp);
        MockPool poolA = new MockPool(settlement, tokenA, 30);
        MockPool poolB = new MockPool(settlement, tokenB, 30);
        settlement.mint(address(this), 20_000_000e6);
        tokenA.mint(address(this), 100_000e18);
        tokenB.mint(address(this), 200_000e6);
        settlement.approve(address(poolA), type(uint256).max);
        settlement.approve(address(poolB), type(uint256).max);
        tokenA.approve(address(poolA), type(uint256).max);
        tokenB.approve(address(poolB), type(uint256).max);
        poolA.seed(10_000_000e6, 100_000e18);
        poolB.seed(10_000_000e6, 200_000e6);

        registry = new AssetRegistry(admin, treasury);
        vm.startPrank(admin);
        registry.registerAsset(address(tokenA), primaryA, fallbackA, address(poolA), MAX_PRICE_AGE);
        registry.registerAsset(address(tokenB), primaryB, fallbackB, address(poolB), MAX_PRICE_AGE);
        vm.stopPrank();

        v2Factory = new VaultFactory(settlement, registry);
        v1Factory = new LegacyVaultFactory(settlement, registry);
        v2Vault = EquiVault(_createV2());
        v1Vault = LegacyEquiVault(_createV1());
    }

    function testVersionDiscoverySeparatesV1AndV2() public view {
        assertEq(v2Factory.protocolVersion(), 2);
        assertEq(v2Vault.protocolVersion(), 2);
        assertEq(InvestmentEscrow(v2Vault.investmentEscrow()).protocolVersion(), 2);
        (bool v1FactoryHasGetter,) = address(v1Factory).staticcall(abi.encodeCall(VaultFactory.protocolVersion, ()));
        (bool v1VaultHasGetter,) = address(v1Vault).staticcall(abi.encodeCall(EquiVault.protocolVersion, ()));
        assertFalse(v1FactoryHasGetter);
        assertFalse(v1VaultHasGetter);
        assertTrue(address(v1Vault).codehash != address(v2Vault).codehash);
    }

    function testLegacyPositionIsIndependentAndCanWithdrawSynchronously() public {
        uint256 amount = 1_000e6;
        settlement.mint(alice, amount);
        vm.startPrank(alice);
        settlement.approve(address(v1Vault), amount);
        uint256 shares = v1Vault.enter(
            LegacyEquiVault.EnterParams({
                settlementIn: amount,
                receiver: alice,
                minSharesOut: 1,
                minAmountsOut: new uint256[](0),
                deadline: block.timestamp,
                proposalId: 0
            })
        );
        assertGt(shares, 0);
        assertEq(v2Vault.balanceOf(alice), 0, "v2 position must stay empty");
        InvestmentEscrow escrow = InvestmentEscrow(v2Vault.investmentEscrow());
        settlement.mint(alice, 500e6);
        settlement.approve(address(escrow), 500e6);
        uint256 requestId = escrow.createRequest(500e6, v2Vault.investmentVersion(), block.timestamp);
        assertEq(escrow.getRequest(requestId).available, 500e6);
        assertEq(v1Vault.balanceOf(alice), shares, "v2 escrow request cannot alter the legacy position");
        uint256 balanceBeforeExit = settlement.balanceOf(alice);
        bool[] memory sellTokens = new bool[](2);
        sellTokens[0] = true;
        sellTokens[1] = true;
        uint256 settlementOut = v1Vault.exit(
            LegacyEquiVault.ExitParams({
                shares: shares,
                receiver: alice,
                sellTokens: sellTokens,
                minAmountsOut: new uint256[](0),
                minSettlementOut: 1,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();
        assertGt(settlementOut, 0);
        assertGt(settlement.balanceOf(alice), balanceBeforeExit);
        assertEq(v1Vault.balanceOf(alice), 0);
    }

    function testV2EscrowCreatesAnIndependentHybridRequest() public {
        uint256 amount = 1_000e6;
        InvestmentEscrow escrow = InvestmentEscrow(v2Vault.investmentEscrow());
        settlement.mint(alice, amount);
        vm.startPrank(alice);
        settlement.approve(address(escrow), amount);
        uint256 requestId = escrow.createRequest(amount, v2Vault.investmentVersion(), block.timestamp);
        vm.stopPrank();

        InvestmentEscrow.Request memory request = escrow.getRequest(requestId);
        assertEq(request.owner, alice);
        assertEq(request.deposited, amount);
        assertEq(request.available, amount);
        assertEq(v1Vault.balanceOf(alice), 0, "legacy position must remain separate");
    }

    function _createV2() internal returns (address) {
        return v2Factory.createVault(
            manager, _assets(), _weights(), 1_000, 300, EquiVault.TimelockMode.Delayed, 1 days, 0, 0
        );
    }

    function _createV1() internal returns (address) {
        return v1Factory.createVault(
            manager, _assets(), _weights(), 1_000, 300, LegacyEquiVault.TimelockMode.Delayed, 1 days, 0, 0
        );
    }

    function _assets() internal view returns (address[] memory assets) {
        assets = new address[](2);
        assets[0] = address(tokenA);
        assets[1] = address(tokenB);
    }

    function _weights() internal pure returns (uint16[] memory weights) {
        weights = new uint16[](2);
        weights[0] = 6_000;
        weights[1] = 4_000;
    }
}
