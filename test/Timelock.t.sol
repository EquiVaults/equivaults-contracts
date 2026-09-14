// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {AssetRegistry} from "../src/AssetRegistry.sol";
import {EquiVault} from "../src/EquiVault.sol";

import {MockOracle, MockPool, MockToken} from "./mocks/Mocks.sol";

contract TimelockTest is Test {
    uint48 internal constant MAX_PRICE_AGE = 1 hours;
    uint256 internal constant PRICE_A = 100e18; // $100 per whole token
    uint256 internal constant PRICE_B = 50e18; // $50 per whole token
    uint256 internal constant PRICE_C = 200e18; // $200 per whole token
    uint256 internal constant SHARE_SCALE = 1e6; // _decimalsOffset() = 6

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal manager = makeAddr("manager");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    MockToken internal usdc;
    MockToken internal tokenA;
    MockToken internal tokenB;
    MockToken internal tokenC;
    MockOracle internal primaryA;
    MockOracle internal fallbackA;
    MockOracle internal primaryB;
    MockOracle internal fallbackB;
    MockOracle internal primaryC;
    MockOracle internal fallbackC;
    MockPool internal poolA;
    MockPool internal poolB;
    MockPool internal poolC;
    AssetRegistry internal registry;

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new MockToken(6);
        tokenA = new MockToken(18);
        tokenB = new MockToken(6);
        tokenC = new MockToken(18);

        primaryA = new MockOracle();
        fallbackA = new MockOracle();
        primaryB = new MockOracle();
        fallbackB = new MockOracle();
        primaryC = new MockOracle();
        fallbackC = new MockOracle();
        _refreshPrices();

        poolA = new MockPool(usdc, tokenA, 30);
        poolB = new MockPool(usdc, tokenB, 30);
        poolC = new MockPool(usdc, tokenC, 30);
        usdc.mint(address(this), 30_000_000e6);
        tokenA.mint(address(this), 100_000e18);
        tokenB.mint(address(this), 200_000e6);
        tokenC.mint(address(this), 50_000e18);
        usdc.approve(address(poolA), type(uint256).max);
        usdc.approve(address(poolB), type(uint256).max);
        usdc.approve(address(poolC), type(uint256).max);
        tokenA.approve(address(poolA), type(uint256).max);
        tokenB.approve(address(poolB), type(uint256).max);
        tokenC.approve(address(poolC), type(uint256).max);
        poolA.seed(10_000_000e6, 100_000e18);
        poolB.seed(10_000_000e6, 200_000e6);
        poolC.seed(10_000_000e6, 50_000e18);

        registry = new AssetRegistry(admin, treasury);
        vm.startPrank(admin);
        registry.registerAsset(address(tokenA), primaryA, fallbackA, address(poolA), MAX_PRICE_AGE);
        registry.registerAsset(address(tokenB), primaryB, fallbackB, address(poolB), MAX_PRICE_AGE);
        registry.registerAsset(address(tokenC), primaryC, fallbackC, address(poolC), MAX_PRICE_AGE);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function enterVault(EquiVault vault, uint256 settlementIn, address receiver) internal returns (uint256) {
    return vault.enter(EquiVault.EnterParams({
        settlementIn: settlementIn,
        receiver: receiver,
        minSharesOut: 0,
        minAmountsOut: new uint256[](0),
        deadline: type(uint256).max,
        proposalId: 0
    }));
}

function enterVaultWithMins(
    EquiVault vault, uint256 settlementIn, address receiver, uint256[] memory minAmountsOut, uint256 proposalId
) internal returns (uint256) {
    return vault.enter(EquiVault.EnterParams({
        settlementIn: settlementIn,
        receiver: receiver,
        minSharesOut: 0,
        minAmountsOut: minAmountsOut,
        deadline: type(uint256).max,
        proposalId: proposalId
    }));
}

function exitVault(EquiVault vault, uint256 shares, address receiver, bool[] memory sellTokens) internal returns (uint256) {
    return vault.exit(EquiVault.ExitParams({
        shares: shares,
        receiver: receiver,
        sellTokens: sellTokens,
        minAmountsOut: new uint256[](0),
        minSettlementOut: 0,
        deadline: type(uint256).max
    }));
}

/// @dev [A, B] 6000/4000 basket on a fresh vault.
    function _deployVault(EquiVault.TimelockMode mode, uint256 delay)
        internal
        returns (EquiVault vault)
    {
        address[] memory a = _assetsAB();
        uint16[] memory w = _weights(6_000, 4_000);
        vault = new EquiVault(usdc, registry, manager, a, w, 1_000, 100, mode, delay, 0, 0);
    }

    function _assetsAB() internal view returns (address[] memory) {
        address[] memory a = new address[](2);
        a[0] = address(tokenA);
        a[1] = address(tokenB);
        return a;
    }

    function _assetsAC() internal view returns (address[] memory) {
        address[] memory a = new address[](2);
        a[0] = address(tokenA);
        a[1] = address(tokenC);
        return a;
    }

    function _weights(uint16 w0, uint16 w1) internal pure returns (uint16[] memory) {
        uint16[] memory w = new uint16[](2);
        w[0] = w0;
        w[1] = w1;
        return w;
    }

    function _fundAndApprove(address vault, address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.prank(who);
        usdc.approve(vault, type(uint256).max);
    }

    /// @dev Oracle timestamps must be refreshed after any warp beyond MAX_PRICE_AGE.
    function _refreshPrices() internal {
        primaryA.setPrice(PRICE_A, block.timestamp);
        fallbackA.setPrice(99e18, block.timestamp);
        primaryB.setPrice(PRICE_B, block.timestamp);
        fallbackB.setPrice(49e18, block.timestamp);
        primaryC.setPrice(PRICE_C, block.timestamp);
        fallbackC.setPrice(199e18, block.timestamp);
    }

    function _propose(EquiVault vault, address[] memory assets, uint16[] memory weights) internal {
        vm.prank(manager);
        vault.proposeReallocation(assets, weights);
    }

    function _executeReallocation(EquiVault vault, uint256[] memory sellMinOuts, uint256[] memory buyMinOuts)
        internal
    {
        vault.executeReallocation(vault.activeProposal().id, type(uint256).max, sellMinOuts, buyMinOuts);
    }

    // ------------------------------------------------------------------
    // Construction
    // ------------------------------------------------------------------

    function testConstructorRejectsInvalidTimelock() public {
        address[] memory a = _assetsAB();
        uint16[] memory w = _weights(6_000, 4_000);

        vm.expectRevert(abi.encodeWithSelector(EquiVault.InvalidTimelockDelay.selector, uint256(0)));
        new EquiVault(usdc, registry, manager, a, w, 1_000, 100, EquiVault.TimelockMode.Delayed, 0, 0, 0);

        vm.expectRevert(abi.encodeWithSelector(EquiVault.InvalidTimelockDelay.selector, uint256(8 days)));
        new EquiVault(usdc, registry, manager, a, w, 1_000, 100, EquiVault.TimelockMode.Delayed, 8 days, 0, 0);

        vm.expectRevert(abi.encodeWithSelector(EquiVault.InvalidTimelockDelay.selector, uint256(1 days)));
        new EquiVault(usdc, registry, manager, a, w, 1_000, 100, EquiVault.TimelockMode.Instant, 1 days, 0, 0);

    }

    // ------------------------------------------------------------------
    // Trust modes
    // ------------------------------------------------------------------

    function testInstantProposalExecutableImmediately() public {
        EquiVault vault = _deployVault(EquiVault.TimelockMode.Instant, 0);
        _fundAndApprove(address(vault), alice, 1_000e6);
        vm.prank(alice);
        enterVault(vault, 1_000e6, alice);

        _propose(vault, _assetsAC(), _weights(5_000, 5_000));
        uint256 id = vault.activeProposal().id;
        // No warp: executable right away, and permissionless (executed by alice, not the manager).
        vm.prank(alice);
        vault.executeReallocation(id, type(uint256).max, new uint256[](0), new uint256[](0));

        address[] memory assets = vault.basketAssets();
        assertEq(assets.length, 2);
        assertEq(assets[0], address(tokenA));
        assertEq(assets[1], address(tokenC));
        assertEq(vault.basketWeightsBps()[0], 5_000);
        assertEq(vault.basketWeightsBps()[1], 5_000);
        assertEq(vault.activeProposal().id, 0);
    }

    function testDelayedProposalNotExecutableBeforeDelay() public {
        EquiVault vault = _deployVault(EquiVault.TimelockMode.Delayed, 1 days);
        _propose(vault, _assetsAC(), _weights(5_000, 5_000));

        EquiVault.ReallocationProposal memory p = vault.activeProposal();
        assertEq(p.id, 1);
        assertEq(p.executableAt, block.timestamp + 1 days);

        vm.expectRevert(abi.encodeWithSelector(EquiVault.ProposalNotExecutable.selector, p.executableAt));
        vault.executeReallocation(p.id, type(uint256).max, new uint256[](0), new uint256[](0));

        vm.warp(block.timestamp + 1 days);
        _refreshPrices();
        vault.executeReallocation(p.id, type(uint256).max, new uint256[](0), new uint256[](0));
        assertEq(vault.activeProposal().id, 0);
    }

    function testImmutableVaultRefusesProposalsForever() public {
        EquiVault vault = _deployVault(EquiVault.TimelockMode.Immutable, 0);

        vm.expectRevert(EquiVault.TimelockImmutable.selector);
        vm.prank(manager);
        vault.proposeReallocation(_assetsAC(), _weights(5_000, 5_000));

        // Composition is frozen, but ordinary deposits still work.
        _fundAndApprove(address(vault), alice, 1_000e6);
        vm.prank(alice);
        enterVault(vault, 1_000e6, alice);
        assertGt(vault.balanceOf(alice), 0);
    }

    // ------------------------------------------------------------------
    // Proposal lifecycle
    // ------------------------------------------------------------------

    function testOnlyManagerCanProposeAndCancel() public {
        EquiVault vault = _deployVault(EquiVault.TimelockMode.Delayed, 1 days);

        vm.expectRevert(EquiVault.NotManager.selector);
        vm.prank(alice);
        vault.proposeReallocation(_assetsAC(), _weights(5_000, 5_000));

        vm.expectRevert(EquiVault.NoActiveProposal.selector);
        vm.prank(manager);
        vault.cancelReallocation(0);

        _propose(vault, _assetsAC(), _weights(5_000, 5_000));
        uint256 reallocationId = vault.activeProposal().id;
        vm.expectRevert(EquiVault.NotManager.selector);
        vm.prank(alice);
        vault.cancelReallocation(reallocationId);

        vm.prank(manager);
        vault.cancelReallocation(reallocationId);
        assertEq(vault.activeProposal().id, 0);

        vm.expectRevert(EquiVault.NoActiveProposal.selector);
        vm.prank(manager);
        vault.cancelReallocation(reallocationId);

        vm.expectRevert(EquiVault.NoActiveProposal.selector);
        vm.prank(manager);
        vault.cancelParameterUpdate(0);

        vm.prank(manager);
        vault.proposeParameters(500, 50);
        uint256 parameterId = vault.activeParameterProposal().id;
        vm.expectRevert(EquiVault.NotManager.selector);
        vm.prank(alice);
        vault.cancelParameterUpdate(parameterId);

        vm.prank(manager);
        vault.cancelParameterUpdate(parameterId);
        assertEq(vault.activeParameterProposal().id, 0);
    }

    function testSecondProposalRejectedWhileActive() public {
        EquiVault vault = _deployVault(EquiVault.TimelockMode.Delayed, 1 days);
        _propose(vault, _assetsAC(), _weights(5_000, 5_000));

        vm.expectRevert(abi.encodeWithSelector(EquiVault.ProposalAlreadyActive.selector, uint256(1)));
        vm.prank(manager);
        vault.proposeReallocation(_assetsAC(), _weights(5_000, 5_000));
    }

    function testReplaceRestartsFullDelay() public {
        EquiVault vault = _deployVault(EquiVault.TimelockMode.Delayed, 1 days);
        _propose(vault, _assetsAC(), _weights(5_000, 5_000));
        uint256 id = vault.activeProposal().id;
        vm.prank(manager);
        vault.cancelReallocation(id);

        vm.warp(block.timestamp + 12 hours); // inside the original window
        _propose(vault, _assetsAB(), _weights(6_000, 4_000));

        EquiVault.ReallocationProposal memory p = vault.activeProposal();
        assertEq(p.id, 2); // fresh identifier
        assertEq(p.executableAt, block.timestamp + 1 days); // full delay restarted
    }

    function testExecuteWithoutProposalReverts() public {
        EquiVault vault = _deployVault(EquiVault.TimelockMode.Instant, 0);
        vm.expectRevert(EquiVault.NoActiveProposal.selector);
        vault.executeReallocation(0, type(uint256).max, new uint256[](0), new uint256[](0));
    }

    function testCancellationRejectsStaleReallocationIdAfterReplacement() public {
        EquiVault vault = _deployVault(EquiVault.TimelockMode.Instant, 0);
        _propose(vault, _assetsAC(), _weights(5_000, 5_000));
        uint256 staleId = vault.activeProposal().id;
        vm.prank(manager);
        vault.cancelReallocation(staleId);
        _propose(vault, _assetsAC(), _weights(5_000, 5_000));
        uint256 replacementId = vault.activeProposal().id;

        vm.expectRevert(abi.encodeWithSelector(EquiVault.ProposalIdMismatch.selector, replacementId, uint256(0)));
        vm.prank(manager);
        vault.cancelReallocation(0);

        vm.expectRevert(abi.encodeWithSelector(EquiVault.ProposalIdMismatch.selector, replacementId, staleId));
        vm.prank(manager);
        vault.cancelReallocation(staleId);

        assertEq(vault.activeProposal().id, replacementId);
        assertEq(vault.basketAssets()[0], address(tokenA));
        assertEq(vault.basketAssets()[1], address(tokenB));
        assertEq(vault.basketWeightsBps()[0], 6_000);
        assertEq(vault.basketWeightsBps()[1], 4_000);

        vm.expectEmit(true, true, false, true);
        emit EquiVault.ReallocationCancelled(replacementId);
        vm.prank(manager);
        vault.cancelReallocation(replacementId);
        assertEq(vault.activeProposal().id, 0);
        assertEq(vault.basketAssets()[0], address(tokenA));
        assertEq(vault.basketAssets()[1], address(tokenB));
        assertEq(vault.basketWeightsBps()[0], 6_000);
        assertEq(vault.basketWeightsBps()[1], 4_000);
    }

    function testExecutionRejectsStaleReallocationIdAfterReplacement() public {
        EquiVault vault = _deployVault(EquiVault.TimelockMode.Instant, 0);
        _propose(vault, _assetsAC(), _weights(5_000, 5_000));
        uint256 staleId = vault.activeProposal().id;
        vm.prank(manager);
        vault.cancelReallocation(staleId);
        _propose(vault, _assetsAC(), _weights(5_000, 5_000));

        vm.expectRevert(abi.encodeWithSelector(EquiVault.ProposalIdMismatch.selector, uint256(2), staleId));
        vault.executeReallocation(staleId, type(uint256).max, new uint256[](0), new uint256[](0));

        assertEq(vault.activeProposal().id, 2);
        assertEq(vault.basketAssets()[1], address(tokenB));
    }

    function testReallocationExecutionDeadlineBoundaries() public {
        EquiVault vault = _deployVault(EquiVault.TimelockMode.Instant, 0);
        _propose(vault, _assetsAC(), _weights(5_000, 5_000));
        uint256 id = vault.activeProposal().id;

        vm.expectRevert(abi.encodeWithSelector(EquiVault.DeadlineExpired.selector, block.timestamp));
        vault.executeReallocation(id, block.timestamp - 1, new uint256[](0), new uint256[](0));
        assertEq(vault.activeProposal().id, id);
        assertEq(vault.basketAssets()[1], address(tokenB));

        vm.prank(alice);
        vault.executeReallocation(id, block.timestamp, new uint256[](0), new uint256[](0));
        assertEq(vault.activeProposal().id, 0);
        assertEq(vault.basketAssets()[1], address(tokenC));

        EquiVault laterVault = _deployVault(EquiVault.TimelockMode.Instant, 0);
        _propose(laterVault, _assetsAC(), _weights(5_000, 5_000));
        uint256 laterId = laterVault.activeProposal().id;
        vm.prank(bob);
        laterVault.executeReallocation(laterId, block.timestamp + 1, new uint256[](0), new uint256[](0));
        assertEq(laterVault.activeProposal().id, 0);
        assertEq(laterVault.basketAssets()[1], address(tokenC));
    }

    function testExecutedProposalsCannotBeExecutedOrCancelled() public {
        EquiVault vault = _deployVault(EquiVault.TimelockMode.Instant, 0);
        _propose(vault, _assetsAC(), _weights(5_000, 5_000));
        uint256 reallocationId = vault.activeProposal().id;
        vault.executeReallocation(reallocationId, type(uint256).max, new uint256[](0), new uint256[](0));

        vm.expectRevert(EquiVault.NoActiveProposal.selector);
        vault.executeReallocation(reallocationId, type(uint256).max, new uint256[](0), new uint256[](0));
        vm.expectRevert(EquiVault.NoActiveProposal.selector);
        vm.prank(manager);
        vault.cancelReallocation(reallocationId);

        vm.prank(manager);
        vault.proposeParameters(500, 50);
        uint256 parameterId = vault.activeParameterProposal().id;
        vault.executeParameterUpdate(parameterId, type(uint256).max);

        vm.expectRevert(EquiVault.NoActiveProposal.selector);
        vault.executeParameterUpdate(parameterId, type(uint256).max);
        vm.expectRevert(EquiVault.NoActiveProposal.selector);
        vm.prank(manager);
        vault.cancelParameterUpdate(parameterId);
    }

    function testCancellationRejectsStaleParameterIdAfterReplacement() public {
        EquiVault vault = _deployVault(EquiVault.TimelockMode.Instant, 0);
        vm.prank(manager);
        vault.proposeParameters(500, 50);
        uint256 staleId = vault.activeParameterProposal().id;
        vm.prank(manager);
        vault.cancelParameterUpdate(staleId);
        vm.prank(manager);
        vault.proposeParameters(600, 75);
        uint256 replacementId = vault.activeParameterProposal().id;

        vm.expectRevert(abi.encodeWithSelector(EquiVault.ProposalIdMismatch.selector, replacementId, uint256(0)));
        vm.prank(manager);
        vault.cancelParameterUpdate(0);

        vm.expectRevert(abi.encodeWithSelector(EquiVault.ProposalIdMismatch.selector, replacementId, staleId));
        vm.prank(manager);
        vault.cancelParameterUpdate(staleId);

        assertEq(vault.activeParameterProposal().id, replacementId);
        assertEq(vault.driftThresholdBps(), 300);
        assertEq(vault.rebalanceSlippageBps(), 100);

        vm.expectEmit(true, true, false, true);
        emit EquiVault.ParameterUpdateCancelled(replacementId);
        vm.prank(manager);
        vault.cancelParameterUpdate(replacementId);
        assertEq(vault.activeParameterProposal().id, 0);
        assertEq(vault.driftThresholdBps(), 300);
        assertEq(vault.rebalanceSlippageBps(), 100);
    }

    function testExecutionRejectsStaleParameterIdAfterReplacement() public {
        EquiVault vault = _deployVault(EquiVault.TimelockMode.Instant, 0);
        vm.prank(manager);
        vault.proposeParameters(500, 50);
        uint256 staleId = vault.activeParameterProposal().id;
        vm.prank(manager);
        vault.cancelParameterUpdate(staleId);
        vm.prank(manager);
        vault.proposeParameters(600, 75);

        vm.expectRevert(abi.encodeWithSelector(EquiVault.ProposalIdMismatch.selector, uint256(2), staleId));
        vault.executeParameterUpdate(staleId, type(uint256).max);

        assertEq(vault.activeParameterProposal().id, 2);
        assertEq(vault.driftThresholdBps(), 300);
        assertEq(vault.rebalanceSlippageBps(), 100);
    }

    function testParameterUpdateExecutionDeadlineBoundaries() public {
        EquiVault vault = _deployVault(EquiVault.TimelockMode.Instant, 0);
        vm.prank(manager);
        vault.proposeParameters(500, 50);
        uint256 id = vault.activeParameterProposal().id;

        vm.expectRevert(abi.encodeWithSelector(EquiVault.DeadlineExpired.selector, block.timestamp));
        vault.executeParameterUpdate(id, block.timestamp - 1);
        assertEq(vault.activeParameterProposal().id, id);
        assertEq(vault.driftThresholdBps(), 300);
        assertEq(vault.rebalanceSlippageBps(), 100);

        vm.prank(alice);
        vault.executeParameterUpdate(id, block.timestamp);
        assertEq(vault.activeParameterProposal().id, 0);
        assertEq(vault.driftThresholdBps(), 500);
        assertEq(vault.rebalanceSlippageBps(), 50);

        EquiVault laterVault = _deployVault(EquiVault.TimelockMode.Instant, 0);
        vm.prank(manager);
        laterVault.proposeParameters(600, 75);
        uint256 laterId = laterVault.activeParameterProposal().id;
        vm.prank(bob);
        laterVault.executeParameterUpdate(laterId, block.timestamp + 1);
        assertEq(laterVault.activeParameterProposal().id, 0);
        assertEq(laterVault.driftThresholdBps(), 600);
        assertEq(laterVault.rebalanceSlippageBps(), 75);
    }

    function testProposalEventsEmitFullHistory() public {
        EquiVault vault = _deployVault(EquiVault.TimelockMode.Delayed, 1 days);
        address[] memory assets = _assetsAC();
        uint16[] memory weights = _weights(5_000, 5_000);

        vm.expectEmit(true, true, true, true);
        emit EquiVault.ReallocationProposed(1, manager, block.timestamp + 1 days, assets, weights);
        vm.prank(manager);
        vault.proposeReallocation(assets, weights);

        vm.warp(block.timestamp + 1 days);
        _refreshPrices();
        vm.expectEmit(true, true, false, true);
        emit EquiVault.ReallocationExecuted(1, assets, weights);
        _executeReallocation(vault, new uint256[](0), new uint256[](0));

        vm.prank(manager);
        vault.proposeReallocation(assets, weights);
        uint256 cancellationId = vault.activeProposal().id;
        vm.expectEmit(true, true, false, true);
        emit EquiVault.ReallocationCancelled(cancellationId);
        vm.prank(manager);
        vault.cancelReallocation(cancellationId);
    }

    // ------------------------------------------------------------------
    // Proposal validation
    // ------------------------------------------------------------------

    function testProposeRejectsInvalidTargets() public {
        EquiVault vault = _deployVault(EquiVault.TimelockMode.Delayed, 1 days);

        // Weight below the 5 % floor.
        vm.expectRevert(abi.encodeWithSelector(EquiVault.InvalidWeight.selector, uint16(100)));
        vm.prank(manager);
        vault.proposeReallocation(_assetsAB(), _weights(100, 9_900));

        // Weights not summing to 100 %.
        uint16[] memory partialW = new uint16[](1);
        partialW[0] = 5_000;
        address[] memory onlyA = new address[](1);
        onlyA[0] = address(tokenA);
        vm.expectRevert(abi.encodeWithSelector(EquiVault.WeightsMustSumTo10000.selector, uint256(5_000)));
        vm.prank(manager);
        vault.proposeReallocation(onlyA, partialW);

        // Settlement asset in basket.
        address[] memory withUsdc = new address[](2);
        withUsdc[0] = address(usdc);
        withUsdc[1] = address(tokenA);
        vm.expectRevert(abi.encodeWithSelector(EquiVault.SettlementAssetInBasket.selector, address(usdc)));
        vm.prank(manager);
        vault.proposeReallocation(withUsdc, _weights(5_000, 5_000));

        // Asset not admissible (unregistered).
        address[] memory unknown = new address[](1);
        unknown[0] = address(0xBEEF);
        uint16[] memory full = new uint16[](1);
        full[0] = 10_000;
        vm.expectRevert(abi.encodeWithSelector(EquiVault.AssetNotAdmissible.selector, address(0xBEEF)));
        vm.prank(manager);
        vault.proposeReallocation(unknown, full);    }

    // ------------------------------------------------------------------
    // Deposit consent during notice
    // ------------------------------------------------------------------

    function testDepositRequiresExactProposalConsent() public {
        EquiVault vault = _deployVault(EquiVault.TimelockMode.Delayed, 1 days);
        _fundAndApprove(address(vault), alice, 1_000e6);
        _fundAndApprove(address(vault), bob, 1_000e6);
        _propose(vault, _assetsAC(), _weights(5_000, 5_000));

        // A zero proposal id is refused while a proposal is pending.
        vm.expectRevert(abi.encodeWithSelector(EquiVault.ProposalIdMismatch.selector, uint256(1), uint256(0)));
        vm.prank(alice);
        enterVault(vault, 500e6, alice);

        // Consenting to the wrong id is refused.
        vm.expectRevert(abi.encodeWithSelector(EquiVault.ProposalIdMismatch.selector, uint256(1), uint256(99)));
        vm.prank(alice);
        enterVaultWithMins(vault, 500e6, alice, new uint256[](0), 99);

        // Consenting to the exact displayed id succeeds.
        vm.prank(alice);
        enterVaultWithMins(vault, 500e6, alice, new uint256[](0), 1);
        assertGt(vault.balanceOf(alice), 0);

        // Same gate applies to every custom entry.
        vm.expectRevert(abi.encodeWithSelector(EquiVault.ProposalIdMismatch.selector, uint256(1), uint256(0)));
        vm.prank(bob);
        enterVault(vault, 300e6, bob);
        vm.prank(bob);
        enterVaultWithMins(vault, 300e6, bob, new uint256[](0), 1);
        assertGt(vault.balanceOf(bob), 0);
    }

    function testMixedExitsAllowedDuringNotice() public {
        EquiVault vault = _deployVault(EquiVault.TimelockMode.Delayed, 1 days);
        _fundAndApprove(address(vault), alice, 1_000e6);
        vm.prank(alice);
        enterVault(vault, 1_000e6, alice);

        _propose(vault, _assetsAC(), _weights(5_000, 5_000));

        // Mixed exit (A -> USDC, B -> token) during the notice succeeds without protocol exit fees.
        bool[] memory flags = new bool[](2);
        flags[0] = true;
        flags[1] = false;
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        exitVault(vault, shares, alice, flags);
        assertEq(vault.balanceOf(alice), 0);
        assertGt(usdc.balanceOf(alice), 0);
        assertGt(tokenB.balanceOf(alice), 0);
    }

    // ------------------------------------------------------------------
    // Execution and migration
    // ------------------------------------------------------------------

    function testMigrationSellsRemovedAndBuysAdded() public {
        EquiVault vault = _deployVault(EquiVault.TimelockMode.Delayed, 1 days);
        _fundAndApprove(address(vault), alice, 1_000e6);
        vm.prank(alice);
        enterVault(vault, 1_000e6, alice);

        uint256 balA = tokenA.balanceOf(address(vault));
        uint256 balB = tokenB.balanceOf(address(vault));
        assertGt(balA, 0);
        assertGt(balB, 0);

        _propose(vault, _assetsAC(), _weights(5_000, 5_000));
        vm.warp(block.timestamp + 1 days);
        _refreshPrices();
        _executeReallocation(vault, new uint256[](0), new uint256[](0));

        // Removed asset fully sold; kept asset untouched; added asset bought.
        assertEq(tokenB.balanceOf(address(vault)), 0);
        assertEq(tokenA.balanceOf(address(vault)), balA);
        uint256 balC = tokenC.balanceOf(address(vault));
        assertGt(balC, 0);

        // New basket and cap applied.
        assertEq(vault.basketAssets()[0], address(tokenA));
        assertEq(vault.basketAssets()[1], address(tokenC));

        // New liquidity route approved for both legs.
        assertEq(usdc.allowance(address(vault), address(poolC)), type(uint256).max);
        assertEq(tokenC.allowance(address(vault), address(poolC)), type(uint256).max);

        // NAV is preserved (only swap costs).
        uint256 nav = vault.totalAssets();
        assertApproxEqAbs(nav, 1_000e6, 20e6);

        // Post-execution deposits buy the new basket, not the old one.
        _fundAndApprove(address(vault), bob, 500e6);
        vm.prank(bob);
        enterVault(vault, 500e6, bob);
        assertEq(tokenB.balanceOf(address(vault)), 0);
        assertGt(tokenC.balanceOf(address(vault)), balC);
    }

    function testReexecutionRevalidatesTarget() public {
        EquiVault vault = _deployVault(EquiVault.TimelockMode.Delayed, 1 days);
        _propose(vault, _assetsAC(), _weights(5_000, 5_000));
        uint256 id = vault.activeProposal().id;

        // Asset C becomes non-admissible before execution: the execute must refuse.
        vm.prank(admin);
        registry.setAssetStatus(address(tokenC), AssetRegistry.AssetStatus.ExitOnly);
        vm.warp(block.timestamp + 1 days);
        _refreshPrices();
        vm.expectRevert(abi.encodeWithSelector(EquiVault.AssetNotAdmissible.selector, address(tokenC)));
        vault.executeReallocation(id, type(uint256).max, new uint256[](0), new uint256[](0));
    }

    function testReallocationRejectsTooPermissiveSellAndBuyMins() public {
        EquiVault vault = _deployVault(EquiVault.TimelockMode.Delayed, 1 days);
        _fundAndApprove(address(vault), alice, 1_000e6);
        vm.prank(alice);
        enterVault(vault, 1_000e6, alice);

        address[] memory onlyA = new address[](1);
        onlyA[0] = address(tokenA);
        uint16[] memory fullWeight = new uint16[](1);
        fullWeight[0] = 10_000;
        _propose(vault, onlyA, fullWeight);
        vm.warp(block.timestamp + 1 days);
        _refreshPrices();
        uint256 id = vault.activeProposal().id;

        uint256[] memory permissiveSell = new uint256[](1);
        permissiveSell[0] = 1;
        vm.expectRevert();
        vault.executeReallocation(id, type(uint256).max, permissiveSell, new uint256[](0));

        // The unchanged proposal remains executable with the vault's oracle-derived defaults.
        _executeReallocation(vault, new uint256[](0), new uint256[](0));
        assertEq(vault.basketAssets().length, 1);
    }

    function testReallocationRejectsTooPermissiveBuyMin() public {
        EquiVault vault = _deployVault(EquiVault.TimelockMode.Delayed, 1 days);
        _fundAndApprove(address(vault), alice, 1_000e6);
        vm.prank(alice);
        enterVault(vault, 1_000e6, alice);

        _propose(vault, _assetsAC(), _weights(5_000, 5_000));
        vm.warp(block.timestamp + 1 days);
        _refreshPrices();
        uint256[] memory permissiveBuy = new uint256[](2);
        permissiveBuy[1] = 1; // C is newly bought and its oracle minimum is materially higher.
        uint256 id = vault.activeProposal().id;
        vm.expectRevert();
        vault.executeReallocation(id, type(uint256).max, new uint256[](0), permissiveBuy);
    }

    function testLargeDepositsRemainBacked() public {
        EquiVault vault = _deployVault(EquiVault.TimelockMode.Delayed, 1 days);

        // Keep the vault's 1 % default slippage unchanged while adding enough route liquidity
        // for a 2.1M settlement deposit. At the 60/40 target weights, token A receives >1.2M
        // settlement value, exceeding the removed per-asset exposure ceiling.
        usdc.mint(address(this), 600_000_000e6);
        tokenA.mint(address(this), 3_000_000e18);
        tokenB.mint(address(this), 6_000_000e6);
        poolA.seed(300_000_000e6, 3_000_000e18);
        poolB.seed(300_000_000e6, 6_000_000e6);

        _fundAndApprove(address(vault), alice, 2_100_000e6);
        vm.prank(alice);
        enterVault(vault, 2_100_000e6, alice);

        uint256 shares = vault.balanceOf(alice);
        assertGt(shares, 0);
        assertGt(vault.totalAssets(), 2_000_000e6);
        assertGt(_valueUsdc(address(tokenA), tokenA.balanceOf(address(vault))), 1_200_000e6);

        vm.prank(alice);
        exitVault(vault, shares, alice, new bool[](2));
        assertEq(vault.balanceOf(alice), 0);
        assertGt(tokenA.balanceOf(alice), 0);
        assertGt(tokenB.balanceOf(alice), 0);
    }

    // ------------------------------------------------------------------
    // B001: reallocation to a strictly smaller basket must reinvest the freed
    // settlement into the kept assets (no idle USDC outside totalAssets()).
    // ------------------------------------------------------------------

    function testReallocationToSmallerBasketReinvestsFreedSettlement() public {
        EquiVault vault = _deployVault(EquiVault.TimelockMode.Delayed, 1 days);
        _fundAndApprove(address(vault), alice, 1_000e6);
        vm.prank(alice);
        enterVault(vault, 1_000e6, alice);

        uint256 navBefore = vault.totalAssets();
        address[] memory target = new address[](1);
        target[0] = address(tokenA);
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10_000;
        vm.prank(manager);
        vault.proposeReallocation(target, weights);
        vm.warp(block.timestamp + 1 days + 1);
        _refreshPrices();

        uint256 id = vault.activeProposal().id;
        vm.prank(bob);
        vault.executeReallocation(id, type(uint256).max, new uint256[](0), new uint256[](0));

        // tokenB was sold and the proceeds fully reinvested into tokenA.
        assertEq(vault.basketAssets().length, 1);
        assertEq(vault.basketAssets()[0], address(tokenA));
        assertLt(usdc.balanceOf(address(vault)), 1e6); // < 1 USDC of swap dust

        // NAV continuity: only the migration swap costs are lost, bounded by the vault slippage.
        uint256 navAfter = vault.totalAssets();
        assertGe(navBefore, navAfter);
        assertGt(navAfter, navBefore * 9_700 / 10_000); // maxSlippageBps 3 % on sell + buy
    }

    function testReallocationToSubsetKeepsExactTargetWeight() public {
        // [A, B, C] -> [B, C] (5000/5000): B is kept, C is bought up to its target weight with the
        // freed settlement; the basket reaches the new weights exactly.
        address[] memory a3 = new address[](3);
        a3[0] = address(tokenA);
        a3[1] = address(tokenB);
        a3[2] = address(tokenC);
        uint16[] memory w3 = new uint16[](3);
        w3[0] = 5_000;
        w3[1] = 3_000;
        w3[2] = 2_000;
        EquiVault vault = new EquiVault(
            usdc, registry, manager, a3, w3, 1_000, 300, EquiVault.TimelockMode.Delayed, 1 days, 0, 0
        );
        _fundAndApprove(address(vault), alice, 1_000e6);
        vm.prank(alice);
        enterVault(vault, 1_000e6, alice);

        address[] memory target = new address[](2);
        target[0] = address(tokenB);
        target[1] = address(tokenC);
        uint16[] memory weights = _weights(5_000, 5_000);
        vm.prank(manager);
        vault.proposeReallocation(target, weights);
        vm.warp(block.timestamp + 1 days + 1);
        _refreshPrices();

        uint256 id = vault.activeProposal().id;
        vm.prank(bob);
        vault.executeReallocation(id, type(uint256).max, new uint256[](0), new uint256[](0));

        assertEq(vault.basketAssets().length, 2);
        assertEq(vault.basketAssets()[0], address(tokenB));
        assertEq(vault.basketAssets()[1], address(tokenC));
        assertLt(usdc.balanceOf(address(vault)), 1e6);
        // B (kept) should hold ~50 % of the NAV and C ~50 %, within swap rounding.
        uint256 nav = vault.totalAssets();
        uint256 bValue = _valueUsdc(address(tokenB), tokenB.balanceOf(address(vault)));
        uint256 cValue = _valueUsdc(address(tokenC), tokenC.balanceOf(address(vault)));
        assertApproxEqAbs(Math.mulDiv(bValue, 10_000, nav), 5_000, 100);
        assertApproxEqAbs(Math.mulDiv(cValue, 10_000, nav), 5_000, 100);
    }

    function _valueUsdc(address a, uint256 amount) internal view returns (uint256) {
        (uint256 price,) = registry.getPrice(a, address(usdc));
        uint256 scale = 10 ** uint256(registry.assetConfig(a).decimals);
        return Math.mulDiv(amount, price * 1e6, scale * 1e18);
    }
}
