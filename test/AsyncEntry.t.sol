// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AssetRegistry} from "../src/AssetRegistry.sol";
import {EquiVault} from "../src/EquiVault.sol";
import {AsyncEntryLib} from "../src/AsyncEntryLib.sol";
import {InvestmentEscrow} from "../src/InvestmentEscrow.sol";
import {ISwapRouter} from "../src/interfaces/ISwapRouter.sol";
import {MockToken, MockOracle, MockOracleRoute} from "./mocks/Mocks.sol";

contract AsyncEntryTest is Test {
    MockToken internal settlement;
    MockToken internal a;
    MockToken internal b;
    MockOracle internal oracle;
    AssetRegistry internal registry;
    EquiVault internal vault;
    InvestmentEscrow internal escrow;
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        vm.warp(1_000_000);
        settlement = new MockToken(6);
        a = new MockToken(18);
        b = new MockToken(6);
        oracle = new MockOracle();
        oracle.setPrice(1e18, block.timestamp);
        registry = new AssetRegistry(address(this), address(0x1234));
        MockOracleRoute route = new MockOracleRoute(registry, settlement, 100);
        a.mint(address(route), 10_000_000e18);
        b.mint(address(route), 10_000_000e6);
        registry.registerAsset(address(a), oracle, oracle, address(route), 1 hours);
        registry.registerAsset(address(b), oracle, oracle, address(route), 1 hours);
        address[] memory assets = new address[](2);
        assets[0] = address(a);
        assets[1] = address(b);
        uint16[] memory weights = new uint16[](2);
        weights[0] = 5_000;
        weights[1] = 5_000;
        vault = new EquiVault(
            settlement, registry, address(this), assets, weights, 1000, 100, EquiVault.TimelockMode.Instant, 0, 0, 0
        );
        escrow = InvestmentEscrow(vault.investmentEscrow());
    }

    function _request(address owner, uint256 amount) internal returns (uint256 id) {
        settlement.mint(owner, amount);
        bytes32 version = vault.investmentVersion();
        vm.startPrank(owner);
        settlement.approve(address(escrow), amount);
        id = escrow.createRequest(amount, version, block.timestamp);
        vm.stopPrank();
    }

    function _buy(uint256 id, uint256 amount) internal {
        escrow.fill(id, 0, amount / 2, 0, block.timestamp);
        escrow.fill(id, 1, amount - amount / 2, 1, block.timestamp);
    }

    function _seedExisting() internal {
        // Seed the reference NAV through the existing sync path plus an explicit donation.
        settlement.mint(alice, 800_000e6);
        vm.startPrank(alice);
        settlement.approve(address(vault), 800_000e6);
        vault.enter(EquiVault.EnterParams(800_000e6, alice, 1, new uint256[](0), block.timestamp, 0));
        vm.stopPrank();
        // Fee was 1%; these donations restore the reference NAV to 800k. Donations are priced,
        // never assigned to an escrow request or mistaken for that request's purchase.
        a.mint(address(vault), 4_000e18);
        b.mint(address(vault), 4_000e6);
    }

    function testNet198Over998AndHistoricalCost() public {
        _seedExisting();
        uint256 beforeSupply = vault.totalSupply();
        uint256 id = _request(bob, 200_000e6);
        _buy(id, 200_000e6);
        assertEq(vault.balanceOf(bob), 0);
        assertEq(vault.totalAssets(), 800_000e6);
        escrow.integrate(id, 2);
        assertEq(vault.totalAssets(), 998_000e6);
        assertEq(vault.costBasis(bob), 200_000e6);
        uint256 shares = vault.balanceOf(bob);
        assertApproxEqAbs(shares * 1e18 / (beforeSupply + shares), uint256(198e18) / 998, 1e9);
        assertEq(a.balanceOf(address(escrow)), 0);
        assertEq(b.balanceOf(address(escrow)), 0);
    }

    function testFuzzProportionalIntegrationPreservesOldHoldings(uint96 rawAmount) public {
        _seedExisting();
        // Both legs and the exact 1% mock fee must be representable in the six-decimal
        // token. Inadmissible rounding is exercised separately by the rejection tests.
        uint256 amount = bound(uint256(rawAmount), 10e6, 1_000_000e6) / 200 * 200;
        uint256 id = _request(bob, amount);
        _buy(id, amount);
        uint256 supply = vault.totalSupply();
        uint256 beforeA = a.balanceOf(address(vault));
        uint256 beforeB = b.balanceOf(address(vault));
        escrow.integrate(id, 2);
        assertGe(a.balanceOf(address(vault)) * supply, beforeA * vault.totalSupply());
        assertGe(b.balanceOf(address(vault)) * supply, beforeB * vault.totalSupply());
        assertLe(vault.costBasis(bob), amount);
    }

    function testBootstrapRequiresEveryLegAndMintsNet() public {
        uint256 id = _request(alice, 100e6);
        escrow.fill(id, 0, 50e6, 0, block.timestamp);
        vm.expectRevert(AsyncEntryLib.InvalidTranche.selector);
        escrow.integrate(id, 1);
        assertEq(vault.totalSupply(), 0);
        escrow.fill(id, 1, 50e6, 1, block.timestamp);
        escrow.integrate(id, 2);
        assertEq(vault.totalAssets(), 99e6);
        assertEq(vault.totalSupply(), 99e12);
        assertEq(vault.costBasis(alice), 100e6);
    }

    function testChangedConfigurationFreezesOldRequestButRecoveryWorks() public {
        uint256 id = _request(alice, 100e6);
        escrow.fill(id, 0, 50e6, 0, block.timestamp);
        bytes32 beforeVersion = vault.investmentVersion();
        vault.proposeParameters(400, 100);
        assertTrue(vault.investmentVersion() != beforeVersion);
        vm.expectRevert();
        escrow.fill(id, 1, 50e6, 1, block.timestamp);
        vm.prank(alice);
        escrow.stop(id);
        vm.prank(alice);
        escrow.claim(id, 0);
        assertEq(settlement.balanceOf(alice), 50e6);
        assertEq(a.balanceOf(alice), 49.5e18);
        assertEq(vault.costBasis(alice), 0);
    }

    function testExistingHoldingsDetermineCompositionNotTargetWeights() public {
        _seedExisting();
        a.mint(address(vault), 400_000e18);
        uint256 id = _request(bob, 300e6);
        escrow.fill(id, 0, 200e6, 0, block.timestamp);
        escrow.fill(id, 1, 100e6, 1, block.timestamp);
        uint256 aBefore = a.balanceOf(address(vault));
        uint256 bBefore = b.balanceOf(address(vault));
        escrow.integrate(id, 2);
        assertEq((a.balanceOf(address(vault)) - aBefore) / 1e12, 2 * (b.balanceOf(address(vault)) - bBefore));
    }

    function testDonationCannotCreditPersonalRequest() public {
        uint256 id = _request(alice, 100e6);
        a.mint(address(escrow), 1_000_000e18);
        settlement.mint(address(escrow), 1_000_000e6);
        _buy(id, 100e6);
        escrow.integrate(id, 2);
        assertEq(vault.totalAssets(), 99e6);
        assertEq(a.balanceOf(address(escrow)), 1_000_000e18);
        assertEq(settlement.balanceOf(address(escrow)), 1_000_000e6);
    }

    function testUnauthorizedMintRejected() public {
        vm.expectRevert(EquiVault.NotInvestmentEscrow.selector);
        vault.integrateInvestment(alice, new uint256[](2), type(uint256).max);
    }

    function testBootstrapDonationPricedWithVirtualOffsets() public {
        a.mint(address(vault), 100e18);
        b.mint(address(vault), 100e6);
        uint256 id = _request(alice, 100e6);
        _buy(id, 100e6);
        escrow.integrate(id, 2);
        assertEq(vault.totalSupply(), Math.mulDiv(99e6, 1e6, 200e6 + 1));
    }

    function testTokenValueFloorCannotBypassRoundingBudget() public {
        MockToken second = new MockToken(18);
        address route = registry.assetConfig(address(a)).liquidityRoute;
        second.mint(route, 1_000_000e18);
        registry.registerAsset(address(second), oracle, oracle, route, 1 hours);
        address[] memory assets = new address[](2);
        assets[0] = address(a);
        assets[1] = address(second);
        uint16[] memory weights = new uint16[](2);
        weights[0] = 5_000;
        weights[1] = 5_000;
        vault = new EquiVault(
            settlement, registry, address(this), assets, weights, 1000, 100, EquiVault.TimelockMode.Instant, 0, 0, 0
        );
        escrow = InvestmentEscrow(vault.investmentEscrow());
        settlement.mint(alice, 100e6);
        vm.startPrank(alice);
        settlement.approve(address(vault), 100e6);
        vault.enter(EquiVault.EnterParams(100e6, alice, 1, new uint256[](0), block.timestamp, 0));
        vm.stopPrank();
        uint256 id = _request(bob, 4);
        _buy(id, 4);
        // Each received leg is worth 1.98 settlement atomic units; flooring both to 1
        // previously minted only ~50.5% of that value while claiming zero rounding loss.
        vm.expectRevert(AsyncEntryLib.ExcessiveRounding.selector);
        escrow.integrate(id, 2);
        assertEq(vault.balanceOf(bob), 0);
        vm.prank(bob);
        escrow.stop(id);
        vm.prank(bob);
        escrow.claim(id, 0);
        vm.prank(bob);
        escrow.claim(id, 1);
        assertEq(a.balanceOf(bob), 1.98e12);
        assertEq(second.balanceOf(bob), 1.98e12);
    }

    function testShareQuantizationCannotBypassRoundingBudget() public {
        a.mint(address(vault), 500_000e18);
        b.mint(address(vault), 500_000e6);
        uint256 id = _request(alice, 100e6);
        _buy(id, 100e6);
        vm.expectRevert(AsyncEntryLib.ExcessiveRounding.selector);
        escrow.integrate(id, 2);
        vm.prank(alice);
        escrow.stop(id);
        vm.prank(alice);
        escrow.claim(id, 0);
        assertEq(vault.balanceOf(alice), 0);
    }

    function testFiveHundredThousandResumesAfterRouteFailureAcrossTranches() public {
        uint256 id = _request(alice, 500_000e6);
        escrow.fill(id, 0, 50_000e6, 0, block.timestamp);
        address route = registry.assetConfig(address(b)).liquidityRoute;
        vm.mockCallRevert(
            route,
            abi.encodeWithSelector(ISwapRouter.swapExactIn.selector, address(settlement), address(b)),
            abi.encodeWithSignature("Error(string)", "route unavailable")
        );
        vm.expectRevert("route unavailable");
        escrow.fill(id, 1, 50_000e6, 1, block.timestamp);
        assertEq(escrow.getRequest(id).available, 450_000e6);
        assertEq(escrow.getRequest(id).sequence, 1);
        (uint256 acquired,) = escrow.positions(id, address(a));
        assertEq(acquired, 49_500e18);
        assertEq(vault.balanceOf(alice), 0);
        vm.clearMockedCalls();
        escrow.fill(id, 1, 50_000e6, 1, block.timestamp);
        escrow.integrate(id, 2);
        for (uint256 tranche = 1; tranche < 5; ++tranche) {
            uint256 sequence = tranche * 3;
            escrow.fill(id, 0, 50_000e6, sequence, block.timestamp);
            escrow.fill(id, 1, 50_000e6, sequence + 1, block.timestamp);
            escrow.integrate(id, sequence + 2);
        }
        InvestmentEscrow.Request memory result = escrow.getRequest(id);
        assertEq(uint256(result.status), uint256(InvestmentEscrow.RequestStatus.Closed));
        assertEq(result.spent, 500_000e6);
        assertEq(result.integratedCost, 500_000e6);
        assertEq(result.available + result.refunded, 0);
        assertEq(vault.totalAssets(), 495_000e6);
        assertEq(vault.costBasis(alice), 500_000e6);
        assertEq(result.shares, vault.balanceOf(alice));
    }
}
