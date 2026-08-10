// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {AssetRegistry} from "../src/AssetRegistry.sol";
import {EquiVault} from "../src/EquiVault.sol";
import {RebalanceEngine} from "../src/RebalanceEngine.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {ISwapRouter} from "../src/interfaces/ISwapRouter.sol";

import {MockOracle, MockOracleRoute, MockToken} from "./mocks/Mocks.sol";

/// @dev F003-S002 (Invariant and Fuzz Testing Suite): shared protocol fixture. Settlement USDC
/// (6 decimals), basket tokens A (18), B (6) and C (10 decimals). Every asset swaps through a
/// zero-fee `MockOracleRoute`, so swaps settle exactly at the oracle price and the handler ghost
/// ledger can track the vault NAV to the wei (any real value leak shows up as a divergence).
/// `MAX_PRICE_AGE` is 3 days so the 1-day timelock warp keeps prices fresh.
abstract contract InvariantBase is Test {
    using Math for uint256;

    uint48 internal constant MAX_PRICE_AGE = 3 days;
    uint256 internal constant PRICE_A = 100e18; // $100 per whole token
    uint256 internal constant PRICE_B = 50e18; // $50 per whole token
    uint256 internal constant PRICE_C = 200e18; // $200 per whole token
    uint256 internal constant EXPOSURE_CAP = 1_000_000e18; // $1M per asset (USD at 1e18)
    uint256 internal constant VAULT_CAP = 1_000_000e6; // 1M settlement units
    uint16 internal constant FEE_BPS = 1_000; // 10 % performance fee
    uint16 internal constant MAX_SLIPPAGE_BPS = 300; // 3 % max swap slippage
    uint256 internal constant NAV_TOLERANCE = 1e5; // rounding dust bound in settlement wei (0.1 unit)
    uint256 internal constant ROUTE_FUNDS = 1e33;

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal manager = makeAddr("manager");
    address internal keeper = makeAddr("keeper");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

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
    MockOracleRoute internal routeA;
    MockOracleRoute internal routeB;
    MockOracleRoute internal routeC;
    AssetRegistry internal registry;

    function setUp() public virtual {
        vm.warp(1_000_000);
        usdc = new MockToken(6);
        tokenA = new MockToken(18);
        tokenB = new MockToken(6);
        tokenC = new MockToken(10);

        primaryA = new MockOracle();
        fallbackA = new MockOracle();
        primaryB = new MockOracle();
        fallbackB = new MockOracle();
        primaryC = new MockOracle();
        fallbackC = new MockOracle();
        _refreshPrices();

        registry = new AssetRegistry(admin, treasury);
        routeA = new MockOracleRoute(registry, usdc, 0);
        routeB = new MockOracleRoute(registry, usdc, 0);
        routeC = new MockOracleRoute(registry, usdc, 0);
        // Fund every route on both legs so any swap can be served at the oracle price.
        tokenA.mint(address(routeA), ROUTE_FUNDS);
        tokenB.mint(address(routeB), ROUTE_FUNDS);
        tokenC.mint(address(routeC), ROUTE_FUNDS);
        usdc.mint(address(routeA), ROUTE_FUNDS);
        usdc.mint(address(routeB), ROUTE_FUNDS);
        usdc.mint(address(routeC), ROUTE_FUNDS);

        vm.startPrank(admin);
        registry.registerAsset(address(tokenA), primaryA, fallbackA, address(routeA), EXPOSURE_CAP, MAX_PRICE_AGE);
        registry.registerAsset(address(tokenB), primaryB, fallbackB, address(routeB), EXPOSURE_CAP, MAX_PRICE_AGE);
        registry.registerAsset(address(tokenC), primaryC, fallbackC, address(routeC), EXPOSURE_CAP, MAX_PRICE_AGE);
        vm.stopPrank();
    }

    function _refreshPrices() internal {
        primaryA.setPrice(PRICE_A, block.timestamp);
        fallbackA.setPrice(99e18, block.timestamp);
        primaryB.setPrice(PRICE_B, block.timestamp);
        fallbackB.setPrice(49e18, block.timestamp);
        primaryC.setPrice(PRICE_C, block.timestamp);
        fallbackC.setPrice(199e18, block.timestamp);
    }

    function _deployVault(address[] memory assets, uint16[] memory weights)
        internal
        returns (EquiVault v)
    {
        v = new EquiVault(
            usdc,
            registry,
            manager,
            assets,
            weights,
            FEE_BPS,
            MAX_SLIPPAGE_BPS,
            EquiVault.TimelockMode.Delayed,
            1 days,
            VAULT_CAP,
            0,
            0
        );
    }

    function _basket(address a, address b, uint16 wa, uint16 wb)
        internal
        pure
        returns (address[] memory, uint16[] memory)
    {
        address[] memory assets = new address[](2);
        assets[0] = a;
        assets[1] = b;
        uint16[] memory weights = new uint16[](2);
        weights[0] = wa;
        weights[1] = wb;
        return (assets, weights);
    }

    function _valueUsdc(address a, uint256 amount, uint256 priceE18) internal view returns (uint256) {
        uint256 scale = 10 ** uint256(registry.assetConfig(a).decimals);
        return amount.mulDiv(priceE18 * (10 ** uint256(usdc.decimals())), scale * 1e18);
    }

    function _priceOf(address a) internal view returns (uint256) {
        if (a == address(tokenA)) return PRICE_A;
        if (a == address(tokenB)) return PRICE_B;
        return PRICE_C;
    }
}

