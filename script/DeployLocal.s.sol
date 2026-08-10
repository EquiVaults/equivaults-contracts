// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";

import {AssetRegistry} from "../src/AssetRegistry.sol";
import {EquiVault} from "../src/EquiVault.sol";
import {RebalanceEngine} from "../src/RebalanceEngine.sol";
import {VaultFactory} from "../src/VaultFactory.sol";

import {MockOracle, MockPool, MockToken} from "../test/mocks/Mocks.sol";

/// @notice Deploys a self-contained local dev environment on Anvil (chainId 31337):
/// mock settlement token (6 decimals, USDG-like), two basket assets with oracle + liquidity
/// route, the registry, the vault factory, one example vault, the rebalance engine, and a
/// funded set of well-known Anvil accounts for frontend testing.
/// @dev Run against a fresh default Anvil instance (default mnemonic, chainId 31337):
///      anvil --chain-id 31337
///      forge script script/DeployLocal.s.sol --rpc-url http://127.0.0.1:8545 \
///        --broadcast --unlocked --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
///      Every call is a broadcast tx signed by the sender, which is also the registry admin:
///      permissioned setup (registerAsset) and pool seeding work because msg.sender == ANVIL0.
///      The script writes `deployments/31337/addresses.json` (committed for the frontend).
contract DeployLocal is Script {
    uint48 internal constant MAX_PRICE_AGE = 1 hours;
    uint256 internal constant PRICE_A = 100e18; // $100 per whole token
    uint256 internal constant PRICE_B = 50e18; // $50 per whole token
    uint256 internal constant EXPOSURE_CAP = 1_000_000e18; // registry ceiling per asset (USD, 1e18)

    // Canonical Anvil default accounts ("test test test test test test test test test test test junk").
    address internal constant ANVIL0 = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266; // broadcaster / registry admin
    address internal constant ANVIL1 = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8; // vault manager
    address internal constant ANVIL2 = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC; // treasury
    address internal constant ANVIL3 = 0x90F79bf6EB2c4f870365E785982E1f101E93b906; // test depositor
    address internal constant ANVIL4 = 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65;
    address internal constant ANVIL5 = 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc;
    address internal constant ANVIL6 = 0x976EA74026E726554dB657fA54763abd0C3a0aa9;
    address internal constant ANVIL7 = 0x14dC79964da2C08b23698B3D3cc7Ca32193d9955;
    address internal constant ANVIL8 = 0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f;
    address internal constant ANVIL9 = 0xa0Ee7A142d267C1f36714E4a8F75612F20a79720;

    MockToken internal settlement; // 6 decimals, USDG-like
    MockToken internal tokenA; // 18 decimals
    MockToken internal tokenB; // 6 decimals
    MockOracle internal primaryA;
    MockOracle internal fallbackA;
    MockOracle internal primaryB;
    MockOracle internal fallbackB;
    MockPool internal poolA;
    MockPool internal poolB;
    AssetRegistry internal registry;
    VaultFactory internal factory;
    RebalanceEngine internal engine;
    address internal exampleVault;

    function run() public {
        require(block.chainid == 31337, "DeployLocal: expected Anvil chainId 31337");

        vm.startBroadcast();

        // --- Tokens ---
        settlement = new MockToken(6);
        tokenA = new MockToken(18);
        tokenB = new MockToken(6);

        // --- Oracles ---
        primaryA = new MockOracle();
        fallbackA = new MockOracle();
        primaryB = new MockOracle();
        fallbackB = new MockOracle();
        primaryA.setPrice(PRICE_A, block.timestamp);
        fallbackA.setPrice(99e18, block.timestamp);
        primaryB.setPrice(PRICE_B, block.timestamp);
        fallbackB.setPrice(49e18, block.timestamp);

        // --- Liquidity routes (constant-product pools) ---
        poolA = new MockPool(settlement, tokenA, 30);
        poolB = new MockPool(settlement, tokenB, 30);

        // --- Registry (admin = ANVIL0, the broadcast sender) ---
        registry = new AssetRegistry(ANVIL0, ANVIL2);
        registry.registerAsset(address(tokenA), primaryA, fallbackA, address(poolA), EXPOSURE_CAP, MAX_PRICE_AGE);
        registry.registerAsset(address(tokenB), primaryB, fallbackB, address(poolB), EXPOSURE_CAP, MAX_PRICE_AGE);

        // --- Factory + example vault + rebalance engine ---
        factory = new VaultFactory(settlement, registry);
        exampleVault = factory.createVault(
            ANVIL1,
            _assetsAB(),
            _weightsAB(),
            1_000, // feeBps 10 %
            300, // maxSlippageBps 3 %
            EquiVault.TimelockMode.Delayed,
            1 days,
            1_000_000e6, // capAum
            0, // driftThresholdBps -> protocol default (300)
            0 // rebalanceSlippageBps -> protocol default (100)
        );
        engine = new RebalanceEngine();

        // --- Seed pools (funds held by ANVIL0, the msg.sender of every broadcast tx) ---
        settlement.mint(ANVIL0, 20_000_000e6);
        tokenA.mint(ANVIL0, 100_000e18);
        tokenB.mint(ANVIL0, 200_000e6);
        settlement.approve(address(poolA), type(uint256).max);
        settlement.approve(address(poolB), type(uint256).max);
        tokenA.approve(address(poolA), type(uint256).max);
        tokenB.approve(address(poolB), type(uint256).max);
        poolA.seed(10_000_000e6, 100_000e18);
        poolB.seed(10_000_000e6, 200_000e6);

        // --- Fund every canonical Anvil account with settlement for frontend testing ---
        _fund(ANVIL0);
        _fund(ANVIL1);
        _fund(ANVIL2);
        _fund(ANVIL3);
        _fund(ANVIL4);
        _fund(ANVIL5);
        _fund(ANVIL6);
        _fund(ANVIL7);
        _fund(ANVIL8);
        _fund(ANVIL9);

        vm.stopBroadcast();

        console2.log("DeployLocal: environment deployed on chain", block.chainid);
        console2.log("  settlement ", address(settlement));
        console2.log("  tokenA     ", address(tokenA));
        console2.log("  tokenB     ", address(tokenB));
        console2.log("  registry   ", address(registry));
        console2.log("  factory    ", address(factory));
        console2.log("  vault      ", exampleVault);
        console2.log("  engine     ", address(engine));
    }

    function _assetsAB() internal view returns (address[] memory a) {
        a = new address[](2);
        a[0] = address(tokenA);
        a[1] = address(tokenB);
    }

    function _weightsAB() internal pure returns (uint16[] memory w) {
        w = new uint16[](2);
        w[0] = 6_000;
        w[1] = 4_000;
    }

    function _fund(address who) internal {
        settlement.mint(who, 1_000_000e6);
    }
}
