// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {AssetRegistry} from "../src/AssetRegistry.sol";
import {EquiVault} from "../src/EquiVault.sol";
import {InvestmentEscrow} from "../src/InvestmentEscrow.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {ISwapRouter} from "../src/interfaces/ISwapRouter.sol";
import {MockOracle, MockOracleRoute, MockToken} from "./mocks/Mocks.sol";

/// @dev Ignores minAmountOut so escrow's receiver-delta check is exercised independently of route behavior.
contract PriceLimitFixedOutputRoute is ISwapRouter {
    IERC20 internal immutable settlement;
    IERC20 internal immutable asset;
    uint256 internal output;

    constructor(IERC20 settlement_, IERC20 asset_) {
        settlement = settlement_;
        asset = asset_;
    }

    function setOutput(uint256 output_) external {
        output = output_;
    }

    function swapExactIn(address assetIn, address assetOut, uint256 amountIn, uint256) external returns (uint256) {
        require(assetIn == address(settlement) && assetOut == address(asset), "wrong pair");
        require(settlement.transferFrom(msg.sender, address(this), amountIn), "settlement transfer failed");
        require(asset.transfer(msg.sender, output), "asset transfer failed");
        return output;
    }
}

contract InvestmentEscrowPriceLimitsTest is Test {
    using Math for uint256;

    uint256 internal constant UNIT = 1e6;
    uint256 internal constant DEPOSIT = 100 * UNIT;
    uint256 internal constant LEG = DEPOSIT / 2;
    uint256 internal constant REFERENCE_PRICE = 100e18;
    uint256 internal constant TWO_PERCENT_CEILING = 102e18;
    address internal constant ALICE = address(0xA11CE);

    AssetRegistry internal registry;
    MockToken internal settlement;
    MockToken internal tokenA;
    MockToken internal tokenB;
    MockOracle internal oracleA;
    MockOracle internal oracleB;
    PriceLimitFixedOutputRoute internal routeA;
    PriceLimitFixedOutputRoute internal routeB;
    EquiVault internal vault;
    InvestmentEscrow internal escrow;

    function setUp() public {
        settlement = new MockToken(6);
        tokenA = new MockToken(18);
        tokenB = new MockToken(8);
        registry = new AssetRegistry(address(this), address(this));
        oracleA = new MockOracle();
        oracleB = new MockOracle();
        routeA = new PriceLimitFixedOutputRoute(settlement, tokenA);
        routeB = new PriceLimitFixedOutputRoute(settlement, tokenB);
        _register(address(tokenA), oracleA, address(routeA));
        _register(address(tokenB), oracleB, address(routeB));
        oracleA.setPrice(104e18, block.timestamp);
        oracleB.setPrice(104e18, block.timestamp);
        tokenA.mint(address(routeA), 1_000_000e18);
        tokenB.mint(address(routeB), 1_000_000e8);

        vault = _vaultWith(address(tokenA), address(tokenB), 100);
        escrow = InvestmentEscrow(vault.investmentEscrow());
        settlement.mint(ALICE, 1_000 * UNIT);
        vm.prank(ALICE);
        settlement.approve(address(escrow), type(uint256).max);
    }

    function testExactCeilingBoundaryUsesRoundedUpMinimumAndRecordsLimits() public {
        uint256[] memory limits = _limits(TWO_PERCENT_CEILING, 0);
        uint256 expectedOut = _ceilingOut(LEG, 18, TWO_PERCENT_CEILING);

        routeA.setOutput(expectedOut);
        vm.expectEmit(true, false, false, true, address(escrow));
        emit InvestmentEscrow.RequestPriceLimitsSet(1, limits);
        uint256 requestId = _createLimited(escrow, vault, limits);

        assertEq(escrow.priceLimitsVersion(), 1);
        assertEq(escrow.protocolVersion(), 2);
        uint256[] memory saved = escrow.getRequestPriceLimits(requestId);
        assertEq(saved.length, 2);
        assertEq(saved[0], TWO_PERCENT_CEILING);
        assertEq(saved[1], 0);

        escrow.fill(requestId, 0, LEG, 0, block.timestamp);
        (uint256 quantity, uint256 cost) = escrow.positions(requestId, address(tokenA));
        assertEq(quantity, expectedOut);
        assertEq(cost, LEG);
    }

    function testOneNaturalUnitAboveCeilingIsRejectedAgainstActualRouteDelta() public {
        uint256 requiredOut = _ceilingOut(LEG, 18, TWO_PERCENT_CEILING);
        routeA.setOutput(requiredOut - 1);
        uint256 requestId = _createLimited(escrow, vault, _limits(TWO_PERCENT_CEILING, 0));

        vm.expectRevert(
            abi.encodeWithSelector(
                InvestmentEscrow.RouteOutputBelowMinimum.selector, address(tokenA), requiredOut, requiredOut - 1
            )
        );
        escrow.fill(requestId, 0, LEG, 0, block.timestamp);

        assertEq(escrow.getRequest(requestId).available, DEPOSIT);
        (uint256 quantity, uint256 cost) = escrow.positions(requestId, address(tokenA));
        assertEq(quantity, 0);
        assertEq(cost, 0);
    }

    function testFeeIsIncludedInThePersonalPurchaseCeiling() public {
        MockToken feeAsset = new MockToken(18);
        MockOracle feeOracle = new MockOracle();
        MockOracleRoute feeRoute = new MockOracleRoute(registry, settlement, 200);
        _register(address(feeAsset), feeOracle, address(feeRoute));
        feeOracle.setPrice(REFERENCE_PRICE, block.timestamp);
        feeAsset.mint(address(feeRoute), 1_000_000e18);
        EquiVault feeVault = _vaultWith(address(feeAsset), address(tokenB), 300);
        InvestmentEscrow feeEscrow = InvestmentEscrow(feeVault.investmentEscrow());
        vm.prank(ALICE);
        settlement.approve(address(feeEscrow), type(uint256).max);

        uint256 requestId = _createLimited(feeEscrow, feeVault, _limits(TWO_PERCENT_CEILING, 0));
        uint256 ceilingOut = _ceilingOut(LEG, 18, TWO_PERCENT_CEILING);
        uint256 feeAdjustedOut = 49e16; // 0.5 asset at the oracle price, less the route's 2 % fee.
        assertLt(feeAdjustedOut, ceilingOut);

        vm.expectRevert(abi.encodeWithSelector(ISwapRouter.SlippageExceeded.selector, ceilingOut, feeAdjustedOut));
        feeEscrow.fill(requestId, 0, LEG, 0, block.timestamp);
    }

    function testDifferentAssetDecimalsUseTheirOwnCeilingScale() public {
        uint256 requiredOut = _ceilingOut(LEG, 8, TWO_PERCENT_CEILING);
        routeB.setOutput(requiredOut);
        uint256 requestId = _createLimited(escrow, vault, _limits(0, TWO_PERCENT_CEILING));

        escrow.fill(requestId, 1, LEG, 0, block.timestamp);
        (uint256 quantity, uint256 cost) = escrow.positions(requestId, address(tokenB));
        assertEq(quantity, requiredOut);
        assertEq(cost, LEG);
    }

    function testPersonalCeilingIsIsolatedPerLeg() public {
        routeA.setOutput(48e16); // Above the 1 % oracle min at 104, below the 102 ceiling minimum.
        routeB.setOutput(48e6); // Above the 1 % oracle min at 104 for the eight-decimal token.
        uint256 requestId = _createLimited(escrow, vault, _limits(TWO_PERCENT_CEILING, 0));

        vm.expectRevert();
        escrow.fill(requestId, 0, LEG, 0, block.timestamp);
        escrow.fill(requestId, 1, LEG, 0, block.timestamp);

        (uint256 aQuantity, uint256 aCost) = escrow.positions(requestId, address(tokenA));
        (uint256 bQuantity, uint256 bCost) = escrow.positions(requestId, address(tokenB));
        assertEq(aQuantity, 0);
        assertEq(aCost, 0);
        assertEq(bQuantity, 48e6);
        assertEq(bCost, LEG);
    }

    function testLegacyCreationStoresZeroLimitsAndRemainsUnlimited() public {
        routeA.setOutput(48e16);
        bytes32 version = vault.investmentVersion();
        vm.prank(ALICE);
        uint256 requestId = escrow.createRequest(DEPOSIT, version, block.timestamp);

        uint256[] memory limits = escrow.getRequestPriceLimits(requestId);
        assertEq(limits.length, 2);
        assertEq(limits[0], 0);
        assertEq(limits[1], 0);
        escrow.fill(requestId, 0, LEG, 0, block.timestamp);
    }

    function testLimitedRequestStopAndClaimNeedNoLivePriceOrOpenAsset() public {
        uint256 expectedOut = _ceilingOut(LEG, 18, TWO_PERCENT_CEILING);
        routeA.setOutput(expectedOut);
        uint256 requestId = _createLimited(escrow, vault, _limits(TWO_PERCENT_CEILING, 0));
        escrow.fill(requestId, 0, LEG, 0, block.timestamp);

        oracleA.setFails(true);
        oracleB.setFails(true);
        registry.setAssetStatus(address(tokenA), AssetRegistry.AssetStatus.Quarantined);
        registry.setDepositsPaused(true);

        vm.prank(ALICE);
        escrow.stop(requestId);
        assertEq(settlement.balanceOf(ALICE), 950 * UNIT);
        vm.prank(ALICE);
        escrow.claim(requestId, 0);
        assertEq(tokenA.balanceOf(ALICE), expectedOut);
        assertEq(uint256(escrow.getRequest(requestId).status), uint256(InvestmentEscrow.RequestStatus.Closed));
    }

    function testLimitLengthAndUnsafePriceAreRejectedBeforeDepositTransfer() public {
        uint256 aliceBefore = settlement.balanceOf(ALICE);
        uint256[] memory wrongLength = new uint256[](1);
        wrongLength[0] = TWO_PERCENT_CEILING;
        bytes32 version = vault.investmentVersion();
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(InvestmentEscrow.PriceLimitsLengthMismatch.selector, 2, 1));
        escrow.createRequestWithLimits(DEPOSIT, version, block.timestamp, wrongLength);
        assertEq(settlement.balanceOf(ALICE), aliceBefore);
        assertEq(escrow.nextRequestId(), 1);

        uint256 maximumPrice = type(uint256).max / UNIT;
        uint256 unsafePrice = maximumPrice + 1;
        uint256 minimumPrice = _minimumSafePrice(DEPOSIT, 18);
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(InvestmentEscrow.UnsafePriceLimit.selector, 0, unsafePrice, minimumPrice, maximumPrice)
        );
        escrow.createRequestWithLimits(DEPOSIT, version, block.timestamp, _limits(unsafePrice, 0));
        assertEq(settlement.balanceOf(ALICE), aliceBefore);
        assertEq(escrow.nextRequestId(), 1);

        uint256 oversizedAmount = type(uint256).max;
        uint256 unsafeLowPrice = _minimumSafePrice(oversizedAmount, 18) - 1;
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(
                InvestmentEscrow.UnsafePriceLimit.selector,
                0,
                unsafeLowPrice,
                unsafeLowPrice + 1,
                maximumPrice
            )
        );
        escrow.createRequestWithLimits(oversizedAmount, version, block.timestamp, _limits(unsafeLowPrice, 0));
        assertEq(settlement.balanceOf(ALICE), aliceBefore);
        assertEq(escrow.nextRequestId(), 1);
    }

    function _createLimited(InvestmentEscrow escrow_, EquiVault vault_, uint256[] memory limits)
        internal
        returns (uint256)
    {
        bytes32 version = vault_.investmentVersion();
        vm.prank(ALICE);
        return escrow_.createRequestWithLimits(DEPOSIT, version, block.timestamp, limits);
    }

    function _limits(uint256 first, uint256 second) internal pure returns (uint256[] memory limits) {
        limits = new uint256[](2);
        limits[0] = first;
        limits[1] = second;
    }

    function _ceilingOut(uint256 settlementIn, uint8 assetDecimals, uint256 maxPriceE18)
        internal
        pure
        returns (uint256)
    {
        return settlementIn.mulDiv(
            (10 ** uint256(assetDecimals)) * 1e18, maxPriceE18 * UNIT, Math.Rounding.Ceil
        );
    }

    function _minimumSafePrice(uint256 amount, uint8 assetDecimals) internal pure returns (uint256) {
        uint256 tokenScale = 10 ** uint256(assetDecimals);
        return Math.ceilDiv(amount.mulDiv(tokenScale * 1e18, type(uint256).max, Math.Rounding.Ceil), UNIT);
    }

    function _vaultWith(address first, address second, uint16 maxSlippageBps) internal returns (EquiVault result) {
        address[] memory assets = new address[](2);
        assets[0] = first;
        assets[1] = second;
        uint16[] memory weights = new uint16[](2);
        weights[0] = 5_000;
        weights[1] = 5_000;
        result = new EquiVault(
            settlement,
            registry,
            address(this),
            assets,
            weights,
            0,
            maxSlippageBps,
            EquiVault.TimelockMode.Immutable,
            0,
            0,
            0
        );
    }

    function _register(address asset, IPriceOracle oracle, address route) internal {
        registry.registerAsset(asset, oracle, oracle, route, 1 days);
    }
}