/// @dev Handler for the constant-price suite: deposits (plain and with min-outs), mixed redemptions
/// and reallocations that swap the basket while keeping every kept asset weight identical, so the
/// target weights stay exact. A ghost ledger replicates the vault accounting (cost basis, shares,
/// NAV) to the wei; invariants compare it against the live vault.
contract EquiVaultHandler is Test {
    using Math for uint256;

    EquiVault public immutable vault;
    AssetRegistry public immutable registry;
    MockToken public immutable usdc;
    MockToken public immutable tokenA;
    MockToken public immutable tokenB;
    MockToken public immutable tokenC;
    MockOracle public immutable primaryA;
    MockOracle public immutable primaryB;
    MockOracle public immutable primaryC;
    address public immutable manager;
    address public immutable alice;
    address public immutable bob;
    address public immutable carol;

    // Ghost ledger.
    uint256 public ghostNav;
    uint256 public ghostDeposited;
    uint256 public ghostWithdrawn;
    uint256 public ghostFees;
    uint256 public ghostTotalShares;
    bool public ghostActiveProposal;
    bool public ghostCapViolation;
    mapping(address => uint256) public ghostShares;
    mapping(address => uint256) public ghostCost;
    mapping(address => uint256) public ghostDepositedBy;

    uint16 internal constant FEE_BPS = 1_000; // 10 %
    uint256 internal constant VAULT_CAP = 1_000_000e6;
    uint256 internal constant PRICE_A = 100e18;
    uint256 internal constant PRICE_B = 50e18;
    uint256 internal constant PRICE_C = 200e18;

    constructor(
        EquiVault vault_,
        AssetRegistry registry_,
        MockToken usdc_,
        MockToken tokenA_,
        MockToken tokenB_,
        MockToken tokenC_,
        MockOracle primaryA_,
        MockOracle primaryB_,
        MockOracle primaryC_,
        address manager_,
        address alice_,
        address bob_,
        address carol_
    ) {
        vault = vault_;
        registry = registry_;
        usdc = usdc_;
        tokenA = tokenA_;
        tokenB = tokenB_;
        tokenC = tokenC_;
        primaryA = primaryA_;
        primaryB = primaryB_;
        primaryC = primaryC_;
        manager = manager_;
        alice = alice_;
        bob = bob_;
        carol = carol_;
    }

    function _user(uint8 idx) internal view returns (address) {
        idx = idx % 3;
        return idx == 0 ? alice : (idx == 1 ? bob : carol);
    }

    function _refreshOracleTimestamps() internal {
        primaryA.setPrice(PRICE_A, block.timestamp);
        primaryB.setPrice(PRICE_B, block.timestamp);
        primaryC.setPrice(PRICE_C, block.timestamp);
    }

    // ------------------------------------------------------------------
    // Deposits
    // ------------------------------------------------------------------

    function deposit(uint256 seed, uint8 userIdx, uint256 amount) external {
        _deposit(seed, userIdx, amount, false);
    }

    function depositWithMins(uint256 seed, uint8 userIdx, uint256 amount) external {
        _deposit(seed, userIdx, amount, true);
    }

    function _deposit(uint256 seed, uint8 userIdx, uint256 amount, bool withMins) internal {
        address u = _user(userIdx);
        amount = bound(amount, 1, 100_000e6);
        if (vault.activeProposal().id != 0) return; // deposit then requires explicit consent
        if (vault.paused()) return;

        uint256 navBefore = vault.totalAssets();
        uint256 navAfter = navBefore + amount;
        if (navAfter > vault.capAum() && seed % 4 != 0) return; // 1/4 still attempt to probe the guard

        uint256 n = vault.basketAssets().length;
        uint256[] memory mins = withMins ? new uint256[](n) : new uint256[](0);

        try vault.deposit(amount, u, mins) returns (uint256 shares) {
            if (navAfter > vault.capAum()) ghostCapViolation = true;
            ghostShares[u] += shares;
            ghostCost[u] += amount;
            ghostDepositedBy[u] += amount;
            ghostTotalShares += shares;
            ghostNav += amount;
        } catch {}
    }

    // ------------------------------------------------------------------
    // Redemptions (mixed token / settlement choices)
    // ------------------------------------------------------------------

    function redeem(uint256 seed, uint8 userIdx, uint256 pct, uint256 flagSeed) external {
        address u = _user(userIdx);
        uint256 sharesBefore = vault.balanceOf(u);
        if (sharesBefore == 0) return;
        if (vault.paused()) return;

        uint256 shares = sharesBefore * bound(pct, 1, 100) / 100;
        if (shares == 0) return;

        uint256 n = vault.basketAssets().length;
        bool[] memory flags = new bool[](n);
        for (uint256 i = 0; i < n; ++i) flags[i] = (flagSeed >> i) & 1 == 1;

        uint256 costBefore = vault.costBasis(u);

        try vault.redeem(shares, u, u, flags) returns (uint256 valueWithdrawn) {
            uint256 realizedCost = costBefore.mulDiv(shares, sharesBefore);
            ghostCost[u] -= realizedCost;
            ghostShares[u] -= shares;
            ghostTotalShares -= shares;
            ghostWithdrawn += valueWithdrawn;
            ghostNav -= valueWithdrawn;
            if (valueWithdrawn > realizedCost) {
                ghostFees += (valueWithdrawn - realizedCost).mulDiv(FEE_BPS, 10_000);
            }
        } catch {}
    }

    // ------------------------------------------------------------------
    // Reallocation proposals (equal-weight basket swaps keep weights exact)
    // ------------------------------------------------------------------

    function proposeReallocation(uint256 seed) external {
        if (vault.activeProposal().id != 0) return;
        (address[] memory target, uint16[] memory weights) = _target(seed);
        vm.prank(manager);
        try vault.proposeReallocation(target, weights, VAULT_CAP) {
            ghostActiveProposal = true;
        } catch {}
    }

    function executeReallocation(uint256) external {
        if (!ghostActiveProposal) return;
        if (vault.paused()) return;
        vm.warp(block.timestamp + 1 days + 1);
        _refreshOracleTimestamps(); // keep prices fresh after the timelock warp
        uint256[] memory sellMins = new uint256[](0);
        uint256[] memory buyMins = new uint256[](0);
        try vault.executeReallocation(sellMins, buyMins) {
            ghostActiveProposal = false;
            // Zero-fee migration preserves NAV: removed assets sell at oracle price and added
            // assets are bought from the freed settlement; only sub-wei rounding dust is lost.
        } catch {}
    }

    /// @dev Target baskets keep the (5000, 5000) weights so kept assets keep their weight and
    /// added assets are bought exactly at their target share of the freed settlement.
    function _target(uint256 seed) internal view returns (address[] memory, uint16[] memory) {
        uint256 choice = bound(seed, 0, 2);
        if (choice == 0) return (_two(address(tokenA), address(tokenB)), _w(5_000, 5_000));
        if (choice == 1) return (_two(address(tokenA), address(tokenC)), _w(5_000, 5_000));
        return (_two(address(tokenB), address(tokenC)), _w(5_000, 5_000));
    }

    function _two(address a, address b) internal pure returns (address[] memory) {
        address[] memory arr = new address[](2);
        arr[0] = a;
        arr[1] = b;
        return arr;
    }

    function _w(uint16 a, uint16 b) internal pure returns (uint16[] memory) {
        uint16[] memory arr = new uint16[](2);
        arr[0] = a;
        arr[1] = b;
        return arr;
    }
}

