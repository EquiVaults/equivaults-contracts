// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {AssetRegistry} from "../src/AssetRegistry.sol";
import {EquiVault} from "../src/EquiVault.sol";
import {ISwapRouter} from "../src/interfaces/ISwapRouter.sol";

import {MockOracle, MockPool, MockToken} from "./mocks/Mocks.sol";

contract EquiVaultTest is Test {
    uint48 internal constant MAX_PRICE_AGE = 1 hours;
    uint256 internal constant PRICE_A = 100e18; // $100 per whole token
    uint256 internal constant PRICE_B = 50e18; // $50 per whole token
    uint256 internal constant SHARE_SCALE = 1e6; // _decimalsOffset() = 6

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal manager = makeAddr("manager");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

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
    EquiVault internal vault;

    struct ExitSim {
        uint256 valueWithdrawn;
        uint256 usdcToUser;
        uint256 tokenAOut;
        uint256 tokenBOut;
        uint256 feePot;
        uint256 managerShare;
        uint256 treasuryShare;
    }

    struct ExitFacts {
        uint256 amountA;
        uint256 amountB;
        uint256 valueWithdrawn;
        uint256 fee;
    }

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
        // Pool spot prices match the oracle: A = $100 (18 decimals), B = $50 (6 decimals),
        // with ~$10M of liquidity on each side.
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
        registry.registerAsset(address(tokenA), primaryA, fallbackA, address(poolA), 1_000_000e18, MAX_PRICE_AGE);
        registry.registerAsset(address(tokenB), primaryB, fallbackB, address(poolB), 1_000_000e18, MAX_PRICE_AGE);
        vm.stopPrank();

        vault = new EquiVault(usdc, registry, manager, assets(), weights(), 1_000, 100, EquiVault.TimelockMode.Delayed, 1 days, 1_000_000e6);
    }

    // ------------------------------------------------------------------
    // Construction
    // ------------------------------------------------------------------

    function testConstructorRejectsInvalidParameters() public {
        address[] memory a = assets();
        uint16[] memory w = weights();

        vm.expectRevert(abi.encodeWithSelector(EquiVault.InvalidFee.selector, uint16(2_001)));
        new EquiVault(usdc, registry, manager, a, w, 2_001, 100, EquiVault.TimelockMode.Delayed, 1 days, 1_000_000e6);

        vm.expectRevert(abi.encodeWithSelector(EquiVault.InvalidSlippage.selector, uint16(3_001)));
        new EquiVault(usdc, registry, manager, a, w, 1_000, 3_001, EquiVault.TimelockMode.Delayed, 1 days, 1_000_000e6);

        vm.expectRevert(abi.encodeWithSelector(EquiVault.InvalidAddress.selector));
        new EquiVault(usdc, registry, address(0), a, w, 1_000, 100, EquiVault.TimelockMode.Delayed, 1 days, 1_000_000e6);

        vm.expectRevert(abi.encodeWithSelector(EquiVault.InvalidBasketSize.selector, uint256(0)));
        new EquiVault(usdc, registry, manager, new address[](0), new uint16[](0), 1_000, 100, EquiVault.TimelockMode.Delayed, 1 days, 1_000_000e6);

        address[] memory six = new address[](6);
        uint16[] memory sixW = new uint16[](6);
        for (uint256 i = 0; i < 6; ++i) {
            six[i] = address(uint160(i + 1));
            sixW[i] = uint16(1_000 + i * 1_000);
        }
        vm.expectRevert(abi.encodeWithSelector(EquiVault.InvalidBasketSize.selector, uint256(6)));
        new EquiVault(usdc, registry, manager, six, sixW, 1_000, 100, EquiVault.TimelockMode.Delayed, 1 days, 1_000_000e6);

        address[] memory one = new address[](1);
        one[0] = address(tokenA);
        vm.expectRevert(abi.encodeWithSelector(EquiVault.BasketLengthMismatch.selector, uint256(1), uint256(0)));
        new EquiVault(usdc, registry, manager, one, new uint16[](0), 1_000, 100, EquiVault.TimelockMode.Delayed, 1 days, 1_000_000e6);

        // weight below the 5 % floor
        address[] memory two = new address[](2);
        two[0] = address(tokenA);
        two[1] = address(tokenB);
        uint16[] memory lowW = new uint16[](2);
        lowW[0] = 100;
        lowW[1] = 9_900;
        vm.expectRevert(abi.encodeWithSelector(EquiVault.InvalidWeight.selector, uint16(100)));
        new EquiVault(usdc, registry, manager, two, lowW, 1_000, 100, EquiVault.TimelockMode.Delayed, 1 days, 1_000_000e6);

        // weights not summing to 100 %
        uint16[] memory partialW = new uint16[](1);
        partialW[0] = 5_000;
        vm.expectRevert(abi.encodeWithSelector(EquiVault.WeightsMustSumTo10000.selector, uint256(5_000)));
        new EquiVault(usdc, registry, manager, one, partialW, 1_000, 100, EquiVault.TimelockMode.Delayed, 1 days, 1_000_000e6);

        // duplicate asset
        address[] memory dupAssets = new address[](2);
        dupAssets[0] = address(tokenA);
        dupAssets[1] = address(tokenA);
        uint16[] memory dupW = new uint16[](2);
        dupW[0] = 5_000;
        dupW[1] = 5_000;
        vm.expectRevert(abi.encodeWithSelector(EquiVault.DuplicateAsset.selector, address(tokenA)));
        new EquiVault(usdc, registry, manager, dupAssets, dupW, 1_000, 100, EquiVault.TimelockMode.Delayed, 1 days, 1_000_000e6);

        // settlement asset in basket
        address[] memory withUsdc = new address[](2);
        withUsdc[0] = address(usdc);
        withUsdc[1] = address(tokenA);
        vm.expectRevert(abi.encodeWithSelector(EquiVault.SettlementAssetInBasket.selector, address(usdc)));
        new EquiVault(usdc, registry, manager, withUsdc, dupW, 1_000, 100, EquiVault.TimelockMode.Delayed, 1 days, 1_000_000e6);

        // unregistered asset
        address[] memory unknown = new address[](1);
        unknown[0] = address(0xBEEF);
        uint16[] memory fullW = new uint16[](1);
        fullW[0] = 10_000;
        vm.expectRevert(abi.encodeWithSelector(EquiVault.AssetNotRegistered.selector, address(0xBEEF)));
        new EquiVault(usdc, registry, manager, unknown, fullW, 1_000, 100, EquiVault.TimelockMode.Delayed, 1 days, 1_000_000e6);
    }

    // ------------------------------------------------------------------
    // Deposits
    // ------------------------------------------------------------------

    function testDepositBuysBasketAndMintsShares() public {
        uint256 depositAmount = 1_000e6;
        _fundAndApprove(alice, depositAmount);

        uint256 allocA = depositAmount * 6_000 / 10_000;
        uint256 allocB = depositAmount * 4_000 / 10_000;
        // Expected token receipts from the seeded pool reserves, before the deposit executes.
        uint256 expectedA = _poolOut(poolA, address(usdc), address(tokenA), allocA);
        uint256 expectedB = _poolOut(poolB, address(usdc), address(tokenB), allocB);

        vm.prank(alice);
        uint256 shares = vault.deposit(depositAmount, alice);

        // Par at genesis: virtual shares/assets cancel, 1 USDC = 1e6 shares.
        assertEq(shares, depositAmount * SHARE_SCALE);
        assertEq(vault.balanceOf(alice), shares);
        assertEq(vault.costBasis(alice), depositAmount);

        assertEq(tokenA.balanceOf(address(vault)), expectedA);
        assertEq(tokenB.balanceOf(address(vault)), expectedB);

        // Only dust USDC stays in the vault; NAV = tokens valued at oracle prices.
        assertLt(usdc.balanceOf(address(vault)), 1e6);
        uint256 expectedNav = _valueUsdc(address(tokenA), expectedA) + _valueUsdc(address(tokenB), expectedB);
        assertEq(vault.totalAssets(), expectedNav);
    }

    function testDepositEnforcesMinimumSwapResults() public {
        _fundAndApprove(alice, 1_000e6);

        uint256 allocA = 1_000e6 * 6_000 / 10_000;
        uint256 expectedOut = _poolOut(poolA, address(usdc), address(tokenA), allocA);
        uint256[] memory impossible = new uint256[](2);
        impossible[0] = type(uint256).max;
        impossible[1] = 0;
        vm.expectRevert(abi.encodeWithSelector(ISwapRouter.SlippageExceeded.selector, type(uint256).max, expectedOut));
        vm.prank(alice);
        vault.deposit(1_000e6, alice, impossible);

        uint256[] memory wrongLength = new uint256[](1);
        wrongLength[0] = 0;
        vm.expectRevert(
            abi.encodeWithSelector(EquiVault.MinOutsLengthMismatch.selector, uint256(2), uint256(1))
        );
        vm.prank(alice);
        vault.deposit(1_000e6, alice, wrongLength);
    }

    function testNoProtocolMinimumTicket() public {
        _fundAndApprove(alice, 1);
        vm.prank(alice);
        uint256 shares = vault.deposit(1, alice);
        assertEq(shares, 1 * SHARE_SCALE);

        vm.prank(alice);
        vault.redeem(shares, alice, alice);
        assertEq(vault.balanceOf(alice), 0);
    }

    function testMintAndWithdrawStandardFlows() public {
        _fundAndApprove(alice, 2_000e6);
        vm.prank(alice);
        uint256 assetsUsed = vault.mint(1_000e6 * SHARE_SCALE, alice);
        assertEq(assetsUsed, 1_000e6);

        uint256 balanceAfterMint = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 burned = vault.withdraw(400e6, alice, alice);
        assertEq(vault.balanceOf(alice), 1_000e6 * SHARE_SCALE - burned);
        assertApproxEqAbs(usdc.balanceOf(alice) - balanceAfterMint, 400e6, 10e6);
    }

    // ------------------------------------------------------------------
    // Exits
    // ------------------------------------------------------------------

    function testProportionalExitDoesNotDistortRemainingHolders() public {
        _fundAndApprove(alice, 1_000e6);
        _fundAndApprove(bob, 1_000e6);
        vm.prank(alice);
        vault.deposit(1_000e6, alice);
        vm.prank(bob);
        vault.deposit(1_000e6, bob);

        uint256 balA = tokenA.balanceOf(address(vault));
        uint256 balB = tokenB.balanceOf(address(vault));
        uint256 total = vault.totalSupply();
        uint256 exitShares = vault.balanceOf(bob) / 2;

        ExitSim memory sim = _simulateExit(bob, exitShares, true, true);

        vm.prank(bob);
        vault.redeem(exitShares, bob, bob);

        // Bob received exactly his proportional slice, net of swap costs (no fee: no realized gain).
        assertEq(usdc.balanceOf(bob), sim.usdcToUser);
        // Remaining balances are exactly the initial ones minus Bob's withdrawn share.
        assertEq(tokenA.balanceOf(address(vault)), balA - balA * exitShares / total);
        assertEq(tokenB.balanceOf(address(vault)), balB - balB * exitShares / total);

        // Remaining holder can still exit fully.
        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(aliceShares, alice, alice);
        assertEq(vault.balanceOf(alice), 0);
    }

    function testMixedExitPerAssetChoice() public {
        _fundAndApprove(alice, 1_000e6);
        vm.prank(alice);
        vault.deposit(1_000e6, alice);

        uint256 balB = tokenB.balanceOf(address(vault));
        uint256 total = vault.totalSupply();
        uint256 shares = vault.balanceOf(alice);
        uint256 amountB = balB * shares / total;

        ExitSim memory sim = _simulateExit(alice, shares, true, false);

        bool[] memory flags = new bool[](2);
        flags[0] = true; // A -> USDC
        flags[1] = false; // B -> token

        vm.prank(alice);
        vault.redeem(shares, alice, alice, flags);

        assertEq(tokenB.balanceOf(alice), amountB); // exact proportional token share
        assertEq(usdc.balanceOf(alice), sim.usdcToUser);
    }

    // ------------------------------------------------------------------
    // Shares and cost basis
    // ------------------------------------------------------------------

    function testSharesAreNonTransferable() public {
        _fundAndApprove(alice, 1_000e6);
        vm.prank(alice);
        vault.deposit(1_000e6, alice);

        bool unused;
        vm.expectRevert(EquiVault.SharesNonTransferable.selector);
        vm.prank(alice);
        unused = vault.transfer(bob, 1);

        vm.expectRevert(EquiVault.SharesNonTransferable.selector);
        vm.prank(alice);
        unused = vault.transferFrom(alice, bob, 1);
        assertFalse(unused); // unreachable: both calls always revert
    }

    function testPartialRedemptionsKeepCostBasisExact() public {
        _fundAndApprove(alice, 1_000e6);
        vm.prank(alice);
        vault.deposit(1_000e6, alice);

        // Exit 40 % at cost: no gain, realized cost removed proportionally.
        uint256 fortyPct = vault.balanceOf(alice) * 40 / 100;
        vm.prank(alice);
        vault.redeem(fortyPct, alice, alice);
        assertEq(vault.costBasis(alice), 600e6);

        // Price of A doubles; exit the remaining 60 %.
        _doublePriceA();
        uint256 remaining = vault.balanceOf(alice);
        ExitSim memory sim = _simulateExit(alice, remaining, true, true);

        vm.prank(alice);
        vault.redeem(remaining, alice, alice);

        assertEq(vault.costBasis(alice), 0);
        assertEq(usdc.balanceOf(manager), sim.managerShare);
        assertEq(usdc.balanceOf(treasury), sim.treasuryShare);
    }

    // ------------------------------------------------------------------
    // Performance fee
    // ------------------------------------------------------------------

    function testPerformanceFeeOnRealizedGain() public {
        _fundAndApprove(alice, 1_000e6);
        vm.prank(alice);
        vault.deposit(1_000e6, alice);

        _doublePriceA();

        uint256 shares = vault.balanceOf(alice);
        ExitSim memory sim = _simulateExit(alice, shares, true, true);

        vm.prank(alice);
        vault.redeem(shares, alice, alice);

        // 90 % to the manager, 10 % to the treasury, exact from the simulated pool proceeds.
        assertEq(usdc.balanceOf(manager), sim.managerShare);
        assertEq(usdc.balanceOf(treasury), sim.treasuryShare);
        assertEq(usdc.balanceOf(manager) + usdc.balanceOf(treasury), sim.feePot);
        assertEq(vault.costBasis(alice), 0);
        // Exit value minus fee minus swap costs all go to the user.
        assertEq(usdc.balanceOf(alice), sim.usdcToUser);
        assertEq(vault.totalSupply(), 0);
    }

    function testFeeCollectedEvenOnTokenExits() public {
        _fundAndApprove(alice, 1_000e6);
        vm.prank(alice);
        vault.deposit(1_000e6, alice);

        _doublePriceA();

        uint256 shares = vault.balanceOf(alice);
        ExitSim memory sim = _simulateExit(alice, shares, false, false);

        bool[] memory flags = new bool[](2); // both false: receive tokens

        vm.prank(alice);
        vault.redeem(shares, alice, alice, flags);

        // Fee still collected in USDC (fee slices sold) on a pure token exit.
        assertGt(sim.feePot, 0);
        assertEq(usdc.balanceOf(manager), sim.managerShare);
        assertEq(usdc.balanceOf(treasury), sim.treasuryShare);
        // User keeps the tokens, minus the fee slices.
        assertEq(tokenA.balanceOf(alice), sim.tokenAOut);
        assertEq(tokenB.balanceOf(alice), sim.tokenBOut);
    }

    function testNoFeeWhenNoRealizedGain() public {
        _fundAndApprove(alice, 1_000e6);
        vm.prank(alice);
        vault.deposit(1_000e6, alice);

        // Exit at cost: entry costs make NAV slightly below principal -> no gain, no fee.
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(shares, alice, alice);

        assertEq(usdc.balanceOf(manager), 0);
        assertEq(usdc.balanceOf(treasury), 0);
    }

    // ------------------------------------------------------------------
    // Pause behavior
    // ------------------------------------------------------------------

    function testDualOracleFailurePausesOnlyAffectedVault() public {
        address[] memory bOnly = new address[](1);
        bOnly[0] = address(tokenB);
        uint16[] memory bW = new uint16[](1);
        bW[0] = 10_000;
        EquiVault vault2 = new EquiVault(usdc, registry, manager, bOnly, bW, 1_000, 100, EquiVault.TimelockMode.Delayed, 1 days, 1_000_000e6);

        _fundAndApprove(alice, 1_000e6);
        _fundAndApprove(bob, 1_000e6);
        vm.prank(bob);
        usdc.approve(address(vault2), 1_000e6);
        vm.prank(alice);
        vault.deposit(1_000e6, alice);
        vm.prank(bob);
        vault2.deposit(1_000e6, bob);

        primaryA.setFails(true);
        fallbackA.setFails(true);

        assertTrue(vault.paused());
        assertFalse(vault2.paused());

        // Deposits and redemptions on the affected vault revert.
        vm.prank(bob);
        vm.expectRevert(EquiVault.VaultPaused.selector);
        vault.deposit(1_000e6, bob);
        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(EquiVault.VaultPaused.selector);
        vault.redeem(aliceShares, alice, alice);

        // The unaffected vault keeps operating.
        uint256 bobShares = vault2.balanceOf(bob);
        vm.prank(bob);
        vault2.redeem(bobShares, bob, bob);
        assertEq(vault2.balanceOf(bob), 0);
    }

    function testExitOnlyBlocksDepositsNotWithdrawals() public {
        _fundAndApprove(alice, 1_000e6);
        vm.prank(alice);
        vault.deposit(1_000e6, alice);

        vm.prank(admin);
        registry.setAssetStatus(address(tokenA), AssetRegistry.AssetStatus.ExitOnly);

        vm.prank(alice);
        vm.expectRevert(EquiVault.VaultPaused.selector);
        vault.deposit(1_000e6, alice);

        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(shares, alice, alice);
        assertEq(vault.balanceOf(alice), 0);
    }

    // ------------------------------------------------------------------
    // Inflation attack mitigation
    // ------------------------------------------------------------------

    function testInflationAttackCannotProfitAndKeepsVaultUsable() public {
        // First depositor: 1 wei, tiny share.
        _fundAndApprove(alice, 1);
        vm.prank(alice);
        vault.deposit(1, alice);

        // Attacker donates a huge amount then deposits and withdraws.
        _fundAndApprove(bob, 2 * 1e11);
        vm.prank(bob);
        bool donationOk = usdc.transfer(address(vault), 1e11); // donation inflates NAV
        assertTrue(donationOk);
        vm.prank(bob);
        uint256 atkShares = vault.deposit(1e11, bob);

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        vault.redeem(atkShares, bob, bob);
        uint256 bobReceived = usdc.balanceOf(bob) - bobBefore;

        // Attacker cannot profit: received less than his own deposit alone, the donation is lost.
        assertLt(bobReceived, 1e11);

        // A later honest depositor keeps ~all of his value (no dilution, vault still usable).
        _fundAndApprove(carol, 1_000e6);
        vm.prank(carol);
        uint256 cShares = vault.deposit(1_000e6, carol);
        uint256 carolBefore = usdc.balanceOf(carol);
        vm.prank(carol);
        vault.redeem(cShares, carol, carol);
        uint256 carolReceived = usdc.balanceOf(carol) - carolBefore;
        assertGe(carolReceived, 1_000e6 * 99 / 100);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function assets() internal view returns (address[] memory a) {
        a = new address[](2);
        a[0] = address(tokenA);
        a[1] = address(tokenB);
    }

    function weights() internal pure returns (uint16[] memory w) {
        w = new uint16[](2);
        w[0] = 6_000;
        w[1] = 4_000;
    }

    function _fundAndApprove(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.prank(who);
        usdc.approve(address(vault), amount);
    }

    /// @dev Constant-product out given explicit reserves and pool fee.
    function _poolOut(uint256 rIn, uint256 rOut, uint16 feeBps, uint256 amountIn) internal pure returns (uint256) {
        uint256 amountInNet = amountIn * (10_000 - feeBps) / 10_000;
        return rOut - (rIn * rOut) / (rIn + amountInNet);
    }

    function _poolOut(MockPool pool, address assetIn, address assetOut, uint256 amountIn)
        internal
        view
        returns (uint256)
    {
        return _poolOut(pool.reserveOf(assetIn), pool.reserveOf(assetOut), pool.swapFeeBps(), amountIn);
    }

    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a + b - 1) / b;
    }

    /// @dev Doubles the oracle price of A and injects USDC into poolA so its spot price matches.
    function _doublePriceA() internal {
        primaryA.setPrice(2 * PRICE_A, block.timestamp);
        uint256 extraUsdc = poolA.reserveOf(address(usdc));
        usdc.mint(address(this), extraUsdc);
        usdc.approve(address(poolA), extraUsdc);
        poolA.seed(extraUsdc, 0);
    }

    /// @dev USDC wei value of `amount` natural units of a basket token (mirrors EquiVault._valueUsdc).
    function _valueUsdc(address token, uint256 amount) internal view returns (uint256) {
        AssetRegistry.AssetConfig memory config = registry.assetConfig(token);
        (uint256 price,) = _oracleOf(token).getPrice(token, address(usdc));
        uint256 baseScale = 10 ** uint256(config.decimals);
        return amount * price * (10 ** 6) / (baseScale * 1e18);
    }

    function _oracleOf(address token) internal view returns (MockOracle) {
        return token == address(tokenA) ? primaryA : primaryB;
    }

    /// @dev Mirrors EquiVault._exit exactly: proportional amounts, fee slices sold first, then the
    /// remainder per sell flag, all with sequentially evolving pool reserves.
    function _simulateExit(address owner, uint256 shares, bool sellA, bool sellB)
        internal
        view
        returns (ExitSim memory s)
    {
        ExitFacts memory f = _exitFacts(owner, shares);
        s.valueWithdrawn = f.valueWithdrawn;

        uint16 feeBps = poolA.swapFeeBps();
        uint256 rAIn = poolA.reserveOf(address(tokenA));
        uint256 rAOut = poolA.reserveOf(address(usdc));
        uint256 rBIn = poolB.reserveOf(address(tokenB));
        uint256 rBOut = poolB.reserveOf(address(usdc));

        uint256 feeSliceA = f.fee == 0 ? 0 : (f.amountA * f.fee + f.valueWithdrawn - 1) / f.valueWithdrawn;
        if (feeSliceA > f.amountA) feeSliceA = f.amountA;
        if (feeSliceA > 0) {
            uint256 p = _poolOut(rAIn, rAOut, feeBps, feeSliceA);
            s.feePot += p;
            rAIn += feeSliceA;
            rAOut -= p;
        }
        if (sellA) {
            uint256 sell = f.amountA - feeSliceA;
            if (sell > 0) {
                uint256 p = _poolOut(rAIn, rAOut, feeBps, sell);
                s.usdcToUser += p;
            }
        } else {
            s.tokenAOut = f.amountA - feeSliceA;
        }

        uint256 feeSliceB = f.fee == 0 ? 0 : (f.amountB * f.fee + f.valueWithdrawn - 1) / f.valueWithdrawn;
        if (feeSliceB > f.amountB) feeSliceB = f.amountB;
        if (feeSliceB > 0) {
            uint256 p = _poolOut(rBIn, rBOut, feeBps, feeSliceB);
            s.feePot += p;
            rBIn += feeSliceB;
            rBOut -= p;
        }
        if (sellB) {
            uint256 sell = f.amountB - feeSliceB;
            if (sell > 0) {
                uint256 p = _poolOut(rBIn, rBOut, feeBps, sell);
                s.usdcToUser += p;
            }
        } else {
            s.tokenBOut = f.amountB - feeSliceB;
        }

        s.managerShare = s.feePot * 9_000 / 10_000;
        s.treasuryShare = s.feePot - s.managerShare;
    }

    /// @dev Proportional amounts, USDC value, and performance fee of an exit, from current state.
    function _exitFacts(address owner, uint256 shares) internal view returns (ExitFacts memory f) {
        uint256 sharesBefore = vault.balanceOf(owner);
        uint256 total = vault.totalSupply();
        f.amountA = tokenA.balanceOf(address(vault)) * shares / total;
        f.amountB = tokenB.balanceOf(address(vault)) * shares / total;
        f.valueWithdrawn = _valueUsdc(address(tokenA), f.amountA) + _valueUsdc(address(tokenB), f.amountB);
        uint256 realizedCost = vault.costBasis(owner) * shares / sharesBefore;
        if (f.valueWithdrawn > realizedCost) {
            f.fee = (f.valueWithdrawn - realizedCost) * vault.feeBps() / 10_000;
        }
    }
}
