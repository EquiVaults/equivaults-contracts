// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";

import {AssetRegistry} from "../src/AssetRegistry.sol";
import {EquiVault} from "../src/EquiVault.sol";
import {InvestmentEscrow} from "../src/InvestmentEscrow.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {MockOracle, MockOracleRoute, MockToken} from "./mocks/Mocks.sol";

/// @dev Bounded stateful driver. Failed external operations are intentional inputs, never state advances.
contract InvestmentProgressHandler {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 internal constant UNIT = 1e6;

    InvestmentEscrow public immutable escrow;
    EquiVault public immutable vault;
    MockToken public immutable settlement;
    MockToken public immutable tokenA;
    MockToken public immutable tokenB;
    address[3] internal _owners;
    uint256[] internal _requestIds;
    mapping(uint256 requestId => uint256 cost) internal _claimedCost;

    constructor(
        InvestmentEscrow escrow_,
        EquiVault vault_,
        MockToken settlement_,
        MockToken tokenA_,
        MockToken tokenB_,
        address[3] memory owners_
    ) {
        escrow = escrow_;
        vault = vault_;
        settlement = settlement_;
        tokenA = tokenA_;
        tokenB = tokenB_;
        _owners = owners_;
    }

    function create(uint256 ownerSeed, uint256 amountSeed) external {
        address owner = _owners[ownerSeed % _owners.length];
        uint256 amount = (amountSeed % (50 * UNIT)) + UNIT;
        bytes32 version = vault.investmentVersion();
        vm.prank(owner);
        try escrow.createRequest(amount, version, block.timestamp) returns (uint256 requestId) {
            _requestIds.push(requestId);
        } catch {}
    }

    function fill(uint256 requestSeed, uint256 indexSeed, uint256 amountSeed) external {
        if (_requestIds.length == 0) return;
        uint256 requestId = _requestIds[requestSeed % _requestIds.length];
        InvestmentEscrow.Request memory request = escrow.getRequest(requestId);
        if (request.status != InvestmentEscrow.RequestStatus.Open || request.available == 0) return;
        uint256 amount = (amountSeed % request.available) + 1;
        try escrow.fill(requestId, indexSeed % 2, amount, request.sequence, block.timestamp) {} catch {}
    }

    function integrate(uint256 requestSeed) external {
        if (_requestIds.length == 0) return;
        uint256 requestId = _requestIds[requestSeed % _requestIds.length];
        InvestmentEscrow.Request memory request = escrow.getRequest(requestId);
        if (request.status != InvestmentEscrow.RequestStatus.Open) return;
        try escrow.integrate(requestId, request.sequence) {} catch {}
    }

    function stop(uint256 requestSeed) external {
        if (_requestIds.length == 0) return;
        uint256 requestId = _requestIds[requestSeed % _requestIds.length];
        InvestmentEscrow.Request memory request = escrow.getRequest(requestId);
        if (request.status != InvestmentEscrow.RequestStatus.Open) return;
        vm.prank(request.owner);
        try escrow.stop(requestId) {} catch {}
    }

    function claim(uint256 requestSeed, uint256 indexSeed) external {
        if (_requestIds.length == 0) return;
        uint256 requestId = _requestIds[requestSeed % _requestIds.length];
        InvestmentEscrow.Request memory request = escrow.getRequest(requestId);
        if (request.status != InvestmentEscrow.RequestStatus.Stopped) return;
        uint256 index = indexSeed % 2;
        (, uint256 cost) = escrow.positions(requestId, index == 0 ? address(tokenA) : address(tokenB));
        vm.prank(request.owner);
        try escrow.claim(requestId, index) {
            _claimedCost[requestId] += cost;
        } catch {}
    }

    /// @dev Donations deliberately enlarge balance but must never create an accounting credit.
    function donate(uint256 settlementSeed, uint256 aSeed, uint256 bSeed) external {
        settlement.mint(address(escrow), settlementSeed % (10 * UNIT));
        tokenA.mint(address(escrow), aSeed % (10e18));
        tokenB.mint(address(escrow), bSeed % (10e18));
    }

    function requestCount() external view returns (uint256) {
        return _requestIds.length;
    }

    function requestIdAt(uint256 index) external view returns (uint256) {
        return _requestIds[index];
    }

    function claimedCost(uint256 requestId) external view returns (uint256) {
        return _claimedCost[requestId];
    }
}

