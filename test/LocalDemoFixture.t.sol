// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {AssetRegistry} from "../src/AssetRegistry.sol";
import {EquiVault} from "../src/EquiVault.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {MockOracle, MockPool, MockToken} from "./mocks/Mocks.sol";
import {NamedMockToken} from "../script/LocalDemoTokens.sol";
import {SeedLocalDemo} from "../script/SeedLocalDemo.s.sol";

/// @notice Regression coverage for the local rich-demo fixture's two deliberate invariants:
/// eight usable demo assets and at most five assets in a single protocol basket.
contract LocalDemoFixtureTest is Test {
    uint48 internal constant MAX_PRICE_AGE = 1 hours;

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal manager = makeAddr("manager");
    MockToken internal settlement;
    AssetRegistry internal registry;
    VaultFactory internal factory;
    address[8] internal assets;

    address internal constant ANVIL0 = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address internal constant ANVIL1 = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address internal constant ANVIL2 = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
    address internal constant ANVIL3 = 0x90F79bf6EB2c4f870365E785982E1f101E93b906;
    address internal constant ANVIL4 = 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65;
    address internal constant ANVIL5 = 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc;
    address internal constant ANVIL6 = 0x976EA74026E726554dB657fA54763abd0C3a0aa9;
    address internal constant ANVIL7 = 0x14dC79964da2C08b23698B3D3cc7Ca32193d9955;
    address internal constant ANVIL8 = 0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f;
    address internal constant ANVIL9 = 0xa0Ee7A142d267C1f36714E4a8F75612F20a79720;

    function setUp() public {
        settlement = new MockToken(6);
        registry = new AssetRegistry(admin, treasury);
        factory = new VaultFactory(settlement, registry);

        assets[0] = _register("Demo Ether", "ETH", 18, 2_500e18);
        assets[1] = _register("Demo Bitcoin", "BTC", 8, 65_000e18);
        assets[2] = _register("Demo Solana", "SOL", 9, 150e18);
        assets[3] = _register("Demo Avalanche", "AVAX", 18, 40e18);
        assets[4] = _register("Demo Chainlink", "LINK", 18, 15e18);
        assets[5] = _register("Demo Uniswap", "UNI", 18, 10e18);
        assets[6] = _register("Demo Aave", "AAVE", 18, 250e18);
        assets[7] = _register("Demo Arbitrum", "ARB", 18, 75e16);
    }

    function testNamedTokensExposeOnchainTickerAndConfiguredDecimals() public view {
        assertEq(NamedMockToken(assets[0]).name(), "Demo Ether");
        assertEq(NamedMockToken(assets[0]).symbol(), "ETH");
        assertEq(NamedMockToken(assets[0]).decimals(), 18);
        assertEq(NamedMockToken(assets[1]).name(), "Demo Bitcoin");
        assertEq(NamedMockToken(assets[1]).symbol(), "BTC");
        assertEq(NamedMockToken(assets[1]).decimals(), 8);
    }

    function testFixtureSupportsOneTwoThreeAndFiveAssetVaults() public {
        address one = _create(_basket(1), _weights(1));
        address two = _create(_basket(2), _weights(2));
        address three = _create(_basket(3), _weights(3));
        address five = _create(_basket(5), _weights(5));

        assertEq(EquiVault(one).basketAssets().length, 1);
        assertEq(EquiVault(two).basketAssets().length, 2);
        assertEq(EquiVault(three).basketAssets().length, 3);
        assertEq(EquiVault(five).basketAssets().length, 5);
        assertEq(factory.vaultCount(), 4);
    }

    function testEightAssetBasketRemainsRejectedWhileEightAssetsAreRegistered() public {
        for (uint256 i = 0; i < assets.length; ++i) {
            assertTrue(registry.canOpenExposure(assets[i]));
        }

        vm.expectRevert(abi.encodeWithSelector(EquiVault.InvalidBasketSize.selector, uint256(8)));
        _create(_basket(8), _weights(8));
    }

    function testSeedScriptCreatesTheCompleteRichFixture() public {
        vm.chainId(31337);
        vm.warp(1_000_000);

        MockToken demoSettlement = new NamedMockToken("Demo USDG", "USDG", 6);
        NamedMockToken demoEth = new NamedMockToken("Demo Ether", "ETH", 18);
        NamedMockToken demoBtc = new NamedMockToken("Demo Bitcoin", "BTC", 8);
        AssetRegistry demoRegistry = new AssetRegistry(ANVIL0, ANVIL2);
        VaultFactory demoFactory = new VaultFactory(demoSettlement, demoRegistry);
        _registerBaselineAsset(demoSettlement, demoRegistry, demoEth, 2_500e18, 20_000e18);
        _registerBaselineAsset(demoSettlement, demoRegistry, demoBtc, 65_000e18, 769_230_76923);
        _fundCanonicalAccounts(demoSettlement);

        address[] memory baselineAssets = new address[](2);
        baselineAssets[0] = address(demoEth);
        baselineAssets[1] = address(demoBtc);
        uint16[] memory baselineWeights = new uint16[](2);
        baselineWeights[0] = 6_000;
        baselineWeights[1] = 4_000;
        vm.prank(ANVIL0);
        demoFactory.createVault(
            ANVIL1,
            baselineAssets,
            baselineWeights,
            1_000,
            300,
            EquiVault.TimelockMode.Delayed,
            1 days,
            0,
            0
        );

        vm.setEnv("DEMO_SETTLEMENT", vm.toString(address(demoSettlement)));
        vm.setEnv("DEMO_REGISTRY", vm.toString(address(demoRegistry)));
        vm.setEnv("DEMO_FACTORY", vm.toString(address(demoFactory)));
        vm.setEnv("DEMO_TOKEN_A", vm.toString(address(demoEth)));
        vm.setEnv("DEMO_TOKEN_B", vm.toString(address(demoBtc)));
        new SeedLocalDemo().run();

        assertEq(demoSettlement.name(), "Demo USDG");
        assertEq(demoSettlement.symbol(), "USDG");
        assertEq(demoSettlement.decimals(), 6);
        assertEq(demoFactory.vaultCount(), 17);
        uint256 funded;
        bool hasOne;
        bool hasTwo;
        bool hasThree;
        bool hasFive;
        for (uint256 i = 1; i < 17; ++i) {
            EquiVault vault = EquiVault(demoFactory.vaults(i));
            uint256 size = vault.basketAssets().length;
            assertTrue(size >= 1 && size <= 5);
            if (size == 1) hasOne = true;
            if (size == 2) hasTwo = true;
            if (size == 3) hasThree = true;
            if (size == 5) hasFive = true;
            if (vault.totalSupply() != 0) ++funded;
        }
        assertTrue(hasOne && hasTwo && hasThree && hasFive);
        assertEq(funded, 13);
        address sol = EquiVault(demoFactory.vaults(4)).basketAssets()[2];
        assertGt(demoRegistry.assetConfig(sol).maxPriceAge, 0);
        assertGt(EquiVault(demoFactory.vaults(8)).activeParameterProposal().id, 0);
        assertGt(EquiVault(demoFactory.vaults(13)).activeParameterProposal().id, 0);
    }

    function _registerBaselineAsset(
        MockToken demoSettlement,
        AssetRegistry demoRegistry,
        NamedMockToken token,
        uint256 price,
        uint256 liquidity
    ) internal {
        MockOracle primary = new MockOracle();
        MockOracle secondary = new MockOracle();
        MockPool pool = new MockPool(demoSettlement, token, 30);
        primary.setPrice(price, block.timestamp);
        secondary.setPrice(price - 1e18, block.timestamp);
        vm.startPrank(ANVIL0);
        demoRegistry.registerAsset(address(token), primary, secondary, address(pool), MAX_PRICE_AGE);
        demoSettlement.mint(ANVIL0, 50_000_000e6);
        token.mint(ANVIL0, liquidity);
        demoSettlement.approve(address(pool), type(uint256).max);
        token.approve(address(pool), type(uint256).max);
        pool.seed(50_000_000e6, liquidity);
        vm.stopPrank();
    }

    function _fundCanonicalAccounts(MockToken demoSettlement) internal {
        demoSettlement.mint(ANVIL0, 1_000_000e6);
        demoSettlement.mint(ANVIL1, 1_000_000e6);
        demoSettlement.mint(ANVIL2, 1_000_000e6);
        demoSettlement.mint(ANVIL3, 1_000_000e6);
        demoSettlement.mint(ANVIL4, 1_000_000e6);
        demoSettlement.mint(ANVIL5, 1_000_000e6);
        demoSettlement.mint(ANVIL6, 1_000_000e6);
        demoSettlement.mint(ANVIL7, 1_000_000e6);
        demoSettlement.mint(ANVIL8, 1_000_000e6);
        demoSettlement.mint(ANVIL9, 1_000_000e6);
    }

    function _register(string memory name, string memory symbol, uint8 decimals, uint256 price)
        internal
        returns (address)
    {
        NamedMockToken token = new NamedMockToken(name, symbol, decimals);
        MockOracle primary = new MockOracle();
        MockOracle secondary = new MockOracle();
        MockPool pool = new MockPool(settlement, token, 30);
        primary.setPrice(price, block.timestamp);
        secondary.setPrice(price - 1, block.timestamp);
        vm.prank(admin);
        registry.registerAsset(address(token), primary, secondary, address(pool), MAX_PRICE_AGE);
        return address(token);
    }

    function _create(address[] memory basket, uint16[] memory weights) internal returns (address) {
        return factory.createVault(
            manager, basket, weights, 1_000, 300, EquiVault.TimelockMode.Delayed, 1 days, 0, 0
        );
    }

    function _basket(uint256 length) internal view returns (address[] memory basket) {
        basket = new address[](length);
        for (uint256 i = 0; i < length; ++i) {
            basket[i] = assets[i];
        }
    }

    function _weights(uint256 length) internal pure returns (uint16[] memory weights) {
        weights = new uint16[](length);
        if (length == 1) {
            weights[0] = 10_000;
            return weights;
        }
        if (length == 2) {
            weights[0] = 5_000;
            weights[1] = 5_000;
            return weights;
        }
        if (length == 3) {
            weights[0] = 3_334;
            weights[1] = 3_333;
            weights[2] = 3_333;
            return weights;
        }
        if (length == 5) {
            for (uint256 i = 0; i < length; ++i) {
                weights[i] = 2_000;
            }
            return weights;
        }
        if (length == 8) {
            for (uint256 i = 0; i < length; ++i) {
                weights[i] = 1_250;
            }
            return weights;
        }
        revert("unsupported test basket size");
    }
}
