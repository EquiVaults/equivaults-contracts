// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {AssetRegistry} from "../src/AssetRegistry.sol";
import {EquiVault} from "../src/EquiVault.sol";
import {VaultFactory} from "../src/VaultFactory.sol";

import {MockOracle, MockPool, MockToken} from "./mocks/Mocks.sol";

contract VaultFactoryTest is Test {
    using Math for uint256;

    uint48 internal constant MAX_PRICE_AGE = 1 hours;
    uint256 internal constant PRICE_A = 100e18; // $100 per whole token
    uint256 internal constant PRICE_B = 50e18; // $50 per whole token
    uint256 internal constant EXPOSURE_CAP = 1_000_000e18; // registry ceiling per asset, USD at 1e18

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal manager = makeAddr("manager");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    MockToken internal usdc;
    MockToken internal tokenA;
    MockToken internal tokenB;
    MockOracle internal primaryA;
    MockOracle internal fallbackA;
    MockOracle internal primaryB;
    MockOracle internal fallbackB;
    MockPool internal poolA;
    MockPool internal poolB;
    AssetRegistry internal registry;
    VaultFactory internal factory;

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new MockToken(6);
        tokenA = new MockToken(18);
        tokenB = new MockToken(6);

        primaryA = new MockOracle();
        fallbackA = new MockOracle();
        primaryB = new MockOracle();
        fallbackB = new MockOracle();
        primaryA.setPrice(PRICE_A, block.timestamp);
        fallbackA.setPrice(99e18, block.timestamp);
        primaryB.setPrice(PRICE_B, block.timestamp);
        fallbackB.setPrice(49e18, block.timestamp);

        poolA = new MockPool(usdc, tokenA, 30);
        poolB = new MockPool(usdc, tokenB, 30);
        usdc.mint(address(this), 20_000_000e6);
        tokenA.mint(address(this), 100_000e18);
        tokenB.mint(address(this), 200_000e6);
        usdc.approve(address(poolA), type(uint256).max);
        usdc.approve(address(poolB), type(uint256).max);
        tokenA.approve(address(poolA), type(uint256).max);
        tokenB.approve(address(poolB), type(uint256).max);
        poolA.seed(10_000_000e6, 100_000e18);
        poolB.seed(10_000_000e6, 200_000e6);

        registry = new AssetRegistry(admin, treasury);
        vm.startPrank(admin);
        registry.registerAsset(address(tokenA), primaryA, fallbackA, address(poolA), EXPOSURE_CAP, MAX_PRICE_AGE);
        registry.registerAsset(address(tokenB), primaryB, fallbackB, address(poolB), EXPOSURE_CAP, MAX_PRICE_AGE);
        vm.stopPrank();

        factory = new VaultFactory(usdc, registry);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _assetsAB() internal view returns (address[] memory) {
        address[] memory a = new address[](2);
        a[0] = address(tokenA);
        a[1] = address(tokenB);
        return a;
    }

    function _weightsAB() internal pure returns (uint16[] memory) {
        uint16[] memory w = new uint16[](2);
        w[0] = 6_000;
        w[1] = 4_000;
        return w;
    }

    /// @dev Default creation: fee 10 %, vault slippage 3 %, Delayed 1 day, cap 1M settlement units,
    /// drift/slippage on protocol defaults.
    function _createVault() internal returns (address vault) {
        vault = factory.createVault(
            manager, _assetsAB(), _weightsAB(), 1_000, 300, EquiVault.TimelockMode.Delayed, 1 days, 1_000_000e6, 0, 0
        );
    }

    // ------------------------------------------------------------------
    // Creation fixes every parameter within its bounds
    // ------------------------------------------------------------------

    function testCreateVaultFixesAllParameters() public {
        address[] memory a = _assetsAB();
        uint16[] memory w = _weightsAB();
        address vault = factory.createVault(
            manager, a, w, 1_000, 200, EquiVault.TimelockMode.Delayed, 2 days, 500_000e6, 500, 200
        );

        EquiVault v = EquiVault(vault);
        assertEq(v.manager(), manager);
        assertEq(v.feeBps(), 1_000);
        assertEq(v.maxSlippageBps(), 200);
        assertEq(uint8(v.timelockMode()), uint8(EquiVault.TimelockMode.Delayed));
        assertEq(v.timelockDelay(), 2 days);
        assertEq(v.capAum(), 500_000e6);
        assertEq(v.driftThresholdBps(), 500);
        assertEq(v.rebalanceSlippageBps(), 200);
        assertEq(address(v.asset()), address(usdc));
        assertEq(address(v.registry()), address(registry));
        assertEq(v.basketAssets().length, 2);
        assertEq(v.basketWeightsBps()[0], 6_000);
        assertEq(v.basketWeightsBps()[1], 4_000);
        assertTrue(factory.isVault(vault));
    }

    function testCreateVaultDefaultsDriftAndSlippageWhenZero() public {
        address vault = _createVault();
        EquiVault v = EquiVault(vault);
        assertEq(v.driftThresholdBps(), 300);
        assertEq(v.rebalanceSlippageBps(), 100);
    }

    function testImmutableVaultIsFrozenAtCreation() public {
        address vault = factory.createVault(
            manager, _assetsAB(), _weightsAB(), 1_000, 300, EquiVault.TimelockMode.Immutable, 0, 1_000_000e6, 500, 200
        );
        EquiVault v = EquiVault(vault);
        assertEq(uint8(v.timelockMode()), uint8(EquiVault.TimelockMode.Immutable));

        // Frozen forever: even the manager cannot change the parameters fixed at creation.
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(EquiVault.TimelockImmutable.selector));
        v.proposeParameters(600, 100);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(EquiVault.TimelockImmutable.selector));
        v.proposeReallocation(_assetsAB(), _weightsAB(), 1_000_000e6);
    }

    function testProtocolAdminHasNoPowerOverVault() public {
        EquiVault v = EquiVault(_createVault());

        // The protocol admin has no role inside the vault: it cannot propose, cancel or move funds.
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(EquiVault.NotManager.selector));
        v.proposeReallocation(_assetsAB(), _weightsAB(), 1_000_000e6);

        vm.prank(manager);
        v.proposeReallocation(_assetsAB(), _weightsAB(), 1_000_000e6);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(EquiVault.NotManager.selector));
        v.cancelReallocation();
    }

    // ------------------------------------------------------------------
    // Invalid creation parameters are rejected
    // ------------------------------------------------------------------

    function testCreateVaultRejectsAssetsNotAdmitted() public {
        address[] memory a = new address[](1);
        uint16[] memory w = new uint16[](1);
        a[0] = address(0xBEEF);
        w[0] = 10_000;
        vm.expectRevert(abi.encodeWithSelector(VaultFactory.AssetNotAdmissible.selector, address(0xBEEF)));
        factory.createVault(manager, a, w, 1_000, 300, EquiVault.TimelockMode.Instant, 0, 1_000_000e6, 0, 0);

        // An ExitOnly asset is not admissible for new exposure.
        vm.startPrank(admin);
        registry.setAssetStatus(address(tokenB), AssetRegistry.AssetStatus.ExitOnly);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(VaultFactory.AssetNotAdmissible.selector, address(tokenB)));
        factory.createVault(
            manager, _assetsAB(), _weightsAB(), 1_000, 300, EquiVault.TimelockMode.Instant, 0, 1_000_000e6, 0, 0
        );

        // A global deposits pause also blocks creation.
        vm.startPrank(admin);
        registry.setAssetStatus(address(tokenB), AssetRegistry.AssetStatus.Active);
        registry.setDepositsPaused(true);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(VaultFactory.AssetNotAdmissible.selector, address(tokenA)));
        factory.createVault(
            manager, _assetsAB(), _weightsAB(), 1_000, 300, EquiVault.TimelockMode.Instant, 0, 1_000_000e6, 0, 0
        );
    }

    function testCreateVaultRejectsSettlementInBasket() public {
        // The deployment settlement asset is never admissible inside a basket.
        address[] memory a = new address[](2);
        a[0] = address(usdc);
        a[1] = address(tokenA);
        uint16[] memory w = new uint16[](2);
        w[0] = 6_000;
        w[1] = 4_000;
        vm.expectRevert(abi.encodeWithSelector(VaultFactory.AssetNotAdmissible.selector, address(usdc)));
        factory.createVault(manager, a, w, 1_000, 300, EquiVault.TimelockMode.Instant, 0, 1_000_000e6, 0, 0);
    }

    function testCreateVaultRejectsInvalidParameters() public {
        address[] memory a = _assetsAB();
        uint16[] memory w = _weightsAB();

        // fee above the immutable 20 % cap
        vm.expectRevert(abi.encodeWithSelector(EquiVault.InvalidFee.selector, uint16(2_001)));
        factory.createVault(manager, a, w, 2_001, 300, EquiVault.TimelockMode.Instant, 0, 1_000_000e6, 0, 0);

        // vault slippage above the 30 % cap
        vm.expectRevert(abi.encodeWithSelector(EquiVault.InvalidSlippage.selector, uint16(3_001)));
        factory.createVault(manager, a, w, 1_000, 3_001, EquiVault.TimelockMode.Instant, 0, 1_000_000e6, 0, 0);

        // weight below the 5 % floor
        uint16[] memory lowW = _weightsAB();
        lowW[1] = 100;
        vm.expectRevert(abi.encodeWithSelector(EquiVault.InvalidWeight.selector, uint16(100)));
        factory.createVault(manager, a, lowW, 1_000, 300, EquiVault.TimelockMode.Instant, 0, 1_000_000e6, 0, 0);

        // weights not summing to 100 %
        address[] memory one = new address[](1);
        one[0] = address(tokenA);
        uint16[] memory partialW = new uint16[](1);
        partialW[0] = 5_000;
        vm.expectRevert(abi.encodeWithSelector(EquiVault.WeightsMustSumTo10000.selector, uint256(5_000)));
        factory.createVault(manager, one, partialW, 1_000, 300, EquiVault.TimelockMode.Instant, 0, 1_000_000e6, 0, 0);

        // timelock delay outside the 1-7 day window for Delayed mode
        vm.expectRevert(abi.encodeWithSelector(EquiVault.InvalidTimelockDelay.selector, uint256(8 days)));
        factory.createVault(manager, a, w, 1_000, 300, EquiVault.TimelockMode.Delayed, 8 days, 1_000_000e6, 0, 0);

        // AUM cap above the registry-derived ceiling
        uint256 bound = Math.mulDiv(EXPOSURE_CAP, 10_000, 6_000).mulDiv(1e6, 1e18);
        vm.expectRevert(abi.encodeWithSelector(EquiVault.InvalidAumCap.selector, bound + 1, bound));
        factory.createVault(manager, a, w, 1_000, 300, EquiVault.TimelockMode.Delayed, 1 days, bound + 1, 0, 0);

        // drift outside the 1-10 point window
        vm.expectRevert(abi.encodeWithSelector(EquiVault.InvalidDriftThreshold.selector, uint16(50)));
        factory.createVault(manager, a, w, 1_000, 300, EquiVault.TimelockMode.Instant, 0, 1_000_000e6, 50, 0);

        // collective rebalance slippage above the 3 % cap
        vm.expectRevert(abi.encodeWithSelector(EquiVault.InvalidRebalanceSlippage.selector, uint16(301)));
        factory.createVault(manager, a, w, 1_000, 300, EquiVault.TimelockMode.Instant, 0, 1_000_000e6, 0, 301);
    }

    // ------------------------------------------------------------------
    // Permissionless deployment and registry
    // ------------------------------------------------------------------

    function testPermissionlessCreation() public {
        // Anyone may create a vault for any manager, paying only the gas.
        vm.prank(alice);
        address v1 = factory.createVault(
            manager, _assetsAB(), _weightsAB(), 1_000, 300, EquiVault.TimelockMode.Instant, 0, 1_000_000e6, 0, 0
        );
        vm.prank(bob);
        address v2 = factory.createVault(
            manager, _assetsAB(), _weightsAB(), 500, 300, EquiVault.TimelockMode.Delayed, 2 days, 1_000_000e6, 0, 0
        );
        vm.prank(manager);
        address v3 = factory.createVault(
            bob, _assetsAB(), _weightsAB(), 2_000, 300, EquiVault.TimelockMode.Immutable, 0, 1_000_000e6, 0, 0
        );

        assertEq(factory.vaultCount(), 3);
        assertEq(factory.vaults(0), v1);
        assertEq(factory.vaults(1), v2);
        assertEq(factory.vaults(2), v3);
        assertTrue(factory.isVault(v1));
        assertTrue(factory.isVault(v2));
        assertTrue(factory.isVault(v3));
        assertFalse(factory.isVault(address(0x1234)));
        // The three vaults are fully independent instances.
        assertTrue(v1 != v2 && v2 != v3 && v1 != v3);
    }

    function testFactoryExposesChainIdAndSettlement() public {
        assertEq(factory.chainId(), block.chainid);
        assertEq(address(factory.settlementAsset()), address(usdc));
        assertEq(address(factory.registry()), address(registry));
    }

    function testVaultCreatedEventCarriesIndexingData() public {
        vm.recordLogs();
        address v1 = factory.createVault(
            manager, _assetsAB(), _weightsAB(), 1_000, 300, EquiVault.TimelockMode.Delayed, 1 days, 1_000_000e6, 0, 0
        );
        address v2 = factory.createVault(
            manager, _assetsAB(), _weightsAB(), 0, 300, EquiVault.TimelockMode.Instant, 0, 1_000_000e6, 0, 0
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 created;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] != VaultFactory.VaultCreated.selector) continue;
            created++;
            // Indexed: vault, manager, settlement asset — the manager's full history is
            // rebuildable by filtering these events on the `manager` topic.
            assertEq(address(uint160(uint256(logs[i].topics[1]))), created == 1 ? v1 : v2);
            assertEq(address(uint160(uint256(logs[i].topics[2]))), manager);
            assertEq(address(uint160(uint256(logs[i].topics[3]))), address(usdc));

            (
                uint256 chainId,
                uint8 mode,
                uint256 delay,
                uint16 fee,
                uint16 maxSlip,
                uint16 drift,
                uint16 rebalSlip,
                uint256 cap
            ) = abi.decode(logs[i].data, (uint256, uint8, uint256, uint16, uint16, uint16, uint16, uint256));
            assertEq(chainId, block.chainid);
            assertEq(mode, created == 1 ? uint8(EquiVault.TimelockMode.Delayed) : uint8(EquiVault.TimelockMode.Instant));
            assertEq(delay, created == 1 ? 1 days : 0);
            assertEq(fee, created == 1 ? 1_000 : 0);
            assertEq(maxSlip, 300);
            assertEq(drift, 300);
            assertEq(rebalSlip, 100);
            assertEq(cap, 1_000_000e6);

            // The basket is read live from the vault, never from a stale event snapshot.
            EquiVault v = EquiVault(created == 1 ? v1 : v2);
            assertEq(v.basketAssets().length, 2);
            assertEq(v.basketWeightsBps()[0] + v.basketWeightsBps()[1], 10_000);
        }
        assertEq(created, 2);
    }
}