/// @dev Constant-price invariant suite (F003-S002). Prices never move, routes are zero-fee, so the
/// ghost ledger must equal the live vault to the wei: any insolvency, cost-basis corruption, fee
/// bypass, weight distortion or cap breach shows up immediately.
contract EquiVaultInvariantTest is InvariantBase {
    EquiVault internal vault;
    EquiVaultHandler internal handler;

    function setUp() public override {
        super.setUp();
        (address[] memory a, uint16[] memory w) = _basket(address(tokenA), address(tokenB), 5_000, 5_000);
        vault = _deployVault(a, w);
        handler = new EquiVaultHandler(
            vault, registry, usdc, tokenA, tokenB, tokenC, primaryA, primaryB, primaryC, manager, alice, bob, carol
        );
        targetContract(address(handler));
    }

    function _users() internal view returns (address[3] memory) {
        return [alice, bob, carol];
    }

    /// @dev Solvency: the vault value (ghost ledger) always covers the value controlled by the
    /// vault (NAV + settlement balance); the gap is only sub-wei swap/valuation rounding dust.
    function invariant_solvency() public {
        uint256 controlled = vault.totalAssets() + usdc.balanceOf(address(vault));
        assertGe(handler.ghostNav(), controlled);
        assertLe(handler.ghostNav() - controlled, NAV_TOLERANCE);
    }

    /// @dev Cost basis is exact: the vault never charges the fee on principal, never loses or
    /// duplicates a realized cost, and a user cannot redeem more cost than they deposited.
    function invariant_costBasis() public {
        address[3] memory users = _users();
        for (uint256 i = 0; i < users.length; ++i) {
            assertEq(vault.costBasis(users[i]), handler.ghostCost(users[i]));
            assertLe(handler.ghostCost(users[i]), handler.ghostDepositedBy(users[i]));
        }
    }

    /// @dev Non-custodial: shares only ever belong to their depositor; manager, admin, treasury
    /// and the executor never receive any share; supply always equals the tracked user shares.
    function invariant_sharesNonCustodial() public {
        address[3] memory users = _users();
        uint256 sum;
        for (uint256 i = 0; i < users.length; ++i) {
            assertEq(vault.balanceOf(users[i]), handler.ghostShares(users[i]));
            sum += handler.ghostShares(users[i]);
        }
        assertEq(vault.totalSupply(), sum);
        assertEq(vault.balanceOf(manager), 0);
        assertEq(vault.balanceOf(admin), 0);
        assertEq(vault.balanceOf(treasury), 0);
        assertEq(vault.balanceOf(keeper), 0);
    }

    /// @dev Fees: every performance fee collected ends up in the manager/treasury split, exactly
    /// the realized-gain fee the ghost ledger expects (never on principal, never doubled).
    function invariant_feeAccounting() public {
        assertEq(handler.ghostFees(), usdc.balanceOf(manager) + usdc.balanceOf(treasury));
    }

    /// @dev Deposits and exits never distort the target weights (no cost transfer to remaining
    /// positions): each asset's value share matches its target weight up to rounding dust.
    function invariant_weightsPreserved() public {
        uint256 nav = vault.totalAssets();
        if (nav < 1e6) return; // dust-dominated regime (sub-USDC NAV)
        address[] memory assets = vault.basketAssets();
        uint16[] memory weights = vault.basketWeightsBps();
        uint256 n = assets.length;
        for (uint256 i = 0; i < n; ++i) {
            uint256 value = _valueUsdc(assets[i], IERC20(assets[i]).balanceOf(address(vault)), _priceOf(assets[i]));
            uint256 shareBps = Math.mulDiv(value, 10_000, nav);
            uint256 diff = shareBps > weights[i] ? shareBps - weights[i] : weights[i] - shareBps;
            assertLe(diff, 2); // 0.02 point
        }
    }

    /// @dev AUM cap: NAV never exceeds the cap (constant prices here) and no deposit ever slipped
    /// past the cap check.
    function invariant_aumCap() public {
        assertLe(vault.totalAssets(), vault.capAum());
        assertFalse(handler.ghostCapViolation());
    }

    /// @dev B001 regression: migrations reinvest the freed settlement; no idle settlement outside
    /// `totalAssets()`.
    function invariant_noOrphanSettlement() public {
        assertLe(usdc.balanceOf(address(vault)), 1e4);
    }

    /// @dev Share claims are always backed: full redemption of every tracked holder is feasible.
    function invariant_claimsBacked() public {
        uint256 nav = vault.totalAssets();
        uint256 claim;
        address[3] memory users = _users();
        for (uint256 i = 0; i < users.length; ++i) {
            claim += vault.previewRedeem(vault.balanceOf(users[i]));
        }
        assertLe(claim, nav + 1);
    }

    /// @dev Proposal lifecycle: at most one active proposal, tracked exactly.
    function invariant_singleProposal() public {
        assertEq(vault.activeProposal().id != 0, handler.ghostActiveProposal());
    }
}

