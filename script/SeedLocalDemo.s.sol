// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {AssetRegistry} from "../src/AssetRegistry.sol";
import {EquiVault} from "../src/EquiVault.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {MockOracle, MockPool, MockToken} from "../test/mocks/Mocks.sol";
import {NamedMockToken} from "./LocalDemoTokens.sol";

/// @notice Adds a rich, deliberately local-only fixture to a LOCAL_DEMO DeployLocal deployment.
/// @dev This script is intentionally one-shot: it requires the unseeded baseline factory to hold
/// exactly one vault. It never resets a chain, accepts no private key, and broadcasts only through
/// unlocked canonical Anvil accounts. Read script/demo-vaults.json for the stable asset and vault order.
contract SeedLocalDemo is Script {
    uint48 internal constant MAX_PRICE_AGE = 1 hours;
    uint256 internal constant POOL_LIQUIDITY = 50_000_000e6;

    address internal constant ANVIL0 = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address internal constant ANVIL1 = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address internal constant ANVIL3 = 0x90F79bf6EB2c4f870365E785982E1f101E93b906;
    address internal constant ANVIL4 = 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65;
    address internal constant ANVIL5 = 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc;
    address internal constant ANVIL6 = 0x976EA74026E726554dB657fA54763abd0C3a0aa9;
    address internal constant ANVIL7 = 0x14dC79964da2C08b23698B3D3cc7Ca32193d9955;
    address internal constant ANVIL8 = 0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f;
    address internal constant ANVIL9 = 0xa0Ee7A142d267C1f36714E4a8F75612F20a79720;

    event DemoTokenSeeded(
        string key, address indexed token, uint8 decimals, uint256 primaryPriceE18, uint256 fallbackPriceE18
    );
    event DemoVaultSeeded(
        uint256 indexed fixtureIndex,
        address indexed vault,
        address indexed manager,
        uint8 assetCount,
        bool seededPosition
    );

    AssetRegistry internal registry;
    VaultFactory internal factory;
    MockToken internal settlement;
    address[8] internal assets;

    function run() external {
        require(block.chainid == 31337, "SeedLocalDemo: expected Anvil chainId 31337");

        settlement = MockToken(vm.envAddress("DEMO_SETTLEMENT"));
        registry = AssetRegistry(vm.envAddress("DEMO_REGISTRY"));
        factory = VaultFactory(vm.envAddress("DEMO_FACTORY"));
        assets[0] = vm.envAddress("DEMO_TOKEN_A");
        assets[1] = vm.envAddress("DEMO_TOKEN_B");
        _validateBaseline();

        vm.startBroadcast(ANVIL0);
        _seedAdditionalAssets();
        address[16] memory vaults = _createVaults();
        vm.stopBroadcast();

        _seedPositions(vaults);
        _createPendingProposals(vaults);

        console2.log("SeedLocalDemo: added six assets");
        console2.log("SeedLocalDemo: factory vault count");
        console2.logUint(factory.vaultCount());
    }

    function _validateBaseline() internal view {
        require(address(settlement).code.length != 0, "SeedLocalDemo: settlement has no code");
        require(address(registry).code.length != 0, "SeedLocalDemo: registry has no code");
        require(address(factory).code.length != 0, "SeedLocalDemo: factory has no code");
        require(address(factory.settlementAsset()) == address(settlement), "SeedLocalDemo: settlement mismatch");
        require(address(factory.registry()) == address(registry), "SeedLocalDemo: registry mismatch");
        require(factory.vaultCount() == 1, "SeedLocalDemo: expected exactly one unseeded baseline vault");
        require(factory.vaults(0).code.length != 0, "SeedLocalDemo: baseline vault missing");
        require(registry.hasRole(bytes32(0), ANVIL0), "SeedLocalDemo: canonical Anvil admin required");
        require(settlement.decimals() == 6, "SeedLocalDemo: expected six-decimal settlement");

        _validateNamedBaseline(assets[0], "ETH", 18, 2_500e18);
        _validateNamedBaseline(assets[1], "BTC", 8, 65_000e18);
    }

    function _validateNamedBaseline(
        address token,
        string memory expectedSymbol,
        uint8 expectedDecimals,
        uint256 expectedPrice
    ) internal view {
        require(token.code.length != 0, "SeedLocalDemo: baseline token has no code");
        require(IERC20Metadata(token).decimals() == expectedDecimals, "SeedLocalDemo: unexpected baseline decimals");
        require(
            keccak256(bytes(IERC20Metadata(token).symbol())) == keccak256(bytes(expectedSymbol)),
            "SeedLocalDemo: run DeployLocal with LOCAL_DEMO=true"
        );
        AssetRegistry.AssetConfig memory config = registry.assetConfig(token);
        require(config.maxPriceAge == MAX_PRICE_AGE, "SeedLocalDemo: unexpected price age");
        (uint256 livePrice,) = registry.getPrice(token, address(settlement));
        require(livePrice == expectedPrice, "SeedLocalDemo: unexpected baseline price");
    }

    function _seedAdditionalAssets() internal {
        emit DemoTokenSeeded("ETH", assets[0], 18, 2_500e18, 2_490e18);
        emit DemoTokenSeeded("BTC", assets[1], 8, 65_000e18, 64_800e18);
        assets[2] = _addAsset("Demo Solana", "SOL", 9, 150e18, 149e18);
        assets[3] = _addAsset("Demo Avalanche", "AVAX", 18, 40e18, 39e18);
        assets[4] = _addAsset("Demo Chainlink", "LINK", 18, 15e18, 149e17);
        assets[5] = _addAsset("Demo Uniswap", "UNI", 18, 10e18, 99e17);
        assets[6] = _addAsset("Demo Aave", "AAVE", 18, 250e18, 248e18);
        assets[7] = _addAsset("Demo Arbitrum", "ARB", 18, 75e16, 74e16);
    }

    function _addAsset(string memory name, string memory symbol, uint8 decimals, uint256 price, uint256 fallbackPrice)
        internal
        returns (address tokenAddress)
    {
        NamedMockToken token = new NamedMockToken(name, symbol, decimals);
        MockOracle primary = new MockOracle();
        MockOracle secondary = new MockOracle();
        MockPool pool = new MockPool(settlement, token, 30);
        primary.setPrice(price, block.timestamp);
        secondary.setPrice(fallbackPrice, block.timestamp);
        registry.registerAsset(address(token), primary, secondary, address(pool), MAX_PRICE_AGE);

        uint256 tokenLiquidity = _tokenAmountForSettlement(POOL_LIQUIDITY, decimals, price);
        settlement.mint(ANVIL0, POOL_LIQUIDITY);
        token.mint(ANVIL0, tokenLiquidity);
        settlement.approve(address(pool), type(uint256).max);
        token.approve(address(pool), type(uint256).max);
        pool.seed(POOL_LIQUIDITY, tokenLiquidity);

        emit DemoTokenSeeded(symbol, address(token), decimals, price, fallbackPrice);
        return address(token);
    }

    function _tokenAmountForSettlement(uint256 settlementAmount, uint8 decimals, uint256 priceE18)
        internal
        pure
        returns (uint256)
    {
        return settlementAmount * (10 ** uint256(decimals)) * 1e18 / (priceE18 * 1e6);
    }

    function _createVaults() internal returns (address[16] memory vaults) {
        vaults[0] =
            _create(ANVIL1, _one(0), _weights1(), 500, 100, EquiVault.TimelockMode.Instant, 0, 150, 50);
        vaults[1] = _create(
            ANVIL4, _one(1), _weights1(), 1_250, 250, EquiVault.TimelockMode.Delayed, 2 days, 300, 100
        );
        vaults[2] = _create(
            ANVIL5,
            _two(0, 1),
            _weights2(5_000, 5_000),
            0,
            150,
            EquiVault.TimelockMode.Immutable,
            0,
            500,
            100
        );
        vaults[3] = _create(
            ANVIL6,
            _three(0, 1, 2),
            _weights3(4_500, 3_000, 2_500),
            750,
            200,
            EquiVault.TimelockMode.Delayed,
            1 days,
            250,
            75
        );
        vaults[4] = _create(
            ANVIL7,
            _three(2, 3, 4),
            _weights3(4_000, 3_500, 2_500),
            1_500,
            300,
            EquiVault.TimelockMode.Instant,
            0,
            350,
            125
        );
        vaults[5] = _create(
            ANVIL8,
            _five(0, 1, 2, 3, 4),
            _weights5(3_000, 2_500, 2_000, 1_500, 1_000),
            1_000,
            300,
            EquiVault.TimelockMode.Delayed,
            3 days,
            400,
            150
        );
        vaults[6] = _create(
            ANVIL9,
            _five(5, 6, 7, 0, 1),
            _weights5(2_500, 2_000, 1_500, 2_500, 1_500),
            2_000,
            300,
            EquiVault.TimelockMode.Immutable,
            0,
            600,
            200
        );
        vaults[7] =
            _create(ANVIL4, _one(4), _weights1(), 250, 100, EquiVault.TimelockMode.Delayed, 7 days, 200, 50);
        vaults[8] = _create(
            ANVIL9,
            _two(3, 5),
            _weights2(5_500, 4_500),
            900,
            180,
            EquiVault.TimelockMode.Instant,
            0,
            450,
            100
        );
        vaults[9] = _create(
            ANVIL4,
            _three(6, 7, 0),
            _weights3(3_500, 2_500, 4_000),
            1_100,
            220,
            EquiVault.TimelockMode.Delayed,
            4 days,
            300,
            150
        );
        vaults[10] = _create(
            ANVIL5,
            _five(1, 2, 4, 5, 6),
            _weights5(3_000, 2_000, 2_000, 1_500, 1_500),
            650,
            200,
            EquiVault.TimelockMode.Instant,
            0,
            250,
            75
        );
        vaults[11] =
            _create(ANVIL6, _one(7), _weights1(), 1_800, 280, EquiVault.TimelockMode.Immutable, 0, 700, 250);
        vaults[12] = _create(
            ANVIL7,
            _two(0, 6),
            _weights2(6_000, 4_000),
            400,
            120,
            EquiVault.TimelockMode.Delayed,
            2 days,
            200,
            50
        );
        vaults[13] = _create(
            ANVIL8,
            _three(1, 3, 7),
            _weights3(5_000, 3_000, 2_000),
            1_300,
            250,
            EquiVault.TimelockMode.Instant,
            0,
            500,
            150
        );
        vaults[14] = _create(
            ANVIL9,
            _five(0, 2, 5, 6, 7),
            _weights5(3_500, 2_000, 1_500, 1_500, 1_500),
            950,
            200,
            EquiVault.TimelockMode.Delayed,
            5 days,
            350,
            100
        );
        vaults[15] = _create(
            ANVIL4,
            _two(4, 5),
            _weights2(5_000, 5_000),
            600,
            150,
            EquiVault.TimelockMode.Immutable,
            0,
            300,
            100
        );

        for (uint256 i = 0; i < vaults.length; ++i) {
            bool seededPosition = i != 2 && i != 6 && i != 11;
            emit DemoVaultSeeded(
                i + 1,
                vaults[i],
                EquiVault(vaults[i]).manager(),
                uint8(EquiVault(vaults[i]).basketAssets().length),
                seededPosition
            );
        }
    }

    function _create(
        address manager,
        uint8[] memory indexes,
        uint16[] memory weights,
        uint16 feeBps,
        uint16 maxSlippageBps,
        EquiVault.TimelockMode mode,
        uint256 delay,
        uint16 drift,
        uint16 rebalanceSlippage
    ) internal returns (address vault) {
        address[] memory basket = new address[](indexes.length);
        for (uint256 i = 0; i < indexes.length; ++i) {
            basket[i] = assets[indexes[i]];
        }
        vault = factory.createVault(
            manager, basket, weights, feeBps, maxSlippageBps, mode, delay, drift, rebalanceSlippage
        );
    }

    function _seedPositions(address[16] memory vaults) internal {
        _deposit(vaults[0], ANVIL3, 15_000e6);
        _deposit(vaults[1], ANVIL4, 8_000e6);
        _deposit(vaults[3], ANVIL5, 25_000e6);
        _deposit(vaults[4], ANVIL6, 12_000e6);
        _deposit(vaults[5], ANVIL7, 40_000e6);
        _deposit(vaults[7], ANVIL8, 6_000e6);
        _deposit(vaults[8], ANVIL9, 18_000e6);
        _deposit(vaults[9], ANVIL3, 22_000e6);
        _deposit(vaults[10], ANVIL4, 30_000e6);
        _deposit(vaults[12], ANVIL5, 16_000e6);
        _deposit(vaults[13], ANVIL6, 20_000e6);
        _deposit(vaults[14], ANVIL7, 35_000e6);
        _deposit(vaults[15], ANVIL8, 14_000e6);
    }

    function _deposit(address vault, address depositor, uint256 amount) internal {
        vm.startBroadcast(depositor);
        settlement.approve(vault, amount);
        uint256[] memory minAmountsOut = new uint256[](0);
        EquiVault(vault)
            .enter(
                EquiVault.EnterParams({
                settlementIn: amount,
                receiver: depositor,
                minSharesOut: 0,
                minAmountsOut: minAmountsOut,
                deadline: block.timestamp + 1 days,
                proposalId: 0
            })
            );
        vm.stopBroadcast();
    }

    function _createPendingProposals(address[16] memory vaults) internal {
        vm.startBroadcast(ANVIL4);
        EquiVault(vaults[7]).proposeParameters(450, 100);
        vm.stopBroadcast();
        vm.startBroadcast(ANVIL7);
        EquiVault(vaults[12]).proposeParameters(450, 100);
        vm.stopBroadcast();
    }

    function _one(uint8 a) internal pure returns (uint8[] memory result) {
        result = new uint8[](1);
        result[0] = a;
    }

    function _two(uint8 a, uint8 b) internal pure returns (uint8[] memory result) {
        result = new uint8[](2);
        result[0] = a;
        result[1] = b;
    }

    function _three(uint8 a, uint8 b, uint8 c) internal pure returns (uint8[] memory result) {
        result = new uint8[](3);
        result[0] = a;
        result[1] = b;
        result[2] = c;
    }

    function _five(uint8 a, uint8 b, uint8 c, uint8 d, uint8 e) internal pure returns (uint8[] memory result) {
        result = new uint8[](5);
        result[0] = a;
        result[1] = b;
        result[2] = c;
        result[3] = d;
        result[4] = e;
    }

    function _weights1() internal pure returns (uint16[] memory result) {
        result = new uint16[](1);
        result[0] = 10_000;
    }

    function _weights2(uint16 a, uint16 b) internal pure returns (uint16[] memory result) {
        result = new uint16[](2);
        result[0] = a;
        result[1] = b;
    }

    function _weights3(uint16 a, uint16 b, uint16 c) internal pure returns (uint16[] memory result) {
        result = new uint16[](3);
        result[0] = a;
        result[1] = b;
        result[2] = c;
    }

    function _weights5(uint16 a, uint16 b, uint16 c, uint16 d, uint16 e)
        internal
        pure
        returns (uint16[] memory result)
    {
        result = new uint16[](5);
        result[0] = a;
        result[1] = b;
        result[2] = c;
        result[3] = d;
        result[4] = e;
    }
}
