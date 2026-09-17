// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {AssetRegistry} from "../src/AssetRegistry.sol";
import {EquiVault} from "../src/EquiVault.sol";
import {InvestmentEscrow} from "../src/InvestmentEscrow.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {ISwapRouter} from "../src/interfaces/ISwapRouter.sol";
import {MockOracle, MockOracleRoute, MockToken} from "./mocks/Mocks.sol";

contract RejectingRecoveryToken is MockToken {
    mapping(address recipient => bool rejected) internal _rejected;

    constructor() MockToken(18) {}

    function setRejected(address recipient, bool rejected) external {
        _rejected[recipient] = rejected;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (_rejected[to]) return false;
        return super.transfer(to, amount);
    }
}

contract InvestmentRecoveryTest is Test {
    uint256 internal constant UNIT = 1e6;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    AssetRegistry internal registry;
    MockToken internal settlement;
    MockToken internal tokenA;
    MockToken internal tokenB;
    MockOracle internal oracleA;
    MockOracle internal oracleB;
    MockOracleRoute internal routeA;
    MockOracleRoute internal routeB;
    EquiVault internal vault;
    InvestmentEscrow internal escrow;

    function setUp() public {
        settlement = new MockToken(6);
        tokenA = new MockToken(18);
        tokenB = new MockToken(18);
        registry = new AssetRegistry(address(this), address(this));
        oracleA = new MockOracle();
        oracleB = new MockOracle();
        routeA = new MockOracleRoute(registry, settlement, 100);
        routeB = new MockOracleRoute(registry, settlement, 100);
        _register(address(tokenA), oracleA, address(routeA));
        _register(address(tokenB), oracleB, address(routeB));
        oracleA.setPrice(1e18, block.timestamp);
        oracleB.setPrice(1e18, block.timestamp);
        tokenA.mint(address(routeA), 10_000_000e18);
        tokenB.mint(address(routeB), 10_000_000e18);

        address[] memory assets = new address[](2);
        assets[0] = address(tokenA);
        assets[1] = address(tokenB);
        uint16[] memory weights = new uint16[](2);
        weights[0] = 5_000;
        weights[1] = 5_000;
        vault = new EquiVault(
            settlement, registry, address(this), assets, weights, 0, 100, EquiVault.TimelockMode.Immutable, 0, 0, 0
        );
        escrow = InvestmentEscrow(vault.investmentEscrow());
    }

    function testStopBeforeFillClosesRequestAndBlocksReplayOrDoubleStop() public {
        uint256 requestId = _request(ALICE, 100 * UNIT);

        vm.expectEmit(true, true, false, true, address(escrow));
        emit InvestmentEscrow.RequestStopped(requestId, ALICE, 100 * UNIT);
        vm.prank(ALICE);
        escrow.stop(requestId);

        InvestmentEscrow.Request memory request = escrow.getRequest(requestId);
        assertEq(uint256(request.status), uint256(InvestmentEscrow.RequestStatus.Closed));
        assertEq(request.deposited, request.refunded);
        assertEq(request.available, 0);
        assertEq(request.spent, 0);
        assertEq(settlement.balanceOf(ALICE), 100 * UNIT);

        vm.expectRevert(
            abi.encodeWithSelector(
                InvestmentEscrow.RequestNotOpen.selector, requestId, InvestmentEscrow.RequestStatus.Closed
            )
        );
        escrow.fill(requestId, 0, 50 * UNIT, 0, block.timestamp);

        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(
                InvestmentEscrow.RequestNotOpen.selector, requestId, InvestmentEscrow.RequestStatus.Closed
            )
        );
        escrow.stop(requestId);

        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(
                InvestmentEscrow.RequestNotStopped.selector, requestId, InvestmentEscrow.RequestStatus.Closed
            )
        );
        escrow.claim(requestId, 0);
    }

    function testOnlyOwnerCanStopOrClaimAndFullSpendRemainsClaimable() public {
        uint256 requestId = _request(ALICE, 100 * UNIT);
        escrow.fill(requestId, 0, 50 * UNIT, 0, block.timestamp);
        escrow.fill(requestId, 1, 50 * UNIT, 1, block.timestamp);
        assertEq(escrow.getRequest(requestId).available, 0);

        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(InvestmentEscrow.NotRequestOwner.selector, BOB, ALICE));
        escrow.stop(requestId);

        vm.prank(ALICE);
        escrow.stop(requestId);
        assertEq(uint256(escrow.getRequest(requestId).status), uint256(InvestmentEscrow.RequestStatus.Stopped));

        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(InvestmentEscrow.NotRequestOwner.selector, BOB, ALICE));
        escrow.claim(requestId, 0);

        vm.prank(ALICE);
        escrow.claim(requestId, 0);
        vm.prank(ALICE);
        escrow.claim(requestId, 1);
        assertEq(tokenA.balanceOf(ALICE), 49.5e18);
        assertEq(tokenB.balanceOf(ALICE), 49.5e18);
        assertEq(uint256(escrow.getRequest(requestId).status), uint256(InvestmentEscrow.RequestStatus.Closed));
    }

    function testPartialIntegrationThenOutagesStopRefundsAndNewRequestIsIsolated() public {
        uint256 requestId = _request(ALICE, 500_000 * UNIT);

        escrow.fill(requestId, 0, 50_000 * UNIT, 0, block.timestamp);
        escrow.fill(requestId, 1, 50_000 * UNIT, 1, block.timestamp);
        uint256 integratedShares = escrow.integrate(requestId, 2);
        assertGt(integratedShares, 0);
        assertEq(vault.balanceOf(ALICE), integratedShares);
        assertEq(vault.costBasis(ALICE), 100_000 * UNIT);

        escrow.fill(requestId, 0, 50_000 * UNIT, 3, block.timestamp);
        escrow.fill(requestId, 1, 50_000 * UNIT, 4, block.timestamp);
        InvestmentEscrow.Request memory beforeStop = escrow.getRequest(requestId);
        assertEq(beforeStop.available, 300_000 * UNIT);
        assertEq(beforeStop.spent, 200_000 * UNIT);
        assertEq(beforeStop.integratedCost, 100_000 * UNIT);

        vm.mockCallRevert(
            address(routeA),
            abi.encodeWithSelector(ISwapRouter.swapExactIn.selector, address(settlement), address(tokenA)),
            abi.encodeWithSignature("Error(string)", "route unavailable")
        );
        vm.expectRevert("route unavailable");
        escrow.fill(requestId, 0, 50_000 * UNIT, 5, block.timestamp);
        vm.clearMockedCalls();
        oracleA.setFails(true);
        oracleB.setFails(true);

        vm.expectEmit(true, true, false, true, address(escrow));
        emit InvestmentEscrow.RequestStopped(requestId, ALICE, 300_000 * UNIT);
        vm.prank(ALICE);
        escrow.stop(requestId);

        InvestmentEscrow.Request memory stopped = escrow.getRequest(requestId);
        assertEq(stopped.available, 0);
        assertEq(stopped.refunded, 300_000 * UNIT);
        assertEq(stopped.deposited, stopped.spent + stopped.refunded);
        assertEq(vault.balanceOf(ALICE), integratedShares);
        assertEq(vault.costBasis(ALICE), 100_000 * UNIT);
        assertEq(settlement.balanceOf(ALICE), 300_000 * UNIT);

        vm.expectEmit(true, true, true, true, address(escrow));
        emit InvestmentEscrow.PositionClaimed(requestId, ALICE, address(tokenA), 49_500e18, 50_000 * UNIT);
        vm.prank(ALICE);
        escrow.claim(requestId, 0);

        uint256 firstClaimBalance = tokenA.balanceOf(ALICE);
        (uint256 remainingQuantity, uint256 remainingCost) = escrow.positions(requestId, address(tokenB));
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(InvestmentEscrow.EmptyPosition.selector, requestId, address(tokenA)));
        escrow.claim(requestId, 0);
        assertEq(tokenA.balanceOf(ALICE), firstClaimBalance);
        (uint256 quantityAfterRetry, uint256 costAfterRetry) = escrow.positions(requestId, address(tokenB));
        assertEq(quantityAfterRetry, remainingQuantity);
        assertEq(costAfterRetry, remainingCost);

        vm.expectEmit(true, true, true, true, address(escrow));
        emit InvestmentEscrow.PositionClaimed(requestId, ALICE, address(tokenB), 49_500e18, 50_000 * UNIT);
        vm.prank(ALICE);
        escrow.claim(requestId, 1);

        assertEq(tokenA.balanceOf(ALICE), 49_500e18);
        assertEq(tokenB.balanceOf(ALICE), 49_500e18);
        assertEq(uint256(escrow.getRequest(requestId).status), uint256(InvestmentEscrow.RequestStatus.Closed));
        assertEq(vault.balanceOf(ALICE), integratedShares);
        assertEq(vault.costBasis(ALICE), 100_000 * UNIT);

        vm.prank(ALICE);
        settlement.approve(address(escrow), 100_000 * UNIT);
        uint256 newRequestId = _create(ALICE, 100_000 * UNIT);
        InvestmentEscrow.Request memory newRequest = escrow.getRequest(newRequestId);
        assertEq(newRequestId, requestId + 1);
        assertEq(newRequest.available, 100_000 * UNIT);
        assertEq(newRequest.spent, 0);
        assertEq(newRequest.refunded, 0);
        assertEq(escrow.getRequest(requestId).refunded, 300_000 * UNIT);
    }

    function testRejectedClaimLeavesOtherPositionRecoverable() public {
        RejectingRecoveryToken rejectingToken = new RejectingRecoveryToken();
        MockOracle rejectingOracle = new MockOracle();
        MockOracleRoute rejectingRoute = new MockOracleRoute(registry, settlement, 100);
        _register(address(rejectingToken), rejectingOracle, address(rejectingRoute));
        rejectingOracle.setPrice(1e18, block.timestamp);
        rejectingToken.mint(address(rejectingRoute), 10_000_000e18);

        address[] memory assets = new address[](2);
        assets[0] = address(rejectingToken);
        assets[1] = address(tokenB);
        uint16[] memory weights = new uint16[](2);
        weights[0] = 5_000;
        weights[1] = 5_000;
        EquiVault recoveryVault = new EquiVault(
            settlement, registry, address(this), assets, weights, 0, 100, EquiVault.TimelockMode.Immutable, 0, 0, 0
        );
        InvestmentEscrow recoveryEscrow = InvestmentEscrow(recoveryVault.investmentEscrow());

        uint256 requestId = _requestFor(recoveryEscrow, recoveryVault, ALICE, 100 * UNIT);
        recoveryEscrow.fill(requestId, 0, 50 * UNIT, 0, block.timestamp);
        recoveryEscrow.fill(requestId, 1, 50 * UNIT, 1, block.timestamp);
        vm.prank(ALICE);
        recoveryEscrow.stop(requestId);

        rejectingToken.setRejected(ALICE, true);
        vm.prank(ALICE);
        vm.expectRevert();
        recoveryEscrow.claim(requestId, 0);
        (uint256 rejectedQuantity, uint256 rejectedCost) = recoveryEscrow.positions(requestId, address(rejectingToken));
        assertEq(rejectedQuantity, 49.5e18);
        assertEq(rejectedCost, 50 * UNIT);

        vm.prank(ALICE);
        recoveryEscrow.claim(requestId, 1);
        assertEq(tokenB.balanceOf(ALICE), 49.5e18);
        assertEq(uint256(recoveryEscrow.getRequest(requestId).status), uint256(InvestmentEscrow.RequestStatus.Stopped));

        rejectingToken.setRejected(ALICE, false);
        vm.prank(ALICE);
        recoveryEscrow.claim(requestId, 0);
        assertEq(rejectingToken.balanceOf(ALICE), 49.5e18);
        assertEq(uint256(recoveryEscrow.getRequest(requestId).status), uint256(InvestmentEscrow.RequestStatus.Closed));
    }

    function _request(address owner, uint256 amount) internal returns (uint256) {
        settlement.mint(owner, amount);
        vm.prank(owner);
        settlement.approve(address(escrow), amount);
        return _create(owner, amount);
    }

    function _create(address owner, uint256 amount) internal returns (uint256) {
        return _createFor(escrow, vault, owner, amount);
    }

    function _requestFor(InvestmentEscrow escrow_, EquiVault vault_, address owner, uint256 amount)
        internal
        returns (uint256)
    {
        settlement.mint(owner, amount);
        vm.prank(owner);
        settlement.approve(address(escrow_), amount);
        return _createFor(escrow_, vault_, owner, amount);
    }

    function _createFor(InvestmentEscrow escrow_, EquiVault vault_, address owner, uint256 amount)
        internal
        returns (uint256)
    {
        bytes32 version = vault_.investmentVersion();
        vm.prank(owner);
        return escrow_.createRequest(amount, version, block.timestamp);
    }

    function _register(address asset, IPriceOracle oracle, address route) internal {
        registry.registerAsset(asset, oracle, oracle, route, 1 days);
    }
}