contract InvestmentProgressInvariantTest is Test {
    uint256 internal constant UNIT = 1e6;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA701);

    AssetRegistry internal registry;
    MockToken internal settlement;
    MockToken internal tokenA;
    MockToken internal tokenB;
    EquiVault internal vault;
    InvestmentEscrow internal escrow;
    InvestmentProgressHandler internal handler;

    function setUp() public {
        (registry, settlement, tokenA, tokenB, vault, escrow) = _deployTwoAssetVault();
        address[3] memory owners = [ALICE, BOB, CAROL];
        for (uint256 i = 0; i < owners.length; ++i) {
            settlement.mint(owners[i], 10_000 * UNIT);
            vm.prank(owners[i]);
            settlement.approve(address(escrow), type(uint256).max);
        }
        handler = new InvestmentProgressHandler(escrow, vault, settlement, tokenA, tokenB, owners);
        targetContract(address(handler));
        // Exercise the complete bootstrap path before fuzzing so the campaign is not vacuous.
        handler.create(0, 49 * UNIT);
        handler.fill(0, 0, 25 * UNIT - 1);
        handler.fill(0, 1, 25 * UNIT - 1);
        handler.integrate(0);
        assertGt(vault.balanceOf(ALICE), 0, "handler bootstrap must integrate");
    }

    function invariantSettlementLiabilitiesAreBackedAndEveryRequestConserves() public view {
        uint256 totalAvailable;
        uint256 requestCount = handler.requestCount();
        for (uint256 i = 0; i < requestCount; ++i) {
            uint256 requestId = handler.requestIdAt(i);
            InvestmentEscrow.Request memory request = escrow.getRequest(requestId);
            assertEq(request.deposited, request.available + request.spent + request.refunded, "settlement conservation");
            totalAvailable += request.available;
        }
        assertLe(totalAvailable, settlement.balanceOf(address(escrow)), "unbacked settlement liability");
    }

    function invariantPendingTokensAndHistoricalCostsConserve() public view {
        uint256 pendingA;
        uint256 pendingB;
        uint256 requestCount = handler.requestCount();
        for (uint256 i = 0; i < requestCount; ++i) {
            uint256 requestId = handler.requestIdAt(i);
            (uint256 aQuantity, uint256 aCost) = escrow.positions(requestId, address(tokenA));
            (uint256 bQuantity, uint256 bCost) = escrow.positions(requestId, address(tokenB));
            InvestmentEscrow.Request memory request = escrow.getRequest(requestId);
            pendingA += aQuantity;
            pendingB += bQuantity;
            assertEq(
                aCost + bCost + request.integratedCost + handler.claimedCost(requestId),
                request.spent,
                "historical acquisition cost conservation"
            );
        }
        assertLe(pendingA, tokenA.balanceOf(address(escrow)), "unbacked token A position");
        assertLe(pendingB, tokenB.balanceOf(address(escrow)), "unbacked token B position");
    }

    function _deployTwoAssetVault()
        private
        returns (
            AssetRegistry registry_,
            MockToken settlement_,
            MockToken tokenA_,
            MockToken tokenB_,
            EquiVault vault_,
            InvestmentEscrow escrow_
        )
    {
        settlement_ = new MockToken(6);
        tokenA_ = new MockToken(18);
        tokenB_ = new MockToken(18);
        registry_ = new AssetRegistry(address(this), address(this));
        MockOracle oracleA = new MockOracle();
        MockOracle oracleB = new MockOracle();
        MockOracleRoute routeA = new MockOracleRoute(registry_, settlement_, 0);
        MockOracleRoute routeB = new MockOracleRoute(registry_, settlement_, 0);
        _register(registry_, address(tokenA_), oracleA, address(routeA));
        _register(registry_, address(tokenB_), oracleB, address(routeB));
        oracleA.setPrice(1e18, block.timestamp);
        oracleB.setPrice(1e18, block.timestamp);
        tokenA_.mint(address(routeA), 10_000_000e18);
        tokenB_.mint(address(routeB), 10_000_000e18);
        vault_ = _newVault(settlement_, registry_, address(tokenA_), address(tokenB_));
        escrow_ = InvestmentEscrow(vault_.investmentEscrow());
    }

    function _newVault(IERC20 settlement_, AssetRegistry registry_, address first, address second)
        private
        returns (EquiVault)
    {
        address[] memory assets = new address[](2);
        assets[0] = first;
        assets[1] = second;
        uint16[] memory weights = new uint16[](2);
        weights[0] = 5_000;
        weights[1] = 5_000;
        return new EquiVault(
            settlement_, registry_, address(this), assets, weights, 0, 100, EquiVault.TimelockMode.Immutable, 0, 0, 0
        );
    }

    function _register(AssetRegistry registry_, address asset, IPriceOracle oracle, address route) private {
        registry_.registerAsset(asset, oracle, oracle, route, 1 days);
    }
}