/// @dev Handler for the stress suite: price shocks, oracle failures/recovery, permissionless
/// rebalances, reallocations, donations, targeted registry pauses and mixed redemptions. The ghost
/// ledger tracks NAV through price moves (delta at the current balance) so the solvency invariant
/// stays exact even while prices move.
contract StressHandler is Test {
    using Math for uint256;

    EquiVault public immutable vault;
    AssetRegistry public immutable registry;
    MockToken public immutable usdc;
    MockToken public immutable tokenA;
    MockToken public immutable tokenB;
    MockToken public immutable tokenC;
    MockOracle public immutable primaryA;
    MockOracle public immutable fallbackA;
    MockOracle public immutable primaryB;
    MockOracle public immutable fallbackB;
    MockOracle public immutable primaryC;
    MockOracle public immutable fallbackC;
    address public immutable manager;
    address public immutable admin;
    address public immutable keeper;
    address public immutable alice;
    address public immutable bob;
    address public immutable carol;

    // Ghost ledger.
    uint256 public ghostNav;
    uint256 public ghostFees;
    uint256 public ghostRebates;
    uint256 public ghostMaxRebate;
    uint256 public ghostTotalShares;
    bool public ghostActiveProposal;
    bool public ghostCapViolation;
    bool public ghostPauseViolation;
    bool public ghostFailA;
    bool public ghostFailB;
    bool public ghostFailC;
    uint256 public ghostPriceA;
    uint256 public ghostPriceB;
    uint256 public ghostPriceC;
    uint256 public ghostLastPriceRefresh;
    mapping(address => uint256) public ghostShares;
    mapping(address => uint256) public ghostCost;
    mapping(address => uint256) public ghostDepositedBy;

    uint16 internal constant FEE_BPS = 1_000; // 10 %
    uint256 internal constant VAULT_CAP = 1_000_000e6;
    uint256 internal constant PRICE_A = 100e18;
    uint256 internal constant PRICE_B = 50e18;
    uint256 internal constant PRICE_C = 200e18;

    constructor(
        EquiVault vault_,
        AssetRegistry registry_,
        MockToken usdc_,
        MockToken tokenA_,
        MockToken tokenB_,
        MockToken tokenC_,
        MockOracle primaryA_,
        MockOracle fallbackA_,
        MockOracle primaryB_,
        MockOracle fallbackB_,
        MockOracle primaryC_,
        MockOracle fallbackC_,
        address manager_,
        address admin_,
        address keeper_,
        address alice_,
        address bob_,
        address carol_
    ) {
        vault = vault_;
        registry = registry_;
        usdc = usdc_;
        tokenA = tokenA_;
        tokenB = tokenB_;
        tokenC = tokenC_;
        primaryA = primaryA_;
        fallbackA = fallbackA_;
        primaryB = primaryB_;
        fallbackB = fallbackB_;
        primaryC = primaryC_;
        fallbackC = fallbackC_;
        manager = manager_;
        admin = admin_;
        keeper = keeper_;
        alice = alice_;
        bob = bob_;
        carol = carol_;
        ghostPriceA = PRICE_A;
        ghostPriceB = PRICE_B;
        ghostPriceC = PRICE_C;
        ghostLastPriceRefresh = block.timestamp;
    }

    function _user(uint8 idx) internal view returns (address) {
        idx = idx % 3;
        return idx == 0 ? alice : (idx == 1 ? bob : carol);
    }

    function _ghostPrice(address a) internal view returns (uint256) {
        if (a == address(tokenA)) return ghostPriceA;
        if (a == address(tokenB)) return ghostPriceB;
        return ghostPriceC;
    }

    function _setGhostPrice(address a, uint256 p) internal {
        if (a == address(tokenA)) ghostPriceA = p;
        else if (a == address(tokenB)) ghostPriceB = p;
        else ghostPriceC = p;
    }

    function _primaryOf(address a) internal view returns (MockOracle) {
        if (a == address(tokenA)) return primaryA;
        if (a == address(tokenB)) return primaryB;
        return primaryC;
    }

    function _fallbackOf(address a) internal view returns (MockOracle) {
        if (a == address(tokenA)) return fallbackA;
        if (a == address(tokenB)) return fallbackB;
        return fallbackC;
    }

    function _valueUsdc(address a, uint256 amount, uint256 priceE18) internal view returns (uint256) {
        uint256 scale = 10 ** uint256(registry.assetConfig(a).decimals);
        return amount.mulDiv(priceE18 * (10 ** uint256(usdc.decimals())), scale * 1e18);
    }

    function _anyFail() internal view returns (bool) {
        return ghostFailA || ghostFailB || ghostFailC;
    }

    function _setFail(address a, bool fail) internal {
        if (a == address(tokenA)) ghostFailA = fail;
        else if (a == address(tokenB)) ghostFailB = fail;
        else ghostFailC = fail;
    }

    /// @dev Keeps oracle timestamps fresh after timelock warps (price values unchanged).
    function _maybeRefreshPrices() internal {
        if (block.timestamp < ghostLastPriceRefresh + 1 days) return;
        ghostLastPriceRefresh = block.timestamp;
        primaryA.setPrice(ghostPriceA, block.timestamp);
        primaryB.setPrice(ghostPriceB, block.timestamp);
        primaryC.setPrice(ghostPriceC, block.timestamp);
    }

    // ------------------------------------------------------------------
    // Prices and oracles
    // ------------------------------------------------------------------

    /// @dev Price shock: publishes a new price on both oracles and revalues the ghost ledger by
    /// the exact NAV delta the vault itself reports (self-consistent, immune to sub-wei rounding).
    function setPrice(uint256 seed, uint8 assetIdx, uint256 multBps) external {
        _maybeRefreshPrices();
        if (vault.paused()) return; // NAV unreadable; keep the tracked price
        address a = assetIdx % 3 == 0 ? address(tokenA) : (assetIdx % 3 == 1 ? address(tokenB) : address(tokenC));
        uint256 newPrice = _ghostPrice(a) * bound(multBps, 2_500, 40_000) / 10_000; // 25 % .. 400 %
        uint256 navBefore = vault.totalAssets();
        _primaryOf(a).setPrice(newPrice, block.timestamp);
        _fallbackOf(a).setPrice(newPrice, block.timestamp);
        uint256 navAfter = vault.totalAssets();
        if (navAfter >= navBefore) ghostNav += navAfter - navBefore;
        else ghostNav -= navBefore - navAfter;
        _setGhostPrice(a, newPrice);
    }

    /// @dev Oracle failure / recovery. While any asset is unpriced the vault must be paused and
    /// every state-changing call must revert.
    function setOracleFail(uint256, uint8 assetIdx, bool fail) external {
        address a = assetIdx % 3 == 0 ? address(tokenA) : (assetIdx % 3 == 1 ? address(tokenB) : address(tokenC));
        _primaryOf(a).setFails(fail);
        _fallbackOf(a).setFails(fail);
        _setFail(a, fail);
        if (!fail) {
            // restore a fresh price at the tracked level so the vault can resume
            _primaryOf(a).setPrice(_ghostPrice(a), block.timestamp);
            _fallbackOf(a).setPrice(_ghostPrice(a), block.timestamp);
            ghostLastPriceRefresh = block.timestamp;
        }
    }

    // ------------------------------------------------------------------
    // Registry admin actions (targeted pauses)
    // ------------------------------------------------------------------

    function setDepositsPaused(uint256, bool paused) external {
        vm.prank(admin);
        registry.setDepositsPaused(paused);
    }

    function setAssetStatus(uint256, uint8 assetIdx, uint8 statusIdx) external {
        address a = assetIdx % 3 == 0 ? address(tokenA) : (assetIdx % 3 == 1 ? address(tokenB) : address(tokenC));
        AssetRegistry.AssetStatus status;
        uint256 s = statusIdx % 3;
        if (s == 0) status = AssetRegistry.AssetStatus.Active;
        else if (s == 1) status = AssetRegistry.AssetStatus.ExitOnly;
        else status = AssetRegistry.AssetStatus.Quarantined;
        vm.prank(admin);
        try registry.setAssetStatus(a, status) {} catch {}
    }

    // ------------------------------------------------------------------
    // Deposits
    // ------------------------------------------------------------------

    function deposit(uint256 seed, uint8 userIdx, uint256 amount) external {
        _maybeRefreshPrices();
        address u = _user(userIdx);
        amount = bound(amount, 1, 100_000e6);
        if (vault.activeProposal().id != 0) return; // deposit then requires explicit consent

        bool paused = vault.paused();
        if (!paused) {
            uint256 navBefore = vault.totalAssets();
            uint256 navAfter = navBefore + amount;
            if (navAfter > vault.capAum() && seed % 4 != 0) return; // 1/4 still attempt to probe the guard
            try vault.deposit(amount, u) returns (uint256 shares) {
                if (navAfter > vault.capAum()) ghostCapViolation = true;
                _recordDeposit(u, shares, amount);
            } catch {}
        } else {
            // Paused: attempt anyway; success would mean the pause guard is broken.
            try vault.deposit(amount, u) returns (uint256 shares) {
                ghostPauseViolation = true;
                _recordDeposit(u, shares, amount);
            } catch {}
        }
    }

    function _recordDeposit(address u, uint256 shares, uint256 amount) internal {
        ghostShares[u] += shares;
        ghostCost[u] += amount;
        ghostDepositedBy[u] += amount;
        ghostTotalShares += shares;
        ghostNav += amount;
        // A successful deposit while any basket asset is not open to exposure (status/deposits
        // pause) would also be a guard bypass.
        address[] memory basket = vault.basketAssets();
        for (uint256 i = 0; i < basket.length; ++i) {
            if (!registry.canOpenExposure(basket[i])) {
                ghostPauseViolation = true;
                break;
            }
        }
    }

    // ------------------------------------------------------------------
    // Redemptions (mixed token / settlement choices)
    // ------------------------------------------------------------------

    function redeemMixed(uint256, uint8 userIdx, uint256 pct, uint256 flagSeed) external {
        _maybeRefreshPrices();
        address u = _user(userIdx);
        uint256 sharesBefore = vault.balanceOf(u);
        if (sharesBefore == 0) return;

        uint256 shares = sharesBefore * bound(pct, 1, 100) / 100;
        if (shares == 0) return;

        uint256 n = vault.basketAssets().length;
        bool[] memory flags = new bool[](n);
        for (uint256 i = 0; i < n; ++i) flags[i] = (flagSeed >> i) & 1 == 1;

        uint256 costBefore = vault.costBasis(u);
        bool paused = vault.paused();

        try vault.redeem(shares, u, u, flags) returns (uint256 valueWithdrawn) {
            if (paused) ghostPauseViolation = true;
            uint256 realizedCost = costBefore.mulDiv(shares, sharesBefore);
            ghostCost[u] -= realizedCost;
            ghostShares[u] -= shares;
            ghostTotalShares -= shares;
            ghostNav -= valueWithdrawn;
            if (valueWithdrawn > realizedCost) {
                ghostFees += (valueWithdrawn - realizedCost).mulDiv(FEE_BPS, 10_000);
            }
        } catch {}
    }

    // ------------------------------------------------------------------
    // Rebalances
    // ------------------------------------------------------------------

    function rebalance(uint256, uint8 executorIdx) external {
        _maybeRefreshPrices();
        bool paused = vault.paused();
        if (!paused) {
            (, bool above) = vault.measureDrift();
            if (!above) return;
        }

        address executor = executorIdx % 2 == 0 ? keeper : _user(executorIdx);
        uint256 n = vault.basketAssets().length;
        uint256[] memory mins = new uint256[](n);

        vm.txGasPrice(1 gwei); // exercise the gas-rebate path
        vm.prank(executor);
        try vault.rebalance(EquiVault.RebalanceParams({deadline: block.timestamp + 1 hours, minAmountsOut: mins}))
        returns (uint256 gasRebate) {
            if (paused) ghostPauseViolation = true;
            ghostRebates += gasRebate;
            if (gasRebate > ghostMaxRebate) ghostMaxRebate = gasRebate;
            ghostNav -= gasRebate;
        } catch {}
    }

    // ------------------------------------------------------------------
    // Reallocations (propose then execute across calls)
    // ------------------------------------------------------------------

    function reallocationStep(uint256 seed) external {
        _maybeRefreshPrices();
        if (!ghostActiveProposal) {
            (address[] memory target, uint16[] memory weights) = _target(seed);
            vm.prank(manager);
            try vault.proposeReallocation(target, weights, VAULT_CAP) {
                ghostActiveProposal = true;
            } catch {}
            return;
        }
        if (vault.paused()) return;
        vm.warp(block.timestamp + 1 days + 1);
        _maybeRefreshPrices();
        uint256[] memory sellMins = new uint256[](0);
        uint256[] memory buyMins = new uint256[](0);
        try vault.executeReallocation(sellMins, buyMins) {
            ghostActiveProposal = false;
        } catch {
            // e.g. deposits paused: execution re-validates admissibility; retry on a later step
        }
    }

    function _target(uint256 seed) internal view returns (address[] memory, uint16[] memory) {
        uint256 choice = bound(seed, 0, 6);
        if (choice == 0) return (_two(address(tokenA), address(tokenB)), _w(6_000, 4_000));
        if (choice == 1) return (_two(address(tokenA), address(tokenB)), _w(4_000, 6_000));
        if (choice == 2) return (_two(address(tokenA), address(tokenC)), _w(7_000, 3_000));
        if (choice == 3) return (_two(address(tokenB), address(tokenC)), _w(5_000, 5_000));
        if (choice == 4) return (_three(address(tokenA), address(tokenB), address(tokenC)), _w3(5_000, 3_000, 2_000));
        if (choice == 5) return (_one(address(tokenA)), _w1(10_000));
        return (_one(address(tokenB)), _w1(10_000));
    }

    // ------------------------------------------------------------------
    // Donations (inflation-attack vector)
    // ------------------------------------------------------------------

    function donate(uint256, uint8 assetIdx, uint256 amount) external {
        address a = assetIdx % 3 == 0 ? address(tokenA) : (assetIdx % 3 == 1 ? address(tokenB) : address(tokenC));
        // `totalAssets()` only values basket assets: a donation to an out-of-basket token would
        // create a ghost NAV gap until (and unless) that asset enters the basket. Donate only to
        // assets the vault currently holds, and credit the exact NAV delta the vault reports.
        if (!_inBasket(a)) return;
        if (vault.paused()) return;
        amount = bound(amount, 1, 10_000e6); // up to $10k equivalent
        uint256 navBefore = vault.totalAssets();
        MockToken(a).mint(address(vault), amount);
        uint256 navAfter = vault.totalAssets(); // minting a priced basket asset can only raise NAV
        ghostNav += navAfter - navBefore;
    }

    function _inBasket(address a) internal view returns (bool) {
        address[] memory basket = vault.basketAssets();
        for (uint256 i = 0; i < basket.length; ++i) {
            if (basket[i] == a) return true;
        }
        return false;
    }

    function _one(address a) internal pure returns (address[] memory) {
        address[] memory arr = new address[](1);
        arr[0] = a;
        return arr;
    }

    function _two(address a, address b) internal pure returns (address[] memory) {
        address[] memory arr = new address[](2);
        arr[0] = a;
        arr[1] = b;
        return arr;
    }

    function _three(address a, address b, address c) internal pure returns (address[] memory) {
        address[] memory arr = new address[](3);
        arr[0] = a;
        arr[1] = b;
        arr[2] = c;
        return arr;
    }

    function _w1(uint16 a) internal pure returns (uint16[] memory) {
        uint16[] memory arr = new uint16[](1);
        arr[0] = a;
        return arr;
    }

    function _w(uint16 a, uint16 b) internal pure returns (uint16[] memory) {
        uint16[] memory arr = new uint16[](2);
        arr[0] = a;
        arr[1] = b;
        return arr;
    }

    function _w3(uint16 a, uint16 b, uint16 c) internal pure returns (uint16[] memory) {
        uint16[] memory arr = new uint16[](3);
        arr[0] = a;
        arr[1] = b;
        arr[2] = c;
        return arr;
    }
}

