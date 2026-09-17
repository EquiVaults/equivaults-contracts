// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AssetRegistry} from "../src/AssetRegistry.sol";
import {EquiVault} from "../src/EquiVault.sol";
import {InvestmentEscrow} from "../src/InvestmentEscrow.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {ISwapRouter} from "../src/interfaces/ISwapRouter.sol";
import {MockOracle, MockOracleRoute, MockToken} from "./mocks/Mocks.sol";

contract RejectingToken is MockToken {
    mapping(address => bool) public rejectedRecipient;

    constructor(uint8 tokenDecimals) MockToken(tokenDecimals) {}

    function setRejectedRecipient(address recipient, bool rejected) external {
        rejectedRecipient[recipient] = rejected;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (rejectedRecipient[to]) return false;
        return super.transfer(to, amount);
    }
}

/// @dev Returns an arbitrary amount without transferring output, modeling a malicious route which ignores minOut.
contract LyingRoute is ISwapRouter {
    IERC20 immutable settlement;

    constructor(IERC20 settlement_) {
        settlement = settlement_;
    }

    function swapExactIn(address assetIn, address, uint256 amountIn, uint256) external returns (uint256) {
        settlement.transferFrom(msg.sender, address(this), amountIn);
        require(assetIn == address(settlement), "wrong input");
        return type(uint256).max;
    }
}

/// @dev Deliberately ignores `minAmountOut`; escrow must enforce the actual receiver balance delta.
contract FixedOutputRoute is ISwapRouter {
    IERC20 immutable settlement;
    IERC20 immutable asset;
    uint256 public output;

    constructor(IERC20 settlement_, IERC20 asset_) {
        settlement = settlement_;
        asset = asset_;
    }

    function setOutput(uint256 output_) external {
        output = output_;
    }

    function swapExactIn(address assetIn, address assetOut, uint256 amountIn, uint256) external returns (uint256) {
        require(assetIn == address(settlement) && assetOut == address(asset), "wrong pair");
        settlement.transferFrom(msg.sender, address(this), amountIn);
        asset.transfer(msg.sender, output);
        return output;
    }
}

contract ReentrantRoute is ISwapRouter {
    IERC20 immutable settlement;
    IERC20 immutable asset;
    InvestmentEscrow public escrow;
    uint256 public requestId;
    bool public reentryAttempted;

    constructor(IERC20 settlement_, IERC20 asset_) {
        settlement = settlement_;
        asset = asset_;
    }

    function configure(InvestmentEscrow escrow_, uint256 requestId_) external {
        escrow = escrow_;
        requestId = requestId_;
    }

    function swapExactIn(address assetIn, address assetOut, uint256 amountIn, uint256) external returns (uint256) {
        require(assetIn == address(settlement) && assetOut == address(asset), "wrong pair");
        settlement.transferFrom(msg.sender, address(this), amountIn);
        reentryAttempted = true;
        (bool ok,) =
            address(escrow).call(abi.encodeCall(InvestmentEscrow.fill, (requestId, 0, 1, 0, block.timestamp + 1 days)));
        require(!ok, "reentry unexpectedly succeeded");
        asset.transfer(msg.sender, amountIn * 1e12);
        return amountIn * 1e12;
    }
}

