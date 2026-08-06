// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";

import {AssetRegistry} from "../src/AssetRegistry.sol";
import {EquiVault} from "../src/EquiVault.sol";
import {RebalanceEngine} from "../src/RebalanceEngine.sol";

import {MockOracle, MockOracleRoute, MockToken} from "./mocks/Mocks.sol";

/// @dev Rebalance engine (F002-S002): drift threshold, collective slippage, permissionless
/// `rebalance()`, measured/capped gas reimbursement and the RebalanceEngine coordinator.
contract RebalanceEngineTest is Test {
    uint48 internal constant MAX_PRICE_AGE = 1 hours;
    uint256 internal constant PRICE_A = 100e18; // $100 per whole token
    uint256 internal constant PRICE_B = 50e18; // $50 per whole token
    uint256 internal constant EXPOSURE_CAP = 1_200_000e18;
    uint256 internal constant BOUND_AB = 2_000_000e6;

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal manager = makeAddr("manager");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal keeper = makeAddr("keeper");

    MockToken internal usdc;
    MockToken internal tokenA;
    MockToken internal tokenB;
    MockOracle internal primaryA;
    MockOracle internal fallbackA;
    MockOracle internal primaryB;
    MockOracle internal fallbackB;
    MockOracleRoute internal routeA;
    MockOracleRoute internal routeB;
    AssetRegistry internal registry;
    RebalanceEngine internal engine;

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new MockToken(6);
        tokenA = new MockToken(18);
        tokenB = new MockToken(6);

        primaryA = new MockOracle();
        fallbackA = new MockOracle();
        primaryB = new MockOracle();
        fallbackB = new MockOracle();
        _refreshPrices();

        registry = new AssetRegistry(admin, treasury);
        routeA = new MockOracleRoute(registry, usdc, 30);
        routeB = new MockOracleRoute(registry, usdc, 30);
        // Fund the routes so they can serve any swap at the current oracle price.
        tokenA.mint(address(routeA), 1e30);
        usdc.mint(address(routeA), 1e30);
        tokenB.mint(address(routeB), 1e30);
        usdc.mint(address(routeB), 1e30);

        vm.startPrank(admin);
        registry.registerAsset(address(tokenA), primaryA, fallbackA, address(routeA), EXPOSURE_CAP, MAX_PRICE_AGE);
        registry.registerAsset(address(tokenB), primaryB, fallbackB, address(routeB), EXPOSURE_CAP, MAX_PRICE_AGE);
        vm.stopPrank();

        engine = new RebalanceEngine();
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// @dev [A, B] 6000/4000 basket, max vault slippage 3 % so the rebalance slippage 0.1-3 %
    /// range is fully exercisable. maxSlippageBps = 300, fee 10 %.
    function _deployVault(EquiVault.TimelockMode mode, uint256 delay) internal returns (EquiVault vault) {
        address[] memory a = new address[](2);
        a[0] = address(tokenA);
        a[1] = address(tokenB);
        uint16[] memory w = new uint16[](2);
        w[0] = 6_000;
        w[1] = 4_000;
        vault = new EquiVault(usdc, registry, manager, a, w, 1_000, 300, mode, delay, 1_000_000e6, 0, 0);
    }

    /// @dev Alice deposits 1,000 USDC, then asset A appreciates 20 % so the basket drifts ~4.3
    /// points above the default 3-point threshold.
    function _fundedVaultWithDrift(EquiVault.TimelockMode mode, uint256 delay)
        internal
        returns (EquiVault vault)
    {
        vault = _deployVault(mode, delay);
        usdc.mint(alice, 1_000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(1_000e6, alice);
        vm.stopPrank();

        primaryA.setPrice(120e18, block.timestamp);
        (uint256 setupDev,) = vault.measureDrift();
        assertTrue(setupDev > vault.driftThresholdBps(), "setup drift below threshold");
        return vault;
    }

    function _rebalance(EquiVault vault, uint256[] memory minAmountsOut) internal returns (uint256 gasRebate) {
        vm.prank(keeper);
        gasRebate = vault.rebalance(
            EquiVault.RebalanceParams({deadline: block.timestamp + 1 hours, minAmountsOut: minAmountsOut})
        );
    }

    function _proposeParameters(EquiVault vault, uint16 driftBps, uint16 slippageBps) internal {
        vm.prank(manager);
        vault.proposeParameters(driftBps, slippageBps);
    }

    /// @dev Oracle timestamps must be refreshed after any warp beyond MAX_PRICE_AGE.
    function _refreshPrices() internal {
        primaryA.setPrice(PRICE_A, block.timestamp);
        fallbackA.setPrice(99e18, block.timestamp);
        primaryB.setPrice(PRICE_B, block.timestamp);
        fallbackB.setPrice(49e18, block.timestamp);
    }

    // ------------------------------------------------------------------
    // Rebalance parameters
    // ------------------------------------------------------------------

    function testRebalanceDefaults() public {
        EquiVault vault = _deployVault(EquiVault.TimelockMode.Instant, 0);
        assertEq(vault.driftThresholdBps(), 300);
        assertEq(vault.rebalanceSlippageBps(), 100);
    }

    function testProposeParametersOnlyManager() public {
        EquiVault vault = _deployVault(EquiVault.TimelockMode.Delayed, 1 days);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(EquiVault.NotManager.selector));
        vault.proposeParameters(500, 200);
    }

    function testProposeParametersBounds() public {
        EquiVault vault = _deployVault(EquiVault.TimelockMode.Delayed, 1 days);

        vm.expectRevert(abi.encodeWithSelector(EquiVault.InvalidDriftThreshold.selector, uint16(99)));
        _proposeParameters(vault, 99, 200);
        vm.expectRevert(abi.encodeWithSelector(EquiVault.InvalidDriftThreshold.selector, uint16(1_001)));
        _proposeParameters(vault, 1_001, 200);

        vm.expectRevert(abi.encodeWithSelector(EquiVault.InvalidRebalanceSlippage.selector, uint16(9)));
        _proposeParameters(vault, 500, 9);
        vm.expectRevert(abi.encodeWithSelector(EquiVault.InvalidRebalanceSlippage.selector, uint16(301)));
        _proposeParameters(vault, 500, 301);
        // Collective slippage can never exceed the vault's own max slippage: a vault capped at
        // 1 % (maxSlippageBps = 100) must reject a 1.5 % rebalance slippage.
        address[] memory a = new address[](2);
        a[0] = address(tokenA);
        a[1] = address(tokenB);
        uint16[] memory w = new uint16[](2);
        w[0] = 6_000;
        w[1] = 4_000;
        EquiVault strictVault =
            new EquiVault(usdc, registry, manager, a, w, 1_000, 100, EquiVault.TimelockMode.Instant, 0, 1_000_000e6, 0, 0);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(EquiVault.InvalidRebalanceSlippage.selector, uint16(150)));
        strictVault.proposeParameters(500, 150);
    }

    function testParameterUpdateRequiresTimelock() public {
        EquiVault vault = _deployVault(EquiVault.TimelockMode.Delayed, 1 days);
        _proposeParameters(vault, 500, 200);

        EquiVault.ParameterProposal memory p = vault.activeParameterProposal();
        assertEq(p.id, 1);
        assertEq(p.driftThresholdBps, 500);
        assertEq(p.rebalanceSlippageBps, 200);
        assertEq(p.executableAt, block.timestamp + 1 days);

        vm.expectRevert(abi.encodeWithSelector(EquiVault.ProposalNotExecutable.selector, p.executableAt));
        vault.executeParameterUpdate();

        vm.warp(block.timestamp + 1 days);
        _refreshPrices();
        vault.executeParameterUpdate();

        assertEq(vault.driftThresholdBps(), 500);
        assertEq(vault.rebalanceSlippageBps(), 200);
        assertEq(vault.activeParameterProposal().id, 0);
    }

    function testParameterUpdateInstant() public {
        EquiVault vault = _deployVault(EquiVault.TimelockMode.Instant, 0);
        _proposeParameters(vault, 400, 250);
        // No warp: executable right away, permissionless execution by alice.
        vm.prank(alice);
        vault.executeParameterUpdate();
        assertEq(vault.driftThresholdBps(), 400);
        assertEq(vault.rebalanceSlippageBps(), 250);
    }

    function testParameterUpdateImmutableRejected() public {
        EquiVault vault = _deployVault(EquiVault.TimelockMode.Immutable, 0);
        vm.expectRevert(abi.encodeWithSelector(EquiVault.TimelockImmutable.selector));
        _proposeParameters(vault, 500, 200);
    }

    function testSinglePendingChangeAtATime() public {
        EquiVault vault = _deployVault(EquiVault.TimelockMode.Delayed, 1 days);

        // A pending basket proposal blocks a parameter proposal...
        vm.prank(manager);
        vault.proposeReallocation(_assetsAB(), _weights(6_000, 4_000), 1_000_000e6);
        vm.expectRevert(abi.encodeWithSelector(EquiVault.ProposalAlreadyActive.selector, uint256(1)));
        _proposeParameters(vault, 500, 200);

        // ...cancelling it frees the slot; a pending parameter proposal then blocks a basket one.
        vm.prank(manager);
        vault.cancelReallocation();
        _proposeParameters(vault, 500, 200);
        vm.expectRevert(abi.encodeWithSelector(EquiVault.ProposalAlreadyActive.selector, uint256(2)));
        vm.prank(manager);
        vault.proposeReallocation(_assetsAB(), _weights(6_000, 4_000), 1_000_000e6);

        vm.prank(manager);
        vault.cancelParameterUpdate();
        vm.prank(manager);
        vault.proposeReallocation(_assetsAB(), _weights(6_000, 4_000), 1_000_000e6);
        assertEq(vault.activeProposal().id, 3);
    }

    // ------------------------------------------------------------------
    // Rebalancing
    // ------------------------------------------------------------------

    function testRebalanceRevertsWhenDriftBelowThreshold() public {
        EquiVault vault = _deployVault(EquiVault.TimelockMode.Instant, 0);
        usdc.mint(alice, 1_000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(1_000e6, alice);
        vm.stopPrank();

        (uint256 maxDev, bool above) = vault.measureDrift();
        assertFalse(above);
        vm.expectRevert(abi.encodeWithSelector(EquiVault.DriftBelowThreshold.selector, maxDev, uint16(300)));
        _rebalance(vault, new uint256[](0));
    }

    function testRebalanceRestoresTargetWeightsAndEmitsHistory() public {
        EquiVault vault = _fundedVaultWithDrift(EquiVault.TimelockMode.Instant, 0);

        vm.recordLogs();
        uint256 rebate = _rebalance(vault, new uint256[](0));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(rebate, 0, "no gas price -> no rebate");

        // Drift is back under the threshold.
        (uint256 maxDev, bool above) = vault.measureDrift();
        assertTrue(maxDev < 300, "drift not restored");
        assertFalse(above);

        // The history event exposes executor, net result and weights before/after.
        bytes32 topic = keccak256("Rebalanced(address,uint256,uint256,uint256,uint256[],uint256[])");
        Vm.Log memory rebalanced;
        bool found;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] == topic) {
                rebalanced = logs[i];
                found = true;
                break;
            }
        }
        assertTrue(found, "Rebalanced event not emitted");
        assertEq(address(uint160(uint256(rebalanced.topics[1]))), keeper);
        (
            uint256 gasRebate,
            uint256 soldValueUsdc,
            uint256 boughtValueUsdc,
            uint256[] memory wBefore,
            uint256[] memory wAfter
        ) = abi.decode(rebalanced.data, (uint256, uint256, uint256, uint256[], uint256[]));
        assertEq(gasRebate, 0);
        assertGt(soldValueUsdc, 0, "nothing sold");
        assertGt(boughtValueUsdc, 0, "nothing bought");
        assertGt(wBefore[0], 6_000, "asset A overweight before rebalance");
        assertLt(wAfter[0], 6_100, "asset A back toward target");
        assertGt(wAfter[0], 5_900, "asset A back toward target");
    }

    function testRebalancePaysMeasuredGasRebate() public {
        EquiVault vault = _fundedVaultWithDrift(EquiVault.TimelockMode.Instant, 0);

        uint256 keeperBefore = usdc.balanceOf(keeper);
        vm.txGasPrice(1 gwei);
        uint256 rebate = _rebalance(vault, new uint256[](0));
        uint256 keeperAfter = usdc.balanceOf(keeper);

        assertGt(rebate, 0, "rebate must be measured and paid");
        assertLt(rebate, vault.MAX_GAS_REBATE(), "1 gwei on ~300k gas stays under the cap");
        assertEq(keeperAfter - keeperBefore, rebate, "executor received the full rebate");
    }

    function testRebalanceGasRebateIsCapped() public {
        EquiVault vault = _fundedVaultWithDrift(EquiVault.TimelockMode.Instant, 0);

        vm.txGasPrice(1_000 gwei);
        uint256 rebate = _rebalance(vault, new uint256[](0));
        assertEq(rebate, vault.MAX_GAS_REBATE(), "absurd gas price clamps to the cap");
    }

    function testRebalanceMinTooPermissiveReverts() public {
        EquiVault vault = _fundedVaultWithDrift(EquiVault.TimelockMode.Instant, 0);

        uint256[] memory mins = new uint256[](2);
        mins[0] = 1; // far below the default collective-slippage bound
        vm.prank(keeper);
        try vault.rebalance(
            EquiVault.RebalanceParams({deadline: block.timestamp + 1 hours, minAmountsOut: mins})
        ) {
            fail("permissive min out should have reverted");
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), EquiVault.RebalanceMinTooPermissive.selector);
        }
    }

    function testRebalanceStricterMinOutIsEnforced() public {
        EquiVault vault = _fundedVaultWithDrift(EquiVault.TimelockMode.Instant, 0);

        // An unattainable min out (stricter than the default) must be enforced on-chain.
        uint256[] memory mins = new uint256[](2);
        mins[1] = 1e30;
        vm.expectRevert();
        _rebalance(vault, mins);
    }

    function testRebalanceDeadlineExpiredReverts() public {
        EquiVault vault = _fundedVaultWithDrift(EquiVault.TimelockMode.Instant, 0);

        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(EquiVault.DeadlineExpired.selector, block.timestamp)
        );
        vault.rebalance(
            EquiVault.RebalanceParams({deadline: block.timestamp - 1, minAmountsOut: new uint256[](0)})
        );
    }

    function testRebalancePausedWhenOraclesFail() public {
        EquiVault vault = _fundedVaultWithDrift(EquiVault.TimelockMode.Instant, 0);

        primaryA.setFails(true);
        fallbackA.setFails(true);
        assertTrue(vault.paused());
        vm.expectRevert(abi.encodeWithSelector(EquiVault.VaultPaused.selector));
        _rebalance(vault, new uint256[](0));
    }

    function testRebalanceCannotRunTwiceInARow() public {
        EquiVault vault = _fundedVaultWithDrift(EquiVault.TimelockMode.Instant, 0);

        _rebalance(vault, new uint256[](0));
        (uint256 dev, bool above) = vault.measureDrift();
        assertFalse(above);
        vm.expectRevert(
            abi.encodeWithSelector(EquiVault.DriftBelowThreshold.selector, dev, vault.driftThresholdBps())
        );
        _rebalance(vault, new uint256[](0));
    }

    function testRebalanceConcurrentExecutorsSecondRejected() public {
        EquiVault vault = _fundedVaultWithDrift(EquiVault.TimelockMode.Instant, 0);

        _rebalance(vault, new uint256[](0));
        (uint256 dev,) = vault.measureDrift();
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(EquiVault.DriftBelowThreshold.selector, dev, vault.driftThresholdBps())
        );
        vault.rebalance(
            EquiVault.RebalanceParams({deadline: block.timestamp + 1 hours, minAmountsOut: new uint256[](0)})
        );
    }

    function testRebalanceRevertsWhenRouteDrained() public {
        EquiVault vault = _fundedVaultWithDrift(EquiVault.TimelockMode.Instant, 0);

        // Dry the USDC leg of route A: the sell cannot deliver (ERC20InsufficientBalance from the
        // token transfer) -> the whole rebalance reverts, funds stay in the vault.
        uint256 bal = usdc.balanceOf(address(routeA));
        routeA.drain(address(usdc), bob, bal);

        vm.expectRevert();
        _rebalance(vault, new uint256[](0));
    }

    function testRebalanceUsesUpdatedThreshold() public {
        EquiVault vault = _deployVault(EquiVault.TimelockMode.Delayed, 1 days);

        // Stronger drift: A +25 % -> ~5.2-point deviation.
        usdc.mint(alice, 1_000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(1_000e6, alice);
        vm.stopPrank();
        primaryA.setPrice(125e18, block.timestamp);
        (uint256 maxDev,) = vault.measureDrift();
        assertTrue(maxDev > 300, "setup drift too small");
        assertTrue(maxDev < 1_000, "setup drift above 10-point max");

        // Raising the threshold to 10 points (1,000 bps) above the current drift blocks rebalancing.
        _proposeParameters(vault, 1_000, 100);
        vm.warp(block.timestamp + 1 days);
        // Refresh prices keeping the drifted A price, otherwise the drift would vanish.
        primaryA.setPrice(125e18, block.timestamp);
        fallbackA.setPrice(99e18, block.timestamp);
        primaryB.setPrice(PRICE_B, block.timestamp);
        fallbackB.setPrice(49e18, block.timestamp);
        vault.executeParameterUpdate();
        assertEq(vault.driftThresholdBps(), 1_000);

        vm.expectRevert(abi.encodeWithSelector(EquiVault.DriftBelowThreshold.selector, maxDev, uint16(1_000)));
        _rebalance(vault, new uint256[](0));
    }

    // ------------------------------------------------------------------
    // RebalanceEngine coordinator
    // ------------------------------------------------------------------

    function testEngineNeedsRebalance() public {
        EquiVault vault = _deployVault(EquiVault.TimelockMode.Instant, 0);
        assertFalse(engine.needsRebalance(vault), "empty vault never needs rebalancing");

        EquiVault drifted = _fundedVaultWithDrift(EquiVault.TimelockMode.Instant, 0);
        assertTrue(engine.needsRebalance(drifted));
        (uint256 engineDev, bool engineAbove) = engine.measureDrift(drifted);
        (uint256 vaultDev,) = drifted.measureDrift();
        assertEq(engineDev, vaultDev, "engine drift matches the vault view");
        assertTrue(engineAbove);
    }

    function testEngineRebalanceDelegatesAndRefundsKeeper() public {
        EquiVault vault = _fundedVaultWithDrift(EquiVault.TimelockMode.Instant, 0);

        uint256 keeperBefore = usdc.balanceOf(keeper);
        vm.txGasPrice(1 gwei);
        vm.prank(keeper);
        uint256 rebate = engine.rebalance(
            vault, EquiVault.RebalanceParams({deadline: block.timestamp + 1 hours, minAmountsOut: new uint256[](0)})
        );
        uint256 keeperAfter = usdc.balanceOf(keeper);

        assertGt(rebate, 0);
        assertEq(keeperAfter - keeperBefore, rebate, "engine forwards the full rebate to its caller");
        (, bool above) = vault.measureDrift();
        assertFalse(above, "vault rebalanced through the engine");
        assertFalse(engine.needsRebalance(vault));
    }

    function testEngineRebalanceRejectsWithoutDrift() public {
        EquiVault vault = _deployVault(EquiVault.TimelockMode.Instant, 0);
        usdc.mint(alice, 1_000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(1_000e6, alice);
        vm.stopPrank();

        (uint256 dev,) = vault.measureDrift();
        vm.expectRevert(
            abi.encodeWithSelector(RebalanceEngine.DriftBelowThreshold.selector, dev, vault.driftThresholdBps())
        );
        vm.prank(keeper);
        engine.rebalance(
            vault, EquiVault.RebalanceParams({deadline: block.timestamp + 1 hours, minAmountsOut: new uint256[](0)})
        );
    }

    // ------------------------------------------------------------------
    // Fixtures
    // ------------------------------------------------------------------

    function _assetsAB() internal view returns (address[] memory) {
        address[] memory a = new address[](2);
        a[0] = address(tokenA);
        a[1] = address(tokenB);
        return a;
    }

    function _weights(uint16 w0, uint16 w1) internal pure returns (uint16[] memory) {
        uint16[] memory w = new uint16[](2);
        w[0] = w0;
        w[1] = w1;
        return w;
    }
}