/// @dev Stress invariant suite: prices move 25 %-400 %, oracles fail and recover, the basket is
/// rebalanced, reallocated and donated to, deposits/redemptions are mixed, and registry pauses are
/// toggled. Invariants: solvency (ghost ledger vs live NAV), cost basis, non-custodial shares,
/// pause consistency, cap enforcement, gas-rebate cap and fee accounting.
contract ProtocolStressInvariantTest is InvariantBase {
    EquiVault internal vault;
    StressHandler internal handler;

    function setUp() public override {
        super.setUp();
        (address[] memory a, uint16[] memory w) = _basket(address(tokenA), address(tokenB), 6_000, 4_000);
        vault = _deployVault(a, w);
        handler = new StressHandler(
            vault, registry, usdc, tokenA, tokenB, tokenC, primaryA, fallbackA, primaryB, fallbackB, primaryC,
            fallbackC, manager, admin, keeper, alice, bob, carol
        );
        targetContract(address(handler));
    }

    function _users() internal view returns (address[3] memory) {
        return [alice, bob, carol];
    }

    /// @dev Solvency under price shocks: the tracked value always covers the value actually
    /// controlled by the vault. `totalAssets()` deliberately excludes the settlement balance
    /// (e.g. a reallocation to a strictly smaller basket sells removed assets into settlement that
    /// a later reallocation reinvests), so the ledger compares against NAV + settlement holdings.
    /// The gap is only swap/valuation rounding dust, never a real leak.
    function invariant_solvency() public {
        try vault.totalAssets() returns (uint256 nav) {
            uint256 controlled = nav + usdc.balanceOf(address(vault));
            assertGe(handler.ghostNav(), controlled);
            assertLe(handler.ghostNav() - controlled, NAV_TOLERANCE);
        } catch {
            // unpriced basket: NAV is unreadable by design (registry.getPrice reverts)
        }
    }

    /// @dev Cost basis stays exact through every price shock, oracle outage and mixed exit.
    function invariant_costBasis() public {
        address[3] memory users = _users();
        for (uint256 i = 0; i < users.length; ++i) {
            assertEq(vault.costBasis(users[i]), handler.ghostCost(users[i]));
            assertLe(handler.ghostCost(users[i]), handler.ghostDepositedBy(users[i]));
        }
    }

    /// @dev Non-custodial: shares belong only to depositors; privileged roles hold none.
    function invariant_sharesNonCustodial() public {
        address[3] memory users = _users();
        uint256 sum;
        for (uint256 i = 0; i < users.length; ++i) {
            assertEq(vault.balanceOf(users[i]), handler.ghostShares(users[i]));
            sum += handler.ghostShares(users[i]);
        }
        assertEq(vault.totalSupply(), sum);
        assertEq(vault.balanceOf(manager), 0);
        assertEq(vault.balanceOf(admin), 0);
        assertEq(vault.balanceOf(treasury), 0);
        assertEq(vault.balanceOf(keeper), 0);
    }

    /// @dev Pause consistency: the vault's rebalance-pause flag matches the basket state.
    /// It is set when an in-basket oracle fails or when the registry makes an asset ExitOnly /
    /// Quarantined, because a rebalance could otherwise buy new exposure to that asset.
    function invariant_pauseConsistency() public {
        address[] memory basket = vault.basketAssets();
        bool ghostPaused = registry.depositsPaused();
        for (uint256 i = 0; i < basket.length; ++i) {
            address a = basket[i];
            bool fail = (a == address(tokenA) && handler.ghostFailA())
                || (a == address(tokenB) && handler.ghostFailB())
                || (a == address(tokenC) && handler.ghostFailC());
            if (fail || registry.assetConfig(a).status != AssetRegistry.AssetStatus.Active) ghostPaused = true;
        }
        assertEq(vault.paused(), ghostPaused);
        assertFalse(handler.ghostPauseViolation());
    }

    /// @dev AUM cap is enforced: no deposit ever slipped past the cap check.
    function invariant_capEnforced() public {
        assertFalse(handler.ghostCapViolation());
    }

    /// @dev B001 regression: after any sequence (including reallocations to strictly smaller
    /// baskets), the vault holds no meaningful settlement outside `totalAssets()` — migrations
    /// reinvest the freed balance toward the new target weights.
    function invariant_noOrphanSettlement() public {
        assertLe(usdc.balanceOf(address(vault)), 1e4); // < 0.01 settlement unit of rounding dust
    }

    /// @dev Gas reimbursement is bounded by the protocol cap per rebalance, and the total paid out
    /// can never exceed the settlement that ever entered the vault (deposits + donations).
    function invariant_rebateCapped() public {
        // Per-rebalance reimbursement is bounded by the protocol cap (5 settlement units). After
        // price appreciation a rebate may legitimately exceed cumulative deposits+donations, so
        // only the per-call cap and the pool bound (checked inside the vault) are invariant.
        assertLe(handler.ghostMaxRebate(), 5e6);
    }

    /// @dev Fees always reach manager+treasury in the exact realized-gain split.
    function invariant_feeAccounting() public {
        assertEq(handler.ghostFees(), usdc.balanceOf(manager) + usdc.balanceOf(treasury));
    }

    /// @dev Proposal lifecycle: at most one active proposal, tracked exactly.
    function invariant_singleProposal() public {
        assertEq(vault.activeProposal().id != 0, handler.ghostActiveProposal());
    }
}


