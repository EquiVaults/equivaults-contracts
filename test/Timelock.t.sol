// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {AssetRegistry} from "../src/AssetRegistry.sol";
import {EquiVault} from "../src/EquiVault.sol";

import {MockOracle, MockPool, MockToken} from "./mocks/Mocks.sol";

contract TimelockTest is Test {
    uint48 internal constant MAX_PRICE_AGE = 1 hours;
    uint256 internal constant PRICE_A = 100e18; // $100 per whole token
    uint256 internal constant PRICE_B = 50e18; // $50 per whole token
    uint256 internal constant PRICE_C = 200e18; // $200 per whole token
    uint256 internal constant SHARE_SCALE = 1e6; // _decimalsOffset() = 6
    // Registry exposure cap per asset (USD at 1e18): yields clean vault AUM bounds in USDC units.
    uint256 internal constant EXPOSURE_CAP = 1_200_000e18;
    // Bound for the [A, B] 6000/4000 basket = min(1.2e24*10000/6000, 1.2e24*10000/4000)/1e12.
    uint256 internal constant BOUND_AB = 2_000_000e6;
    // Bound for the [A, C] 5000/5000 basket = 1.2e24*10000/5000/1e12.
    uint256 internal constant BOUND_AC = 2_400_000e6;

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
        registry.registerAsset(address(tokenA), primaryA, fallbackA, address(poolA), EXPOSURE_CAP, MAX_PRICE_AGE);
        registry.registerAsset(address(tokenB), primaryB, fallbackB, address(poolB), EXPOSURE_CAP, MAX_PRICE_AGE);
        registry.registerAsset(address(tokenC), primaryC, fallbackC, address(poolC), EXPOSURE_CAP, MAX_PRICE_AGE);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// @dev [A, B] 6000/4000 basket on a fresh vault.
    function _deployVault(EquiVault.TimelockMode mode, uint256 delay, uint256 cap)
        internal
        returns (EquiVault vault)
    {
        address[] memory a = _assetsAB();
        uint16[] memory w = _weights(6_000, 4_000);
        vault = new EquiVault(usdc, registry, manager, a, w, 1_000, 100, mode, delay, cap, 0, 0);
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

    function _propose(EquiVault vault, address[] memory assets, uint16[] memory weights, uint256 cap) internal {
        vm.prank(manager);
        vault.proposeReallocation(assets, weights, cap);
    }

    // ------------------------------------------------------------------
    // Construction
    // ------------------------------------------------------------------

    function testConstructorRejectsInvalidTimelockAndCap() public {
        address[] memory a = _assetsAB();
        uint16[] memory w = _weights(6_000, 4_000);

        vm.expectRevert(abi.encodeWithSelector(EquiVault.InvalidTimelockDelay.selector, uint256(0)));
        new EquiVault(usdc, registry, manager, a, w, 1_000, 100, EquiVault.TimelockMode.Delayed, 0, 1_000_000e6, 0, 0);

        vm.expectRevert(abi.encodeWithSelector(EquiVault.InvalidTimelockDelay.selector, uint256(8 days)));
        new EquiVault(usdc, registry, manager, a, w, 1_000, 100, EquiVault.TimelockMode.Delayed, 8 days, 1_000_000e6, 0, 0);

        vm.expectRevert(abi.encodeWithSelector(EquiVault.InvalidTimelockDelay.selector, uint256(1 days)));
        new EquiVault(usdc, registry, manager, a, w, 1_000, 100, EquiVault.TimelockMode.Instant, 1 days, 1_000_000e6, 0, 0);

        vm.expectRevert(abi.encodeWithSelector(EquiVault.InvalidAumCap.selector, uint256(0), BOUND_AB));
        new EquiVault(usdc, registry, manager, a, w, 1_000, 100, EquiVault.TimelockMode.Delayed, 1 days, 0, 0, 0);

        vm.expectRevert(abi.encodeWithSelector(EquiVault.InvalidAumCap.selector, BOUND_AB + 1, BOUND_AB));
        new EquiVault(usdc, registry, manager, a, w, 1_000, 100, EquiVault.TimelockMode.Delayed, 1 days, BOUND_AB + 1, 0, 0);
    }

    // ------------------------------------------------------------------
    // Trust modes
    // ------------------------------------------------------------------

    function testInstantProposalExecutableImmediately() public {
        EquiVault vault = _deployVault(EquiVault.TimelockMode.Instant, 0, 1_000_000e6);
        _fundAndApprove(address(vault), alice, 1_000e6);
        vm.prank(alice);
        vault.deposit(1_000e6, alice);

        _propose(vault, _assetsAC(), _weights(5_000, 5_000), 1_500_000e6);
        // No warp: executable right away, and permissionless (executed by alice, not the manager).
        vm.prank(alice);
        vault.executeReallocation(new uint256[](0), new uint256[](0));

        address[] memory assets = vault.basketAssets();
        assertEq(assets.length, 2);
        assertEq(assets[0], address(tokenA));
        assertEq(assets[1], address(tokenC));
        assertEq(vault.basketWeightsBps()[0], 5_000);
        assertEq(vault.basketWeightsBps()[1], 5_000);
        assertEq(vault.capAum(), 1_500_000e6);
        assertEq(vault.activeProposal().id, 0);
    }

    function testDelayedProposalNotExecutableBeforeDelay() public {
        EquiVault vault = _deployVault(EquiVault.TimelockMode.Delayed, 1 days, 1_000_000e6);
        _propose(vault, _assetsAC(), _weights(5_000, 5_000), 1_500_000e6);

        EquiVault.ReallocationProposal memory p = vault.activeProposal();
        assertEq(p.id, 1);
        assertEq(p.executableAt, block.timestamp + 1 days);

        vm.expectRevert(abi.encodeWithSelector(EquiVault.ProposalNotExecutable.selector, p.executableAt));
        vault.executeReallocation(new uint256[](0), new uint256[](0));

        vm.warp(block.timestamp + 1 days);
        _refreshPrices();
        vault.executeReallocation(new uint256[](0), new uint256[](0));
        assertEq(vault.activeProposal().id, 0);
    }

    function testImmutableVaultRefusesProposalsForever() public {
        EquiVault vault = _deployVault(EquiVault.TimelockMode.Immutable, 0, 1_000_000e6);

        vm.expectRevert(EquiVault.TimelockImmutable.selector);
        vm.prank(manager);
        vault.proposeReallocation(_assetsAC(), _weights(5_000, 5_000), 1_500_000e6);

        // Composition is frozen, but ordinary deposits still work.
        _fundAndApprove(address(vault), alice, 1_000e6);
        vm.prank(alice);
        vault.deposit(1_000e6, alice);
        assertEq(vault.balanceOf(alice), 1_000e6 * SHARE_SCALE);
    }

    // ------------------------------------------------------------------
    // Proposal lifecycle
    // ------------------------------------------------------------------

    function testOnlyManagerCanProposeAndCancel() public {
        EquiVault vault = _deployVault(EquiVault.TimelockMode.Delayed, 1 days, 1_000_000e6);

        vm.expectRevert(EquiVault.NotManager.selector);
        vm.prank(alice);
        vault.proposeReallocation(_assetsAC(), _weights(5_000, 5_000), 1_500_000e6);

        _propose(vault, _assetsAC(), _weights(5_000, 5_000), 1_500_000e6);
        assertEq(vault.activeProposal().id, 1);

        vm.expectRevert(EquiVault.NotManager.selector);
        vm.prank(alice);
        vault.cancelReallocation();

        vm.prank(manager);
        vault.cancelReallocation();
        assertEq(vault.activeProposal().id, 0);
    }

    function testSecondProposalRejectedWhileActive() public {
        EquiVault vault = _deployVault(EquiVault.TimelockMode.Delayed, 1 days, 1_000_000e6);
        _propose(vault, _assetsAC(), _weights(5_000, 5_000), 1_500_000e6);

        vm.expectRevert(abi.encodeWithSelector(EquiVault.ProposalAlreadyActive.selector, uint256(1)));
        vm.prank(manager);
        vault.proposeReallocation(_assetsAC(), _weights(5_000, 5_000), 1_500_000e6);
    }

    function testReplaceRestartsFullDelay() public {
        EquiVault vault = _deployVault(EquiVault.TimelockMode.Delayed, 1 days, 1_000_000e6);
        _propose(vault, _assetsAC(), _weights(5_000, 5_000), 1_500_000e6);
        vm.prank(manager);
        vault.cancelReallocation();

        vm.warp(block.timestamp + 12 hours); // inside the original window
        _propose(vault, _assetsAB(), _weights(6_000, 4_000), 1_100_000e6);

        EquiVault.ReallocationProposal memory p = vault.activeProposal();
        assertEq(p.id, 2); // fresh identifier
        assertEq(p.executableAt, block.timestamp + 1 days); // full delay restarted
    }

    function testExecuteWithoutProposalReverts() public {
        EquiVault vault = _deployVault(EquiVault.TimelockMode.Instant, 0, 1_000_000e6);
        vm.expectRevert(EquiVault.NoActiveProposal.selector);
        vault.executeReallocation(new uint256[](0), new uint256[](0));
    }

    function testProposalEventsEmitFullHistory() public {
        EquiVault vault = _deployVault(EquiVault.TimelockMode.Delayed, 1 days, 1_000_000e6);
        address[] memory assets = _assetsAC();
        uint16[] memory weights = _weights(5_000, 5_000);

        vm.expectEmit(true, true, true, true);
        emit EquiVault.ReallocationProposed(1, manager, block.timestamp + 1 days, assets, weights, 1_500_000e6);
        vm.prank(manager);
        vault.proposeReallocation(assets, weights, 1_500_000e6);

        vm.warp(block.timestamp + 1 days);
        _refreshPrices();
        vm.expectEmit(true, true, false, true);
        emit EquiVault.ReallocationExecuted(1, assets, weights, 1_500_000e6);
        vault.executeReallocation(new uint256[](0), new uint256[](0));

        vm.prank(manager);
        vault.proposeReallocation(assets, weights, 1_500_000e6);
        vm.expectEmit(true, true, false, true);
        emit EquiVault.ReallocationCancelled(2);
        vm.prank(manager);
        vault.cancelReallocation();
    }

    // ------------------------------------------------------------------
    // Proposal validation
    // ------------------------------------------------------------------

    function testProposeRejectsInvalidTargets() public {
        EquiVault vault = _deployVault(EquiVault.TimelockMode.Delayed, 1 days, 1_000_000e6);

        // Weight below the 5 % floor.
        vm.expectRevert(abi.encodeWithSelector(EquiVault.InvalidWeight.selector, uint16(100)));
        vm.prank(manager);
        vault.proposeReallocation(_assetsAB(), _weights(100, 9_900), 1_000_000e6);

        // Weights not summing to 100 %.
        uint16[] memory partialW = new uint16[](1);
        partialW[0] = 5_000;
        address[] memory onlyA = new address[](1);
        onlyA[0] = address(tokenA);
        vm.expectRevert(abi.encodeWithSelector(EquiVault.WeightsMustSumTo10000.selector, uint256(5_000)));
        vm.prank(manager);
        vault.proposeReallocation(onlyA, partialW, 1_000_000e6);

        // Settlement asset in basket.
        address[] memory withUsdc = new address[](2);
        withUsdc[0] = address(usdc);
        withUsdc[1] = address(tokenA);
        vm.expectRevert(abi.encodeWithSelector(EquiVault.SettlementAssetInBasket.selector, address(usdc)));
        vm.prank(manager);
        vault.proposeReallocation(withUsdc, _weights(5_000, 5_000), 1_000_000e6);

        // Asset not admissible (unregistered).
        address[] memory unknown = new address[](1);
        unknown[0] = address(0xBEEF);
        uint16[] memory full = new uint16[](1);
        full[0] = 10_000;
        vm.expectRevert(abi.encodeWithSelector(EquiVault.AssetNotAdmissible.selector, address(0xBEEF)));
        vm.prank(manager);
        vault.proposeReallocation(unknown, full, 1_000_000e6);

        // Cap above the registry-derived bound.
        vm.expectRevert(abi.encodeWithSelector(EquiVault.InvalidAumCap.selector, BOUND_AB + 1, BOUND_AB));
        vm.prank(manager);
        vault.proposeReallocation(_assetsAB(), _weights(6_000, 4_000), BOUND_AB + 1);

        // Zero cap.
        vm.expectRevert(abi.encodeWithSelector(EquiVault.InvalidAumCap.selector, uint256(0), BOUND_AB));
        vm.prank(manager);
        vault.proposeReallocation(_assetsAB(), _weights(6_000, 4_000), 0);
    }

    // ------------------------------------------------------------------
    // Deposit consent during notice
    // ------------------------------------------------------------------

    function testDepositRequiresExactProposalConsent() public {
        EquiVault vault = _deployVault(EquiVault.TimelockMode.Delayed, 1 days, 1_000_000e6);
        _fundAndApprove(address(vault), alice, 1_000e6);
        _fundAndApprove(address(vault), bob, 1_000e6);
        _propose(vault, _assetsAC(), _weights(5_000, 5_000), 1_500_000e6);

        // Plain deposit is refused while a proposal is pending.
        vm.expectRevert(abi.encodeWithSelector(EquiVault.DepositRequiresConsent.selector, uint256(1)));
        vm.prank(alice);
        vault.deposit(500e6, alice);

        // Consenting to the wrong id is refused.
        vm.expectRevert(abi.encodeWithSelector(EquiVault.ProposalIdMismatch.selector, uint256(1), uint256(99)));
        vm.prank(alice);
        vault.deposit(500e6, alice, new uint256[](0), 99);

        // Consenting to the exact displayed id succeeds.
        vm.prank(alice);
        vault.deposit(500e6, alice, new uint256[](0), 1);
        assertEq(vault.balanceOf(alice), 500e6 * SHARE_SCALE);

        // Same gate on mint.
        vm.expectRevert(abi.encodeWithSelector(EquiVault.DepositRequiresConsent.selector, uint256(1)));
        vm.prank(bob);
        vault.mint(300e6 * SHARE_SCALE, bob);
        vm.prank(bob);
        vault.mint(300e6 * SHARE_SCALE, bob, new uint256[](0), 1);
        assertEq(vault.balanceOf(bob), 300e6 * SHARE_SCALE);
    }

    function testMixedExitsAllowedDuringNotice() public {
        EquiVault vault = _deployVault(EquiVault.TimelockMode.Delayed, 1 days, 1_000_000e6);
        _fundAndApprove(address(vault), alice, 1_000e6);
        vm.prank(alice);
        vault.deposit(1_000e6, alice);

        _propose(vault, _assetsAC(), _weights(5_000, 5_000), 1_500_000e6);

        // Mixed exit (A -> USDC, B -> token) during the notice succeeds without protocol exit fees.
        bool[] memory flags = new bool[](2);
        flags[0] = true;
        flags[1] = false;
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(shares, alice, alice, flags);
        assertEq(vault.balanceOf(alice), 0);
        assertGt(usdc.balanceOf(alice), 0);
        assertGt(tokenB.balanceOf(alice), 0);
    }

    // ------------------------------------------------------------------
    // Execution and migration
    // ------------------------------------------------------------------

    function testMigrationSellsRemovedAndBuysAdded() public {
        EquiVault vault = _deployVault(EquiVault.TimelockMode.Delayed, 1 days, 1_000_000e6);
        _fundAndApprove(address(vault), alice, 1_000e6);
        vm.prank(alice);
        vault.deposit(1_000e6, alice);

        uint256 balA = tokenA.balanceOf(address(vault));
        uint256 balB = tokenB.balanceOf(address(vault));
        assertGt(balA, 0);
        assertGt(balB, 0);

        _propose(vault, _assetsAC(), _weights(5_000, 5_000), 1_500_000e6);
        vm.warp(block.timestamp + 1 days);
        _refreshPrices();
        vault.executeReallocation(new uint256[](0), new uint256[](0));

        // Removed asset fully sold; kept asset untouched; added asset bought.
        assertEq(tokenB.balanceOf(address(vault)), 0);
        assertEq(tokenA.balanceOf(address(vault)), balA);
        uint256 balC = tokenC.balanceOf(address(vault));
        assertGt(balC, 0);

        // New basket and cap applied.
        assertEq(vault.basketAssets()[0], address(tokenA));
        assertEq(vault.basketAssets()[1], address(tokenC));
        assertEq(vault.capAum(), 1_500_000e6);

        // New liquidity route approved for both legs.
        assertEq(usdc.allowance(address(vault), address(poolC)), type(uint256).max);
        assertEq(tokenC.allowance(address(vault), address(poolC)), type(uint256).max);

        // NAV is preserved (only swap costs).
        uint256 nav = vault.totalAssets();
        assertApproxEqAbs(nav, 1_000e6, 20e6);

        // Post-execution deposits buy the new basket, not the old one.
        _fundAndApprove(address(vault), bob, 500e6);
        vm.prank(bob);
        vault.deposit(500e6, bob);
        assertEq(tokenB.balanceOf(address(vault)), 0);
        assertGt(tokenC.balanceOf(address(vault)), balC);
    }

    function testReexecutionRevalidatesTarget() public {
        EquiVault vault = _deployVault(EquiVault.TimelockMode.Delayed, 1 days, 1_000_000e6);
        _propose(vault, _assetsAC(), _weights(5_000, 5_000), 1_500_000e6);

        // Asset C becomes non-admissible before execution: the execute must refuse.
        vm.prank(admin);
        registry.setAssetStatus(address(tokenC), AssetRegistry.AssetStatus.ExitOnly);
        vm.warp(block.timestamp + 1 days);
        _refreshPrices();
        vm.expectRevert(abi.encodeWithSelector(EquiVault.AssetNotAdmissible.selector, address(tokenC)));
        vault.executeReallocation(new uint256[](0), new uint256[](0));
    }

    // ------------------------------------------------------------------
    // AUM cap
    // ------------------------------------------------------------------

    function testAumCapBlocksDepositsAtBoundary() public {
        EquiVault vault = _deployVault(EquiVault.TimelockMode.Delayed, 1 days, 1_000e6);
        _fundAndApprove(address(vault), alice, 1_000e6);
        _fundAndApprove(address(vault), bob, 1_000e6);

        vm.prank(alice);
        vault.deposit(900e6, alice);
        assertLt(vault.totalAssets(), 1_000e6);

        uint256 navBefore = vault.totalAssets();
        vm.expectRevert(abi.encodeWithSelector(EquiVault.AumCapReached.selector, navBefore + 150e6, 1_000e6));
        vm.prank(bob);
        vault.deposit(150e6, bob);
    }

    function testCapDecreaseBelowNavBlocksDeposits() public {
        EquiVault vault = _deployVault(EquiVault.TimelockMode.Delayed, 1 days, 1_000e6);
        _fundAndApprove(address(vault), alice, 1_000e6);
        _fundAndApprove(address(vault), bob, 1_000e6);
        vm.prank(alice);
        vault.deposit(800e6, alice);

        // Cap-only reallocation: same basket, lower cap, via the timelock.
        _propose(vault, _assetsAB(), _weights(6_000, 4_000), 700e6);
        vm.warp(block.timestamp + 1 days);
        _refreshPrices();
        vault.executeReallocation(new uint256[](0), new uint256[](0));
        assertEq(vault.capAum(), 700e6);

        // NAV (~800e6) is above the new cap: deposits are refused, no forced withdrawal.
        vm.expectRevert();
        vm.prank(bob);
        vault.deposit(100e6, bob);
        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(aliceShares, alice, alice);
        assertEq(vault.balanceOf(alice), 0);
    }

    function testCapIncreaseAfterExecutionAllowsMoreDeposits() public {
        EquiVault vault = _deployVault(EquiVault.TimelockMode.Delayed, 1 days, 1_000e6);
        _fundAndApprove(address(vault), alice, 1_000e6);
        _fundAndApprove(address(vault), bob, 1_000e6);
        vm.prank(alice);
        vault.deposit(900e6, alice);

        // Raising the cap (same basket) takes effect only after the timelock elapses.
        _propose(vault, _assetsAB(), _weights(6_000, 4_000), 1_100e6);
        vm.expectRevert();
        vm.prank(bob);
        vault.deposit(150e6, bob); // still capped under the old cap

        vm.warp(block.timestamp + 1 days);
        _refreshPrices();
        vault.executeReallocation(new uint256[](0), new uint256[](0));
        assertEq(vault.capAum(), 1_100e6);

        vm.prank(bob);
        vault.deposit(150e6, bob);
        assertGt(vault.balanceOf(bob), 0);
    }
}
