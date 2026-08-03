// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {AssetRegistry} from "../src/AssetRegistry.sol";

import {MockOracle, MockToken} from "./mocks/Mocks.sol";

contract AssetRegistryTest is Test {
    uint48 internal constant MAX_PRICE_AGE = 1 hours;
    uint256 internal constant EXPOSURE_CAP = 1_000_000e18;

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal nextAdmin = makeAddr("nextAdmin");
    address internal nextTreasury = makeAddr("nextTreasury");
    address internal quote = makeAddr("usdc");
    address internal route = makeAddr("dexRoute");

    AssetRegistry internal registry;
    MockToken internal asset;
    MockOracle internal primary;
    MockOracle internal fallbackOracle;

    function setUp() public {
        vm.warp(1_000_000);
        registry = new AssetRegistry(admin, treasury);
        asset = new MockToken(6);
        primary = new MockOracle();
        fallbackOracle = new MockOracle();
        primary.setPrice(2e18, block.timestamp);
        fallbackOracle.setPrice(19e17, block.timestamp);

        vm.prank(admin);
        registry.registerAsset(address(asset), primary, fallbackOracle, route, EXPOSURE_CAP, MAX_PRICE_AGE);
    }

    function testRegistersValidatedAssetConfig() public view {
        AssetRegistry.AssetConfig memory config = registry.assetConfig(address(asset));

        assertEq(address(config.primaryOracle), address(primary));
        assertEq(address(config.fallbackOracle), address(fallbackOracle));
        assertEq(config.liquidityRoute, route);
        assertEq(config.exposureCapE18, EXPOSURE_CAP);
        assertEq(config.maxPriceAge, MAX_PRICE_AGE);
        assertEq(config.decimals, 6);
        assertEq(uint256(config.status), uint256(AssetRegistry.AssetStatus.Active));
    }

    function testRejectsNonTokenAsset() public {
        vm.expectRevert(abi.encodeWithSelector(AssetRegistry.InvalidToken.selector, address(this)));
        vm.prank(admin);
        registry.registerAsset(address(this), primary, fallbackOracle, route, EXPOSURE_CAP, MAX_PRICE_AGE);
    }

    function testResolvesFallbackPriceWithoutStoringIt() public {
        primary.setFails(true);

        (uint256 price, uint256 updatedAt) = registry.getPrice(address(asset), quote);

        assertEq(price, 19e17);
        assertEq(updatedAt, block.timestamp);
    }

    function testRejectsWhenBothOraclesAreInvalid() public {
        primary.setPrice(2e18, block.timestamp - MAX_PRICE_AGE - 1);
        fallbackOracle.setFails(true);

        vm.expectRevert(abi.encodeWithSelector(AssetRegistry.PriceUnavailable.selector, address(asset), quote));
        registry.getPrice(address(asset), quote);
    }

    function testExposureCapBoundsVaultAumAndCanBeLowered() public {
        assertEq(registry.maxVaultAum(address(asset), 2_000), 5_000_000e18);

        vm.prank(admin);
        registry.setExposureCap(address(asset), 400_000e18);

        assertEq(registry.maxVaultAum(address(asset), 2_000), 2_000_000e18);
    }

    function testExitOnlyQuarantineAndPauseBlockNewExposureButAllowExits() public {
        assertTrue(registry.canOpenExposure(address(asset)));
        assertTrue(registry.canExit(address(asset)));

        vm.startPrank(admin);
        registry.setAssetStatus(address(asset), AssetRegistry.AssetStatus.ExitOnly);
        vm.stopPrank();
        assertFalse(registry.canOpenExposure(address(asset)));
        assertTrue(registry.canExit(address(asset)));

        vm.prank(admin);
        registry.setAssetStatus(address(asset), AssetRegistry.AssetStatus.Quarantined);
        assertFalse(registry.canOpenExposure(address(asset)));
        assertTrue(registry.canExit(address(asset)));

        vm.startPrank(admin);
        registry.setAssetStatus(address(asset), AssetRegistry.AssetStatus.Active);
        registry.setDepositsPaused(true);
        vm.stopPrank();
        assertFalse(registry.canOpenExposure(address(asset)));
        assertTrue(registry.canExit(address(asset)));
    }

    function testOnlyAdminCanMutateAssetConfig() public {
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        registry.setExposureCap(address(asset), EXPOSURE_CAP / 2);
    }

    function testAdminRotationNeedsDelayAndAcceptance() public {
        vm.prank(admin);
        registry.beginDefaultAdminTransfer(nextAdmin);

        vm.expectRevert();
        vm.prank(nextAdmin);
        registry.acceptDefaultAdminTransfer();

        vm.warp(block.timestamp + registry.ADMIN_TRANSFER_DELAY() + 1);
        vm.prank(nextAdmin);
        registry.acceptDefaultAdminTransfer();

        vm.prank(admin);
        vm.expectRevert();
        registry.setExposureCap(address(asset), EXPOSURE_CAP / 2);

        vm.prank(nextAdmin);
        registry.setExposureCap(address(asset), EXPOSURE_CAP / 2);
    }

    function testTreasuryRotationNeedsSevenDayNotice() public {
        vm.prank(admin);
        registry.proposeTreasury(nextTreasury);

        vm.expectRevert(
            abi.encodeWithSelector(AssetRegistry.TreasuryTransferNotReady.selector, uint48(block.timestamp + 7 days))
        );
        registry.executeTreasuryTransfer();

        vm.warp(block.timestamp + 7 days);
        registry.executeTreasuryTransfer();

        assertEq(registry.treasury(), nextTreasury);
        assertEq(registry.pendingTreasury(), address(0));
        assertEq(registry.pendingTreasuryExecutableAt(), 0);
    }
}
