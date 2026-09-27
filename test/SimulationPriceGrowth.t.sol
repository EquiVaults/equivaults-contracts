// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {AssetRegistry} from "../src/AssetRegistry.sol";
import {EquiVault} from "../src/EquiVault.sol";
import {InvestmentEscrow} from "../src/InvestmentEscrow.sol";
import {MockOracle, MockOracleRoute, MockToken} from "./mocks/Mocks.sol";

/// @notice Exercises the on-chain valuation behind local simulation: controlled oracle doubling
/// after 90 days changes quoted exit value while holdings retain their quantity. These are not projections.
contract SimulationPriceGrowthTest is Test {
    uint256 internal constant UNIT = 1e6;
    uint256 internal constant INVESTMENT = 100_000 * UNIT;
    uint256 internal constant NINETY_DAYS = 90 days;

    address internal constant ALICE = address(0xA11CE);

    MockToken internal settlement;
    MockToken internal asset;
    MockOracle internal oracle;
    AssetRegistry internal registry;
    MockOracleRoute internal route;
    EquiVault internal vault;
    InvestmentEscrow internal escrow;

    function setUp() public {
        vm.warp(1_000_000);
        settlement = new MockToken(6);
        asset = new MockToken(18);
        oracle = new MockOracle();
        oracle.setPrice(1e18, block.timestamp);
        registry = new AssetRegistry(address(this), address(0xBEEF));
        route = new MockOracleRoute(registry, settlement, 100); // 1% route fee
        asset.mint(address(route), 10_000_000e18);
        registry.registerAsset(address(asset), oracle, oracle, address(route), 1 days);

        address[] memory assets = new address[](1);
        assets[0] = address(asset);
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10_000;
        vault = new EquiVault(
            settlement, registry, address(this), assets, weights, 1_000, 100, EquiVault.TimelockMode.Instant, 0, 0, 0
        );
        escrow = InvestmentEscrow(vault.investmentEscrow());
    }

    function testDirectInvestmentQuoteExitValueDoublesAfterNinetyDaysAndOracleRefresh() public {
        uint256 shares = _enterDirect(INVESTMENT);
        uint256 holdingsBefore = asset.balanceOf(address(vault));
        uint256 quoteBefore = vault.quoteExitValue(shares);

        // The initial quote measures the real 1% route fee; it does not assert a fictional 100k -> 200k return.
        assertEq(quoteBefore, 99_000 * UNIT);
        assertEq(vault.costBasis(ALICE), INVESTMENT);

        vm.warp(block.timestamp + NINETY_DAYS);
        oracle.setPrice(2e18, block.timestamp);

        assertEq(asset.balanceOf(address(vault)), holdingsBefore);
        assertEq(vault.balanceOf(ALICE), shares);
        assertEq(vault.costBasis(ALICE), INVESTMENT);
        assertEq(vault.quoteExitValue(shares), quoteBefore * 2);
    }

    function testTimeAloneDoesNotCreateQuotedGainWhenTheOraclePriceIsConstant() public {
        uint256 shares = _enterDirect(INVESTMENT);
        uint256 quoteBefore = vault.quoteExitValue(shares);

        vm.warp(block.timestamp + NINETY_DAYS);
        oracle.setPrice(1e18, block.timestamp); // refresh freshness without changing the price

        assertEq(vault.quoteExitValue(shares), quoteBefore);
        assertEq(vault.balanceOf(ALICE), shares);
        assertEq(vault.costBasis(ALICE), INVESTMENT);
    }

    function testPartiallyBoughtAsyncInvestmentOnlyGainsOnItsBoughtPortion() public {
        uint256 requestId = _createRequest(INVESTMENT);
        uint256 boughtCost = 40_000 * UNIT;
        escrow.fill(requestId, 0, boughtCost, 0, block.timestamp);
        escrow.integrate(requestId, 1);

        uint256 shares = vault.balanceOf(ALICE);
        uint256 boughtQuoteBefore = vault.quoteExitValue(shares);
        InvestmentEscrow.Request memory request = escrow.getRequest(requestId);
        assertEq(boughtQuoteBefore, 39_600 * UNIT);
        assertEq(request.available, INVESTMENT - boughtCost);
        assertEq(request.integratedCost, boughtCost);
        assertEq(settlement.balanceOf(address(escrow)), INVESTMENT - boughtCost);

        vm.warp(block.timestamp + NINETY_DAYS);
        oracle.setPrice(2e18, block.timestamp);

        // The untouched 60k remains settlement in the personal escrow. Only the 40k bought
        // (less its real route fee) is represented by vault shares and participates in the move.
        assertEq(vault.quoteExitValue(shares), boughtQuoteBefore * 2);
        assertLt(vault.quoteExitValue(shares), INVESTMENT * 2);
        request = escrow.getRequest(requestId);
        assertEq(request.available, INVESTMENT - boughtCost);
        assertEq(settlement.balanceOf(address(escrow)), INVESTMENT - boughtCost);
    }

    function _enterDirect(uint256 amount) internal returns (uint256 shares) {
        settlement.mint(ALICE, amount);
        vm.startPrank(ALICE);
        settlement.approve(address(vault), amount);
        vault.enter(EquiVault.EnterParams(amount, ALICE, 1, new uint256[](0), block.timestamp, 0));
        vm.stopPrank();
        shares = vault.balanceOf(ALICE);
    }

    function _createRequest(uint256 amount) internal returns (uint256 requestId) {
        settlement.mint(ALICE, amount);
        vm.startPrank(ALICE);
        settlement.approve(address(escrow), amount);
        requestId = escrow.createRequest(amount, vault.investmentVersion(), block.timestamp);
        vm.stopPrank();
    }
}