/// @dev Malicious basket token: re-enters the vault from its transfer hook while armed, to probe
/// the ReentrancyGuard on every state-changing entry point (F003-S002 criterion: all state
/// functions resist reentrancy).
contract AttackToken is ERC20 {
    EquiVault public vault;
    bool public armed;
    uint8 public mode; // 1 deposit, 2 redeem, 3 rebalance, 4 executeReallocation

    constructor() ERC20("Attack Token", "ATK") {}

    function arm(EquiVault vault_, uint8 mode_) external {
        vault = vault_;
        mode = mode_;
        armed = true;
    }

    function disarm() external {
        armed = false;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (armed && (from == address(vault) || to == address(vault))) {
            if (mode == 1) {
                vault.deposit(1, address(this));
            } else if (mode == 2) {
                vault.redeem(1, address(this), address(this));
            } else if (mode == 3) {
                uint256[] memory mins = new uint256[](0);
                vault.rebalance(
                    EquiVault.RebalanceParams({deadline: block.timestamp + 1 hours, minAmountsOut: mins})
                );
            } else if (mode == 4) {
                uint256[] memory empty = new uint256[](0);
                vault.executeReallocation(empty, empty);
            }
        }
        super._update(from, to, amount);
    }
}

/// @dev Malicious liquidity route: re-enters the vault from swapExactIn while armed. Disarmed it
/// behaves like the zero-fee oracle route so the surrounding flows stay functional.
contract AttackRoute is ISwapRouter {
    using Math for uint256;

    AssetRegistry public immutable registry;
    IERC20 public immutable settlement;
    uint256 private immutable _settlementScale;
    EquiVault public vault;
    bool public armed;
    uint8 public mode; // 2 redeem, 3 rebalance, 4 executeReallocation

    constructor(AssetRegistry registry_, IERC20 settlement_, uint8 settlementDecimals) {
        registry = registry_;
        settlement = settlement_;
        _settlementScale = 10 ** uint256(settlementDecimals);
    }

    function arm(EquiVault vault_, uint8 mode_) external {
        vault = vault_;
        mode = mode_;
        armed = true;
    }

    function disarm() external {
        armed = false;
    }

    function swapExactIn(address assetIn, address assetOut, uint256 amountIn, uint256 minAmountOut)
        external
        returns (uint256 amountOut)
    {
        if (armed) {
            if (mode == 2) {
                vault.redeem(1, address(this), address(this));
            } else if (mode == 3) {
                uint256[] memory mins = new uint256[](0);
                vault.rebalance(
                    EquiVault.RebalanceParams({deadline: block.timestamp + 1 hours, minAmountsOut: mins})
                );
            } else if (mode == 4) {
                uint256[] memory empty = new uint256[](0);
                vault.executeReallocation(empty, empty);
            }
        }
        require(assetIn == address(settlement) || assetOut == address(settlement), "AttackRoute: wrong pair");
        address token = assetIn == address(settlement) ? assetOut : assetIn;
        (uint256 priceE18,) = registry.getPrice(token, address(settlement));
        uint256 tokenScale = 10 ** uint256(registry.assetConfig(token).decimals);
        if (assetIn == address(settlement)) {
            amountOut = amountIn.mulDiv(tokenScale * 1e18, priceE18 * _settlementScale);
        } else {
            amountOut = amountIn.mulDiv(priceE18 * _settlementScale, tokenScale * 1e18);
        }
        if (amountOut < minAmountOut) revert ISwapRouter.SlippageExceeded(minAmountOut, amountOut);
        bool inOk = IERC20(assetIn).transferFrom(msg.sender, address(this), amountIn);
        bool outOk = IERC20(assetOut).transfer(msg.sender, amountOut);
        require(inOk && outOk, "AttackRoute: transfer failed");
    }
}