contract FiveAssetProgressFixture {
    MockToken public settlement;
    AssetRegistry public registry;
    EquiVault public vault;
    InvestmentEscrow public escrow;
    MockToken[5] internal _tokens;

    constructor() {
        settlement = new MockToken(6);
        registry = new AssetRegistry(address(this), address(this));
        address[] memory assets = new address[](5);
        uint16[] memory weights = new uint16[](5);
        for (uint256 i = 0; i < 5; ++i) {
            assets[i] = _addAsset(i);
            weights[i] = 2_000;
        }
        vault = new EquiVault(
            settlement, registry, address(this), assets, weights, 0, 100, EquiVault.TimelockMode.Immutable, 0, 0, 0
        );
        escrow = InvestmentEscrow(vault.investmentEscrow());
    }

    function _addAsset(uint256 index) private returns (address) {
        MockToken token = new MockToken(18);
        MockOracle oracle = new MockOracle();
        MockOracleRoute route = new MockOracleRoute(registry, settlement, 0);
        registry.registerAsset(address(token), oracle, oracle, address(route), 1 days);
        oracle.setPrice(1e18, block.timestamp);
        token.mint(address(route), 10_000_000e18);
        _tokens[index] = token;
        return address(token);
    }
}

contract InvestmentProgressLimitsTest is Test {
    uint256 internal constant UNIT = 1e6;
    address internal constant ALICE = address(0xA11CE);

    function testFiveAssetFillAndIntegrationGas() public {
        FiveAssetProgressFixture fixture = new FiveAssetProgressFixture();
        MockToken settlement = fixture.settlement();
        EquiVault vault = fixture.vault();
        InvestmentEscrow escrow = fixture.escrow();
        settlement.mint(ALICE, 500 * UNIT);
        vm.startPrank(ALICE);
        settlement.approve(address(escrow), type(uint256).max);
        uint256 requestId = escrow.createRequest(500 * UNIT, vault.investmentVersion(), block.timestamp);
        vm.stopPrank();

        uint256 sequence;
        uint256 totalFillGas;
        for (uint256 i = 0; i < 5; ++i) {
            uint256 gasBefore = gasleft();
            escrow.fill(requestId, i, 100 * UNIT, sequence, block.timestamp);
            totalFillGas += gasBefore - gasleft();
            ++sequence;
        }
        uint256 integrationGasBefore = gasleft();
        uint256 shares = escrow.integrate(requestId, sequence);
        uint256 integrationGas = integrationGasBefore - gasleft();
        emit log_named_uint("fiveAssetTotalFillGas", totalFillGas);
        emit log_named_uint("fiveAssetIntegrationGas", integrationGas);
        assertGt(shares, 0);
        assertEq(vault.balanceOf(ALICE), shares);
    }

    function testLowDecimalDustFillRejectsAndSettlementRemainsRecoverable() public {
        MockToken settlement = new MockToken(6);
        MockToken indivisible = new MockToken(0);
        MockToken regular = new MockToken(18);
        AssetRegistry registry = new AssetRegistry(address(this), address(this));
        MockOracle lowOracle = new MockOracle();
        MockOracle regularOracle = new MockOracle();
        MockOracleRoute lowRoute = new MockOracleRoute(registry, settlement, 0);
        MockOracleRoute regularRoute = new MockOracleRoute(registry, settlement, 0);
        registry.registerAsset(address(indivisible), lowOracle, lowOracle, address(lowRoute), 1 days);
        registry.registerAsset(address(regular), regularOracle, regularOracle, address(regularRoute), 1 days);
        lowOracle.setPrice(1e18, block.timestamp);
        regularOracle.setPrice(1e18, block.timestamp);
        indivisible.mint(address(lowRoute), 1_000_000);
        regular.mint(address(regularRoute), 1_000_000e18);
        EquiVault vault = _newTwoAssetVault(settlement, registry, address(indivisible), address(regular));
        InvestmentEscrow escrow = InvestmentEscrow(vault.investmentEscrow());
        settlement.mint(ALICE, UNIT);
        vm.startPrank(ALICE);
        settlement.approve(address(escrow), UNIT);
        uint256 requestId = escrow.createRequest(UNIT, vault.investmentVersion(), block.timestamp);
        vm.expectRevert();
        escrow.fill(requestId, 0, UNIT / 2, 0, block.timestamp);
        escrow.stop(requestId);
        vm.stopPrank();
        assertEq(settlement.balanceOf(ALICE), UNIT);
    }

    function _newTwoAssetVault(IERC20 settlement, AssetRegistry registry, address first, address second)
        private
        returns (EquiVault)
    {
        address[] memory assets = new address[](2);
        assets[0] = first;
        assets[1] = second;
        uint16[] memory weights = new uint16[](2);
        weights[0] = 5_000;
        weights[1] = 5_000;
        return new EquiVault(
            settlement, registry, address(this), assets, weights, 0, 100, EquiVault.TimelockMode.Immutable, 0, 0, 0
        );
    }
}
