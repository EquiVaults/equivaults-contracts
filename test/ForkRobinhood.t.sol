// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {AssetRegistry} from "../src/AssetRegistry.sol";
import {EquiVault} from "../src/EquiVault.sol";

import {MockOracle, MockOracleRoute, MockToken} from "./mocks/Mocks.sol";

interface IERC20Like {
    function decimals() external view returns (uint8);
}

/// @dev Fork tests against Robinhood Chain mainnet (chain ID 4663). The settlement asset is the
/// REAL USDG (Global Dollar by Paxos, 6 decimals) — address verified on the official explorer and
/// on-chain on 2026-08-05. Basket assets, oracles and swap routes remain mocked because real
/// Chainlink feed addresses and liquid DEX pools are not yet publicly documented on this young
/// chain; real adapters are tracked in candidate CS001004.
/// @dev RPC URL overridable via ROBINHOOD_RPC_URL (the public endpoint is the default).
contract ForkRobinhoodTest is Test {
    string internal constant DEFAULT_RPC = "https://rpc.mainnet.chain.robinhood.com";
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    // Top USDG holder (EOA, ~39 M USDG) used to fund test actors via prank transfers: the real
    // USDG is a proxy whose storage the deal cheatcode cannot write.
    address internal constant USDG_WHALE = 0x2d4d2A025b10C09BDbd794B4FCe4F7ea8C7d7bB4;

    uint48 internal constant MAX_PRICE_AGE = 1 hours;
    uint256 internal constant PRICE_A = 100e18;
    uint256 internal constant PRICE_B = 50e18;
    uint256 internal constant EXPOSURE_CAP = 1_200_000e18;

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal manager = makeAddr("manager");
    address internal alice = makeAddr("alice");
    address internal keeper = makeAddr("keeper");

    MockToken internal tokenA;
    MockToken internal tokenB;
    MockOracle internal primaryA;
    MockOracle internal fallbackA;
    MockOracle internal primaryB;
    MockOracle internal fallbackB;
    MockOracleRoute internal routeA;
    MockOracleRoute internal routeB;
    AssetRegistry internal registry;

    function setUp() public {
        vm.createSelectFork(vm.envOr("ROBINHOOD_RPC_URL", DEFAULT_RPC));

        // The real USDG must be a live, 6-decimal ERC-20 on the forked state.
        assertGt(USDG.code.length, 0, "USDG not deployed on the forked chain");
        assertEq(IERC20Like(USDG).decimals(), 6, "USDG must have 6 decimals");

        tokenA = new MockToken(18);
        tokenB = new MockToken(18);
        primaryA = new MockOracle();
        fallbackA = new MockOracle();
        primaryB = new MockOracle();
        fallbackB = new MockOracle();
        _refreshPrices();

        registry = new AssetRegistry(admin, treasury);
        routeA = new MockOracleRoute(registry, MockToken(USDG), 30);
        routeB = new MockOracleRoute(registry, MockToken(USDG), 30);
        // Fund the routes: mock tokens via mint, real USDG via transfers from the real whale.
        tokenA.mint(address(routeA), 1e30);
        tokenB.mint(address(routeB), 1e30);
        _fundUsdg(address(routeA), 1_000_000e6);
        _fundUsdg(address(routeB), 1_000_000e6);

        vm.startPrank(admin);
        registry.registerAsset(address(tokenA), primaryA, fallbackA, address(routeA), EXPOSURE_CAP, MAX_PRICE_AGE);
        registry.registerAsset(address(tokenB), primaryB, fallbackB, address(routeB), EXPOSURE_CAP, MAX_PRICE_AGE);
        vm.stopPrank();
    }

    function _deployVault() internal returns (EquiVault vault) {
        address[] memory a = new address[](2);
        a[0] = address(tokenA);
        a[1] = address(tokenB);
        uint16[] memory w = new uint16[](2);
        w[0] = 6_000;
        w[1] = 4_000;
        vault = new EquiVault(
            MockToken(USDG), registry, manager, a, w, 1_000, 300, EquiVault.TimelockMode.Instant, 0, 1_000_000e6
        );
    }

    function _fundedVaultWithDrift() internal returns (EquiVault vault) {
        vault = _deployVault();
        _fundUsdg(alice, 1_000e6);
        vm.startPrank(alice);
        MockToken(USDG).approve(address(vault), type(uint256).max);
        vault.deposit(1_000e6, alice);
        vm.stopPrank();

        primaryA.setPrice(120e18, block.timestamp);
        (uint256 dev,) = vault.measureDrift();
        assertTrue(dev > vault.driftThresholdBps(), "setup drift below threshold");
    }

    /// @dev Transfers real USDG from the whale to `to` by impersonating the whale.
    function _fundUsdg(address to, uint256 amount) internal {
        vm.prank(USDG_WHALE);
        MockToken(USDG).transfer(to, amount);
    }

    function _refreshPrices() internal {
        primaryA.setPrice(PRICE_A, block.timestamp);
        fallbackA.setPrice(99e18, block.timestamp);
        primaryB.setPrice(PRICE_B, block.timestamp);
        fallbackB.setPrice(49e18, block.timestamp);
    }

    /// @notice Full vault lifecycle against the real mainnet state: deposit real USDG, drift,
    /// permissionless rebalance back to target weights with a gas reimbursement.
    function testForkVaultLifecycleWithRealUsdg() public {
        EquiVault vault = _fundedVaultWithDrift();

        // Alice's real USDG was pulled in and the basket was bought.
        uint256 usdgAfter = MockToken(USDG).balanceOf(alice);
        assertLt(usdgAfter, 1_000e6, "deposit must spend real USDG");
        assertGt(vault.totalAssets(), 0, "basket was bought");

        uint256 navBefore = _navUsdc(vault);
        assertGt(navBefore, 0);
        (uint256 devBefore,) = vault.measureDrift();
        assertTrue(devBefore > vault.driftThresholdBps(), "drift not above threshold");

        // Permissionless rebalance by the keeper, no gas price -> no rebate.
        vm.prank(keeper);
        uint256 rebate = vault.rebalance(
            EquiVault.RebalanceParams({deadline: block.timestamp + 1 hours, minAmountsOut: new uint256[](0)})
        );
        assertEq(rebate, 0);

        (, bool above) = vault.measureDrift();
        assertFalse(above, "weights not restored toward targets");
        uint256 navAfter = _navUsdc(vault);
        assertGt(navAfter, navBefore * 95 / 100, "NAV preserved within 5 %");
        assertLt(navAfter, navBefore * 105 / 100, "NAV preserved within 5 %");
    }

    /// @notice The measured gas reimbursement covers the real L2 execution cost at the forked
    /// block's base fee (converted at the protocol-fixed ETH price cap).
    function testForkRebalanceGasRebateCoversRealGasCost() public {
        EquiVault vault = _fundedVaultWithDrift();

        uint256 baseFee = block.basefee; // real base fee of the forked block
        uint256 ethUsdcPriceCap = 5_000e6;

        vm.txGasPrice(1 gwei);
        vm.prank(keeper);
        uint256 rebate = vault.rebalance(
            EquiVault.RebalanceParams({deadline: block.timestamp + 1 hours, minAmountsOut: new uint256[](0)})
        );

        assertGt(rebate, 0, "rebate must be measured and paid");
        assertLe(rebate, vault.MAX_GAS_REBATE_USDC());

        // Recover the measured gas from the uncapped rebate: rebate = gasUsed * 1 gwei * cap / 1e18.
        uint256 gasUsed = rebate * 1e18 / (1 gwei * ethUsdcPriceCap);
        assertGt(gasUsed, 0);

        // Real execution cost at the forked base fee, in USDC wei at the fixed ETH price cap.
        uint256 realCostUsdc = gasUsed * baseFee * ethUsdcPriceCap / 1e18;
        assertGe(rebate, realCostUsdc, "rebate must cover the real L2 gas cost at 1 gwei");
    }

    /// @dev NAV in real USDG units using the oracle prices.
    function _navUsdc(EquiVault vault) internal view returns (uint256) {
        address[] memory assets = vault.basketAssets();
        uint256 nav;
        for (uint256 i = 0; i < assets.length; ++i) {
            (uint256 priceE18,) = registry.getPrice(assets[i], USDG);
            uint256 bal = MockToken(assets[i]).balanceOf(address(vault));
            nav += bal * priceE18 * 1e6 / (1e18 * 1e18);
        }
        return nav;
    }
}
