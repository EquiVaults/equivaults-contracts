// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";

import {AssetRegistry} from "../src/AssetRegistry.sol";
import {EquiVault} from "../src/EquiVault.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {InvestmentExecutionAccount} from "../src/InvestmentExecutionAccount.sol";
import {InvestmentExecutionFactory} from "../src/InvestmentExecutionFactory.sol";
import {MockOracle, MockPool, MockToken} from "../test/mocks/Mocks.sol";
import {NamedMockToken} from "./LocalDemoTokens.sol";

/// @notice Opt-in stress extension for an already-seeded local demo.
/// @dev It is run only by simulation_fixture.py after it has persisted a progress marker and
/// impersonated the fixed local actors. It deliberately has no production deployment path.
contract SeedSimulationFixture is Script {
    uint48 internal constant MAX_PRICE_AGE = 1 hours;
    uint256 internal constant POOL_SETTLEMENT = 200_000e6;
    uint256 internal constant INVESTOR_FUNDS = 1_000_000e6;

    address internal constant ADMIN = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address internal constant EARLY = 0x1000000000000000000000000000000000000001;
    address internal constant LATE = 0x1000000000000000000000000000000000000002;
    address internal constant PATIENT = 0x1000000000000000000000000000000000000003;
    address internal constant WHALE = 0x1000000000000000000000000000000000000004;
    address internal constant MIXED = 0x1000000000000000000000000000000000000005;
    address internal constant EXIT = 0x1000000000000000000000000000000000000006;
    address internal constant BLOCKED = 0x1000000000000000000000000000000000000007;
    address internal constant NEW_INVESTOR = 0x1000000000000000000000000000000000000008;

    AssetRegistry internal registry;
    VaultFactory internal factory;
    MockToken internal settlement;
    address[5] internal assets;

    function run() external {
        require(block.chainid == 31337, "SeedSimulationFixture: expected Anvil");
        settlement = MockToken(vm.envAddress("DEMO_SETTLEMENT"));
        registry = AssetRegistry(vm.envAddress("DEMO_REGISTRY"));
        factory = VaultFactory(vm.envAddress("DEMO_FACTORY"));
        require(address(factory.settlementAsset()) == address(settlement), "SeedSimulationFixture: settlement");
        require(address(factory.registry()) == address(registry), "SeedSimulationFixture: registry");
        require(factory.vaultCount() == vm.envUint("SIMULATION_BASE_VAULT_COUNT"), "SeedSimulationFixture: baseline");
        require(registry.hasRole(bytes32(0), ADMIN), "SeedSimulationFixture: admin");

        vm.startBroadcast(ADMIN);
        _fundActors();
        assets[0] = _addAsset("Stress Rally", "RALLY", 18, 80e18, 79e18, 150_000e6);
        assets[1] = _addAsset("Stress Bottleneck", "BOTTL", 18, 30e18, 295e17, 12_000e6);
        assets[2] = _addAsset("Stress Illiquid", "ILLQ", 18, 12e18, 118e17, 8_000e6);
        assets[3] = _addAsset("Stress Volatile", "VOLX", 18, 55e18, 54e18, 40_000e6);
        assets[4] = _addAsset("Stress Shared Pool", "SHARE", 18, 22e18, 218e17, 25_000e6);
        address[5] memory vaults = _createVaults();
        vm.stopBroadcast();

        _seedInvestorHistory(vaults);
        _seedExecutionBudgets(vaults);
        // LATE and NEW_INVESTOR intentionally have no historical position. The engine stages the
        // former after a price rise; the latter is funded but has no investment history at all.
    }

    function _fundActors() private {
        settlement.mint(EARLY, INVESTOR_FUNDS);
        settlement.mint(LATE, INVESTOR_FUNDS);
        settlement.mint(PATIENT, INVESTOR_FUNDS);
        settlement.mint(WHALE, 4 * INVESTOR_FUNDS);
        settlement.mint(MIXED, INVESTOR_FUNDS);
        settlement.mint(EXIT, INVESTOR_FUNDS);
        settlement.mint(BLOCKED, INVESTOR_FUNDS);
        settlement.mint(NEW_INVESTOR, 50_000e6);
    }

    function _addAsset(
        string memory name, string memory symbol, uint8 decimals, uint256 price, uint256 fallbackPrice, uint256 reserve
    ) private returns (address tokenAddress) {
        NamedMockToken token = new NamedMockToken(name, symbol, decimals);
        MockOracle primary = new MockOracle();
        MockOracle fallbackOracle = new MockOracle();
        MockPool pool = new MockPool(settlement, token, 30);
        primary.setPrice(price, block.timestamp);
        fallbackOracle.setPrice(fallbackPrice, block.timestamp);
        registry.registerAsset(address(token), primary, fallbackOracle, address(pool), MAX_PRICE_AGE);
        uint256 tokenReserve = reserve * (10 ** uint256(decimals)) * 1e18 / (price * 1e6);
        settlement.mint(ADMIN, reserve);
        token.mint(ADMIN, tokenReserve);
        settlement.approve(address(pool), type(uint256).max);
        token.approve(address(pool), type(uint256).max);
        pool.seed(reserve, tokenReserve);
        return address(token);
    }

    function _createVaults() private returns (address[5] memory vaults) {
        vaults[0] = _create(EARLY, _two(0, 3), _weights2(6_000, 4_000));
        vaults[1] = _create(PATIENT, _one(1), _weights1());
        vaults[2] = _create(MIXED, _three(2, 3, 4), _weights3(4_000, 3_500, 2_500));
        vaults[3] = _create(EXIT, _one(3), _weights1());
        vaults[4] = _create(WHALE, _two(4, 0), _weights2(5_000, 5_000));
    }

    function _create(address manager, uint8[] memory indexes, uint16[] memory weights) private returns (address vault) {
        address[] memory basket = new address[](indexes.length);
        for (uint256 i; i < indexes.length; ++i) basket[i] = assets[indexes[i]];
        vault = factory.createVault(manager, basket, weights, 500, 300, EquiVault.TimelockMode.Instant, 0, 300, 100);
    }

    function _seedInvestorHistory(address[5] memory vaults) private {
        _enter(vaults[0], EARLY, 300e6);
        _enter(vaults[2], MIXED, 300e6);
        _enter(vaults[3], EXIT, 500e6);
        _partialExit(vaults[3]);
        _request(vaults[0], PATIENT, 30_000e6, 10_200);
        _request(vaults[1], WHALE, 1_500_000e6, 10_150);
        _request(vaults[3], BLOCKED, 20_000e6, 9_000);
    }

    function _enter(address vault, address investor, uint256 amount) private {
        vm.startBroadcast(investor);
        settlement.approve(vault, amount);
        uint256[] memory mins = new uint256[](0);
        EquiVault(vault).enter(EquiVault.EnterParams(amount, investor, 0, mins, block.timestamp + 1 days, 0));
        vm.stopBroadcast();
    }

    function _partialExit(address vault) private {
        uint256 shares = EquiVault(vault).balanceOf(EXIT) / 2;
        vm.startBroadcast(EXIT);
        bool[] memory sell = new bool[](1);
        sell[0] = true;
        uint256[] memory mins = new uint256[](0);
        EquiVault(vault).exit(EquiVault.ExitParams(shares, EXIT, sell, mins, 0, block.timestamp + 1 days));
        vm.stopBroadcast();
    }

    function _request(address vault, address investor, uint256 amount, uint256 priceBps) private {
        address escrow = EquiVault(vault).investmentEscrow();
        address[] memory basket = EquiVault(vault).basketAssets();
        uint256[] memory limits = new uint256[](basket.length);
        for (uint256 i; i < basket.length; ++i) {
            (uint256 price,) = registry.getPrice(basket[i], address(settlement));
            limits[i] = price * priceBps / 10_000;
        }
        vm.startBroadcast(investor);
        settlement.approve(escrow, amount);
        // The frozen price ceilings are the request's personal acquisition limits. The blocked
        // profile uses a below-market ceiling; its request remains recoverable but cannot fill.
        (bool ok,) = escrow.call(
            abi.encodeWithSignature("createRequestWithLimits(uint256,bytes32,uint256,uint256[])", amount,
                EquiVault(vault).investmentVersion(), block.timestamp + 30 days, limits)
        );
        require(ok, "SeedSimulationFixture: request");
        vm.stopBroadcast();
    }

    function _seedExecutionBudgets(address[5] memory vaults) private {
        InvestmentExecutionFactory executionFactory = InvestmentExecutionFactory(vm.envAddress("SIMULATION_EXECUTION_FACTORY"));
        address executor = vm.envAddress("SIMULATION_EXECUTOR");
        require(address(executionFactory).code.length != 0 && executionFactory.vaultFactory() == factory,
            "SeedSimulationFixture: execution factory");
        require(executor != address(0), "SeedSimulationFixture: executor");
        _createExecutionAccount(executionFactory, EquiVault(vaults[0]).investmentEscrow(), PATIENT, executor);
        _createExecutionAccount(executionFactory, EquiVault(vaults[1]).investmentEscrow(), WHALE, executor);
        _createExecutionAccount(executionFactory, EquiVault(vaults[3]).investmentEscrow(), BLOCKED, executor);
    }

    function _createExecutionAccount(
        InvestmentExecutionFactory executionFactory, address escrow, address investor, address executor
    ) private {
        InvestmentExecutionAccount.Policy memory policy = InvestmentExecutionAccount.Policy({
            maxFeePerGas: uint128(1 gwei), maxAttemptFee: uint128(0.01 ether), maxAttempts: 32,
            validUntil: uint48(block.timestamp + 30 days), minFillAmount: 1e6
        });
        vm.startBroadcast(investor);
        executionFactory.createAccount{value: 0.32 ether}(escrow, 1, executor, policy);
        vm.stopBroadcast();
    }

    function _one(uint8 a) private pure returns (uint8[] memory r) { r = new uint8[](1); r[0] = a; }
    function _two(uint8 a, uint8 b) private pure returns (uint8[] memory r) { r = new uint8[](2); r[0] = a; r[1] = b; }
    function _three(uint8 a, uint8 b, uint8 c) private pure returns (uint8[] memory r) { r = new uint8[](3); r[0] = a; r[1] = b; r[2] = c; }
    function _weights1() private pure returns (uint16[] memory r) { r = new uint16[](1); r[0] = 10_000; }
    function _weights2(uint16 a, uint16 b) private pure returns (uint16[] memory r) { r = new uint16[](2); r[0] = a; r[1] = b; }
    function _weights3(uint16 a, uint16 b, uint16 c) private pure returns (uint16[] memory r) { r = new uint16[](3); r[0] = a; r[1] = b; r[2] = c; }
}