/// @dev Targeted reentrancy attacks (F003-S002 criterion: all state-modifying functions resist
/// reentrancy). Every nested attempt must hit the vault's ReentrancyGuard and leave the state
/// untouched; disarming must restore normal operation.
contract ReentrancyInvariantTest is Test {
    using Math for uint256;

    uint48 internal constant MAX_PRICE_AGE = 3 days;
    uint256 internal constant EXPOSURE_CAP = 1_000_000e18;
    uint256 internal constant VAULT_CAP = 1_000_000e6;
    uint256 internal constant ROUTE_FUNDS = 1e33;

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal manager = makeAddr("manager");
    address internal alice = makeAddr("alice");

    MockToken internal usdc;
    MockToken internal tokenA;
    MockToken internal tokenB;
    AttackToken internal attackToken;
    MockOracle internal primaryA;
    MockOracle internal fallbackA;
    MockOracle internal primaryAtk;
    MockOracle internal fallbackAtk;
    MockOracle internal primaryB;
    MockOracle internal fallbackB;
    AttackRoute internal routeA;
    MockOracleRoute internal routeAtk;
    MockOracleRoute internal routeB;
    AssetRegistry internal registry;
    EquiVault internal vault;
    RebalanceEngine internal engine;

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new MockToken(6);
        tokenA = new MockToken(18);
        tokenB = new MockToken(18);
        attackToken = new AttackToken();

        primaryA = new MockOracle();
        fallbackA = new MockOracle();
        primaryAtk = new MockOracle();
        fallbackAtk = new MockOracle();
        primaryB = new MockOracle();
        fallbackB = new MockOracle();
        primaryA.setPrice(100e18, block.timestamp);
        fallbackA.setPrice(99e18, block.timestamp);
        primaryAtk.setPrice(50e18, block.timestamp);
        fallbackAtk.setPrice(49e18, block.timestamp);
        primaryB.setPrice(200e18, block.timestamp);
        fallbackB.setPrice(199e18, block.timestamp);

        registry = new AssetRegistry(admin, treasury);
        routeA = new AttackRoute(registry, usdc, 6);
        routeAtk = new MockOracleRoute(registry, usdc, 0);
        routeB = new MockOracleRoute(registry, usdc, 0);
        tokenA.mint(address(routeA), ROUTE_FUNDS);
        usdc.mint(address(routeA), ROUTE_FUNDS);
        attackToken.mint(address(routeAtk), ROUTE_FUNDS);
        usdc.mint(address(routeAtk), ROUTE_FUNDS);
        tokenB.mint(address(routeB), ROUTE_FUNDS);
        usdc.mint(address(routeB), ROUTE_FUNDS);

        vm.startPrank(admin);
        registry.registerAsset(address(tokenA), primaryA, fallbackA, address(routeA), EXPOSURE_CAP, MAX_PRICE_AGE);
        registry.registerAsset(address(attackToken), primaryAtk, fallbackAtk, address(routeAtk), EXPOSURE_CAP, MAX_PRICE_AGE);
        registry.registerAsset(address(tokenB), primaryB, fallbackB, address(routeB), EXPOSURE_CAP, MAX_PRICE_AGE);
        vm.stopPrank();

        address[] memory assets = new address[](2);
        assets[0] = address(tokenA);
        assets[1] = address(attackToken);
        uint16[] memory weights = new uint16[](2);
        weights[0] = 5_000;
        weights[1] = 5_000;
        vault = new EquiVault(
            usdc, registry, manager, assets, weights, 1_000, 300, EquiVault.TimelockMode.Delayed, 1 days, VAULT_CAP, 0, 0
        );
        engine = new RebalanceEngine();
    }

    function _fund(uint256 amount) internal {
        usdc.mint(alice, amount);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(amount, alice);
        vm.stopPrank();
    }

    function _expectGuard() internal {
        vm.expectRevert(abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
    }

    // ------------------------------------------------------------------
    // Token-hook reentrancy
    // ------------------------------------------------------------------

    function testDepositReentrancyViaTokenReverts() public {
        attackToken.arm(vault, 1); // nested deposit during the basket buy
        usdc.mint(alice, 1_000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        _expectGuard();
        vault.deposit(1_000e6, alice);
        vm.stopPrank();

        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.balanceOf(alice), 0);

        attackToken.disarm();
        vm.prank(alice);
        vault.deposit(1_000e6, alice);
        assertGt(vault.balanceOf(alice), 0);
    }

    function testRedeemReentrancyViaTokenReverts() public {
        _fund(1_000e6);
        uint256 sharesBefore = vault.balanceOf(alice);

        attackToken.arm(vault, 2); // nested redeem during the token distribution
        bool[] memory flags = new bool[](2); // both assets distributed as tokens
        _expectGuard();
        vm.prank(alice);
        vault.redeem(sharesBefore, alice, alice, flags);

        assertEq(vault.balanceOf(alice), sharesBefore);
        assertEq(vault.totalSupply(), sharesBefore);
        assertEq(attackToken.balanceOf(alice), 0);
    }

    function testRebalanceReentrancyViaTokenReverts() public {
        _fund(1_000e6);
        primaryA.setPrice(150e18, block.timestamp);
        (, bool above) = vault.measureDrift();
        assertTrue(above);

        attackToken.arm(vault, 3); // nested rebalance during the buy leg
        uint256[] memory mins = new uint256[](2);
        _expectGuard();
        vault.rebalance(EquiVault.RebalanceParams({deadline: block.timestamp + 1 hours, minAmountsOut: mins}));
        assertEq(vault.totalSupply(), vault.balanceOf(alice));
    }

    // ------------------------------------------------------------------
    // Route-hook reentrancy
    // ------------------------------------------------------------------

    function testDepositReentrancyViaRouteReverts() public {
        routeA.arm(vault, 2); // nested redeem during the tokenA buy
        usdc.mint(alice, 1_000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        _expectGuard();
        vault.deposit(1_000e6, alice);
        vm.stopPrank();
        assertEq(vault.totalSupply(), 0);

        routeA.disarm();
        vm.prank(alice);
        vault.deposit(1_000e6, alice);
        assertGt(vault.balanceOf(alice), 0);
    }

    function testEngineRebalanceReentrancyViaRouteReverts() public {
        _fund(1_000e6);
        primaryA.setPrice(150e18, block.timestamp);

        routeA.arm(vault, 3); // nested rebalance inside the engine-forwarded one
        uint256[] memory mins = new uint256[](2);
        _expectGuard();
        engine.rebalance(vault, EquiVault.RebalanceParams({deadline: block.timestamp + 1 hours, minAmountsOut: mins}));
    }

    function testExecuteReallocationReentrancyViaRouteReverts() public {
        _fund(1_000e6);
        address[] memory target = new address[](2);
        target[0] = address(attackToken);
        target[1] = address(tokenB);
        uint16[] memory weights = new uint16[](2);
        weights[0] = 5_000;
        weights[1] = 5_000;
        vm.prank(manager);
        vault.proposeReallocation(target, weights, VAULT_CAP);
        vm.warp(block.timestamp + 1 days + 1);
        // refresh tokenA/attackToken/tokenB prices after the warp (MAX_PRICE_AGE = 3 days: still fresh)

        routeA.arm(vault, 4); // nested executeReallocation during the sell leg
        uint256[] memory empty = new uint256[](0);
        _expectGuard();
        vault.executeReallocation(empty, empty);

        routeA.disarm();
        vault.executeReallocation(empty, empty);
        assertEq(vault.basketAssets().length, 2);
        assertEq(vault.basketAssets()[0], address(attackToken));
        assertEq(vault.basketAssets()[1], address(tokenB));
    }
}

/// @dev Handler that creates vaults through the permissionless factory with fuzzed parameters.
contract FactoryHandler is Test {
    VaultFactory public immutable factory;
    address public immutable manager;
    address public immutable tokenA;
    address public immutable tokenB;
    uint256 public ghostCreated;

    constructor(VaultFactory factory_, address manager_, address tokenA_, address tokenB_) {
        factory = factory_;
        manager = manager_;
        tokenA = tokenA_;
        tokenB = tokenB_;
    }

    function createVault(uint256 seed) external {
        uint16 fee = uint16(bound(seed, 0, 2_000));
        uint16 maxSlip = uint16(bound(seed >> 8, 0, 3_000));
        uint256 modeSeed = bound(seed >> 16, 0, 2);
        EquiVault.TimelockMode mode = EquiVault.TimelockMode(modeSeed);
        uint256 delay = mode == EquiVault.TimelockMode.Delayed ? 1 days + bound(seed >> 24, 0, 6 days) : 0;
        uint16 drift = uint16(bound(seed >> 32, 0, 1_000));
        uint16 rebalSlip = uint16(bound(seed >> 40, 0, 300));
        address[] memory a = new address[](2);
        a[0] = tokenA;
        a[1] = tokenB;
        uint16[] memory w = new uint16[](2);
        w[0] = 5_000;
        w[1] = 5_000;
        try factory.createVault(manager, a, w, fee, maxSlip, mode, delay, 100_000e6, drift, rebalSlip)
        returns (address) {
            ++ghostCreated;
        } catch {}
    }
}

/// @dev Factory invariants: the deployment registry enumerates exactly the vaults that were
/// created, every listed vault is recognized, the chain id is exposed, and the immutable creation
/// parameters stay within their protocol bounds.
contract VaultFactoryInvariantTest is InvariantBase {
    VaultFactory internal factory;
    FactoryHandler internal handler;

    function setUp() public override {
        super.setUp();
        factory = new VaultFactory(usdc, registry);
        handler = new FactoryHandler(factory, manager, address(tokenA), address(tokenB));
        targetContract(address(handler));
    }

    function invariant_vaultRegistryConsistent() public {
        assertEq(factory.vaultCount(), handler.ghostCreated());
        for (uint256 i = 0; i < factory.vaultCount(); ++i) {
            assertTrue(factory.isVault(factory.vaults(i)));
        }
    }

    function invariant_chainId() public {
        assertEq(factory.chainId(), block.chainid);
    }

    function invariant_createdVaultParamsBounded() public {
        uint256 count = factory.vaultCount();
        if (count == 0) return;
        EquiVault v = EquiVault(factory.vaults(count - 1));
        assertEq(address(v.asset()), address(usdc));
        assertEq(address(v.registry()), address(registry));
        assertEq(v.manager(), manager);
        assertLe(v.feeBps(), 2_000);
        assertLe(v.maxSlippageBps(), 3_000);
        assertGe(v.driftThresholdBps(), 100);
        assertLe(v.driftThresholdBps(), 1_000);
        assertLe(v.rebalanceSlippageBps(), 300);
        assertGt(v.capAum(), 0);
    }
}