contract InvestmentEscrowTest is Test {
    uint256 internal constant UNIT = 1e6;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    AssetRegistry internal registry;
    MockToken internal settlement;
    RejectingToken internal tokenA;
    MockToken internal tokenB;
    MockOracle internal oracleA;
    MockOracle internal oracleB;
    MockOracleRoute internal routeA;
    MockOracleRoute internal routeB;
    EquiVault internal vault;
    InvestmentEscrow internal escrow;

    function setUp() public {
        settlement = new MockToken(6);
        tokenA = new RejectingToken(18);
        tokenB = new MockToken(18);
        registry = new AssetRegistry(address(this), address(this));
        oracleA = new MockOracle();
        oracleB = new MockOracle();
        routeA = new MockOracleRoute(registry, settlement, 0);
        routeB = new MockOracleRoute(registry, settlement, 0);
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
        settlement.mint(ALICE, 1_000 * UNIT);
        settlement.mint(BOB, 1_000 * UNIT);
        vm.prank(ALICE);
        settlement.approve(address(escrow), type(uint256).max);
        vm.prank(BOB);
        settlement.approve(address(escrow), type(uint256).max);
    }

    function testTwoRequestsAreIsolatedAndFirstCompleteTrancheIntegrates() public {
        uint256 aliceRequest = _create(ALICE, 100 * UNIT);
        uint256 bobRequest = _create(BOB, 100 * UNIT);

        escrow.fill(aliceRequest, 0, 50 * UNIT, 0, block.timestamp);
        escrow.fill(aliceRequest, 1, 50 * UNIT, 1, block.timestamp);

        (uint256 bobA, uint256 bobACost) = escrow.positions(bobRequest, address(tokenA));
        assertEq(bobA, 0);
        assertEq(bobACost, 0);
        InvestmentEscrow.Request memory aliceBefore = escrow.getRequest(aliceRequest);
        assertEq(aliceBefore.available, 0);
        assertEq(aliceBefore.spent, 100 * UNIT);

        uint256 shares = escrow.integrate(aliceRequest, 2);
        assertGt(shares, 0);
        assertEq(vault.balanceOf(ALICE), shares);
        assertEq(tokenA.balanceOf(address(vault)), 50e18);
        assertEq(tokenB.balanceOf(address(vault)), 50e18);
        assertEq(tokenA.balanceOf(address(escrow)), 0);
        assertEq(tokenB.balanceOf(address(escrow)), 0);
        assertEq(vault.balanceOf(BOB), 0);
        InvestmentEscrow.Request memory bob = escrow.getRequest(bobRequest);
        assertEq(bob.available, 100 * UNIT);
    }

    function test_RevertWhen_FillFailsDoesNotAlterPreviouslyBoughtPosition() public {
        uint256 requestId = _create(ALICE, 100 * UNIT);
        escrow.fill(requestId, 0, 50 * UNIT, 0, block.timestamp);
        oracleB.setFails(true);

        vm.expectRevert();
        escrow.fill(requestId, 1, 50 * UNIT, 1, block.timestamp);

        (uint256 quantity, uint256 cost) = escrow.positions(requestId, address(tokenA));
        assertEq(quantity, 50e18);
        assertEq(cost, 50 * UNIT);
        InvestmentEscrow.Request memory request = escrow.getRequest(requestId);
        assertEq(request.available, 50 * UNIT);
        assertEq(request.spent, 50 * UNIT);
        assertEq(request.sequence, 1);
    }

    function testLyingRouteCannotCreditReportedOutput() public {
        MockToken badAsset = new MockToken(18);
        MockOracle badOracle = new MockOracle();
        LyingRoute lying = new LyingRoute(settlement);
        _register(address(badAsset), badOracle, address(lying));
        badOracle.setPrice(1e18, block.timestamp);
        EquiVault badVault = _vaultWith(address(badAsset), address(tokenB));
        InvestmentEscrow badEscrow = InvestmentEscrow(badVault.investmentEscrow());
        vm.prank(ALICE);
        settlement.approve(address(badEscrow), type(uint256).max);
        uint256 requestId = _createFor(badEscrow, badVault, ALICE, 100 * UNIT);

        vm.expectRevert();
        badEscrow.fill(requestId, 0, 50 * UNIT, 0, block.timestamp);

        InvestmentEscrow.Request memory request = badEscrow.getRequest(requestId);
        assertEq(request.available, 100 * UNIT);
        assertEq(request.spent, 0);
        assertEq(settlement.balanceOf(address(lying)), 0);
    }

    function testLowDecimalRouteCannotExploitDoubleFloorSlippage() public {
        MockToken indivisible = new MockToken(0);
        MockToken regular = new MockToken(18);
        MockOracle indivisibleOracle = new MockOracle();
        MockOracle regularOracle = new MockOracle();
        FixedOutputRoute maliciousRoute = new FixedOutputRoute(settlement, indivisible);
        MockOracleRoute regularRoute = new MockOracleRoute(registry, settlement, 0);
        _register(address(indivisible), indivisibleOracle, address(maliciousRoute));
        _register(address(regular), regularOracle, address(regularRoute));
        indivisibleOracle.setPrice(1_000e18, block.timestamp);
        regularOracle.setPrice(1e18, block.timestamp);
        indivisible.mint(address(maliciousRoute), 2);
        regular.mint(address(regularRoute), 10_000e18);
        EquiVault lowDecimalVault = _vaultWith(address(indivisible), address(regular));
        InvestmentEscrow lowDecimalEscrow = InvestmentEscrow(lowDecimalVault.investmentEscrow());
        settlement.mint(ALICE, 4_000 * UNIT);
        vm.prank(ALICE);
        settlement.approve(address(lowDecimalEscrow), type(uint256).max);
        uint256 requestId = _createFor(lowDecimalEscrow, lowDecimalVault, ALICE, 4_000 * UNIT);

        maliciousRoute.setOutput(1);
        vm.expectRevert();
        lowDecimalEscrow.fill(requestId, 0, 2_000 * UNIT, 0, block.timestamp);
        assertEq(lowDecimalEscrow.getRequest(requestId).available, 4_000 * UNIT);

        maliciousRoute.setOutput(2);
        lowDecimalEscrow.fill(requestId, 0, 2_000 * UNIT, 0, block.timestamp);
        (uint256 quantity, uint256 cost) = lowDecimalEscrow.positions(requestId, address(indivisible));
        assertEq(quantity, 2);
        assertEq(cost, 2_000 * UNIT);
    }

    function testSingleLegCannotConsumeTheWholeRequestBudget() public {
        uint256 requestId = _create(ALICE, 100 * UNIT);
        assertEq(escrow.maxFillAmount(requestId, 0), 50 * UNIT);
        assertEq(escrow.maxFillAmount(requestId, 1), 50 * UNIT);
        vm.expectRevert(
            abi.encodeWithSelector(InvestmentEscrow.FillExceedsLegBudget.selector, requestId, 0, 100 * UNIT, 50 * UNIT)
        );
        escrow.fill(requestId, 0, 100 * UNIT, 0, block.timestamp);
        escrow.fill(requestId, 0, 50 * UNIT, 0, block.timestamp);
        assertEq(escrow.maxFillAmount(requestId, 1), 50 * UNIT);
        escrow.fill(requestId, 1, 50 * UNIT, 1, block.timestamp);
        assertGt(escrow.integrate(requestId, 2), 0);
    }

    function testStaleSequenceCannotReplayFill() public {
        uint256 requestId = _create(ALICE, 100 * UNIT);
        escrow.fill(requestId, 0, 50 * UNIT, 0, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(InvestmentEscrow.SequenceMismatch.selector, 0, 1));
        escrow.fill(requestId, 1, 50 * UNIT, 0, block.timestamp);
    }

    function testStopAndClaimNeedNoLiveOracleOrOpenRegistry() public {
        uint256 requestId = _create(ALICE, 100 * UNIT);
        escrow.fill(requestId, 0, 50 * UNIT, 0, block.timestamp);
        oracleA.setFails(true);
        registry.setAssetStatus(address(tokenA), AssetRegistry.AssetStatus.Quarantined);

        vm.prank(ALICE);
        escrow.stop(requestId);
        assertEq(settlement.balanceOf(ALICE), 950 * UNIT);
        vm.prank(ALICE);
        escrow.claim(requestId, 0);
        assertEq(tokenA.balanceOf(ALICE), 50e18);
        assertEq(uint256(escrow.getRequest(requestId).status), uint256(InvestmentEscrow.RequestStatus.Closed));
    }

    function testStopWithNoSettlementLeavesAssetsClaimable() public {
        uint256 requestId = _create(ALICE, 100 * UNIT);
        escrow.fill(requestId, 0, 50 * UNIT, 0, block.timestamp);
        escrow.fill(requestId, 1, 50 * UNIT, 1, block.timestamp);
        vm.prank(ALICE);
        escrow.stop(requestId);
        assertEq(settlement.balanceOf(ALICE), 900 * UNIT);
        vm.prank(ALICE);
        escrow.claim(requestId, 0);
        vm.prank(ALICE);
        escrow.claim(requestId, 1);
        assertEq(uint256(escrow.getRequest(requestId).status), uint256(InvestmentEscrow.RequestStatus.Closed));
    }

    function test_RevertWhen_ClaimFailsRollsBackPositionAndDoesNotBlockRetry() public {
        uint256 requestId = _create(ALICE, 100 * UNIT);
        escrow.fill(requestId, 0, 50 * UNIT, 0, block.timestamp);
        vm.prank(ALICE);
        escrow.stop(requestId);
        tokenA.setRejectedRecipient(ALICE, true);

        vm.prank(ALICE);
        vm.expectRevert();
        escrow.claim(requestId, 0);
        (uint256 quantity, uint256 cost) = escrow.positions(requestId, address(tokenA));
        assertEq(quantity, 50e18);
        assertEq(cost, 50 * UNIT);

        tokenA.setRejectedRecipient(ALICE, false);
        vm.prank(ALICE);
        escrow.claim(requestId, 0);
        assertEq(tokenA.balanceOf(ALICE), 50e18);
    }

    function testOwnerChecksAreEnforced() public {
        uint256 requestId = _create(ALICE, 100 * UNIT);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(InvestmentEscrow.NotRequestOwner.selector, BOB, ALICE));
        escrow.stop(requestId);
    }

    function testRouteReentryIsRejectedWhileTheFillSucceeds() public {
        MockToken reentrantAsset = new MockToken(18);
        ReentrantRoute reentrantRoute = new ReentrantRoute(settlement, reentrantAsset);
        MockOracle reentrantOracle = new MockOracle();
        _register(address(reentrantAsset), reentrantOracle, address(reentrantRoute));
        reentrantOracle.setPrice(1e18, block.timestamp);
        reentrantAsset.mint(address(reentrantRoute), 1_000e18);
        EquiVault reentrantVault = _vaultWith(address(reentrantAsset), address(tokenB));
        InvestmentEscrow reentrantEscrow = InvestmentEscrow(reentrantVault.investmentEscrow());
        vm.prank(ALICE);
        settlement.approve(address(reentrantEscrow), type(uint256).max);
        uint256 requestId = _createFor(reentrantEscrow, reentrantVault, ALICE, 100 * UNIT);
        reentrantRoute.configure(reentrantEscrow, requestId);

        reentrantEscrow.fill(requestId, 0, 50 * UNIT, 0, block.timestamp);

        assertTrue(reentrantRoute.reentryAttempted());
        (uint256 quantity,) = reentrantEscrow.positions(requestId, address(reentrantAsset));
        assertEq(quantity, 50e18);
        assertEq(reentrantEscrow.getRequest(requestId).sequence, 1);
    }

    function _create(address owner, uint256 amount) internal returns (uint256) {
        return _createFor(escrow, vault, owner, amount);
    }

    function _createFor(InvestmentEscrow escrow_, EquiVault vault_, address owner, uint256 amount)
        internal
        returns (uint256)
    {
        bytes32 version = vault_.investmentVersion();
        vm.prank(owner);
        return escrow_.createRequest(amount, version, block.timestamp);
    }

    function _vaultWith(address first, address second) internal returns (EquiVault result) {
        address[] memory assets = new address[](2);
        assets[0] = first;
        assets[1] = second;
        uint16[] memory weights = new uint16[](2);
        weights[0] = 5_000;
        weights[1] = 5_000;
        result = new EquiVault(
            settlement, registry, address(this), assets, weights, 0, 100, EquiVault.TimelockMode.Immutable, 0, 0, 0
        );
    }

    function _register(address asset, IPriceOracle oracle, address route) internal {
        registry.registerAsset(asset, oracle, oracle, route, 1 days);
    }
}
