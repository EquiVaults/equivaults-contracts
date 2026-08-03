// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {
    AccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPriceOracle} from "./interfaces/IPriceOracle.sol";

/// @notice Protocol-wide catalogue of assets that vaults may use.
/// @dev The default admin attests asset compatibility off-chain; this contract enforces configured limits and states.
contract AssetRegistry is AccessControlDefaultAdminRules {
    uint48 public constant ADMIN_TRANSFER_DELAY = 7 days;
    uint16 public constant BPS_DENOMINATOR = 10_000;

    enum AssetStatus {
        None,
        Active,
        ExitOnly,
        Quarantined
    }

    struct AssetConfig {
        IPriceOracle primaryOracle;
        IPriceOracle fallbackOracle;
        address liquidityRoute;
        uint256 exposureCapE18;
        uint48 maxPriceAge;
        uint8 decimals;
        AssetStatus status;
    }

    error AssetAlreadyRegistered(address asset);
    error AssetNotRegistered(address asset);
    error InvalidAddress();
    error InvalidExposureCap();
    error InvalidPriceAge();
    error InvalidWeight(uint16 weightBps);
    error InvalidAssetStatus(AssetStatus status);
    error InvalidToken(address asset);
    error PriceUnavailable(address asset, address quote);
    error TreasuryTransferNotReady(uint48 executableAt);

    event AssetRegistered(
        address indexed asset,
        address indexed primaryOracle,
        address indexed fallbackOracle,
        address liquidityRoute,
        uint256 exposureCapE18,
        uint48 maxPriceAge,
        uint8 decimals
    );
    event AssetStatusUpdated(address indexed asset, AssetStatus status);
    event ExposureCapUpdated(address indexed asset, uint256 exposureCapE18);
    event DepositsPauseUpdated(bool paused);
    event TreasuryTransferProposed(address indexed treasury, uint48 executableAt);
    event TreasuryTransferExecuted(address indexed previousTreasury, address indexed newTreasury);
    event TreasuryTransferCancelled();

    mapping(address asset => AssetConfig config) private _assets;

    address public treasury;
    address public pendingTreasury;
    uint48 public pendingTreasuryExecutableAt;
    bool public depositsPaused;

    constructor(address initialAdmin, address initialTreasury)
        AccessControlDefaultAdminRules(ADMIN_TRANSFER_DELAY, initialAdmin)
    {
        if (initialTreasury == address(0)) revert InvalidAddress();
        treasury = initialTreasury;
    }

    function registerAsset(
        address asset,
        IPriceOracle primaryOracle,
        IPriceOracle fallbackOracle,
        address liquidityRoute,
        uint256 exposureCapE18,
        uint48 maxPriceAge
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_assets[asset].status != AssetStatus.None) revert AssetAlreadyRegistered(asset);
        if (
            asset == address(0) || address(primaryOracle) == address(0) || address(fallbackOracle) == address(0)
                || liquidityRoute == address(0)
        ) revert InvalidAddress();
        if (asset.code.length == 0) revert InvalidToken(asset);
        if (exposureCapE18 == 0) revert InvalidExposureCap();
        if (maxPriceAge == 0) revert InvalidPriceAge();

        uint8 decimals;
        try IERC20Metadata(asset).decimals() returns (uint8 tokenDecimals) {
            decimals = tokenDecimals;
        } catch {
            revert InvalidToken(asset);
        }
        if (decimals > 18) revert InvalidToken(asset);

        _assets[asset] = AssetConfig({
            primaryOracle: primaryOracle,
            fallbackOracle: fallbackOracle,
            liquidityRoute: liquidityRoute,
            exposureCapE18: exposureCapE18,
            maxPriceAge: maxPriceAge,
            decimals: decimals,
            status: AssetStatus.Active
        });

        emit AssetRegistered(
            asset,
            address(primaryOracle),
            address(fallbackOracle),
            liquidityRoute,
            exposureCapE18,
            maxPriceAge,
            decimals
        );
    }

    function assetConfig(address asset) external view returns (AssetConfig memory) {
        AssetConfig memory config = _assets[asset];
        if (config.status == AssetStatus.None) revert AssetNotRegistered(asset);
        return config;
    }

    function setAssetStatus(address asset, AssetStatus status) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _requireRegistered(asset);
        if (status == AssetStatus.None) revert InvalidAssetStatus(status);
        _assets[asset].status = status;
        emit AssetStatusUpdated(asset, status);
    }

    function setExposureCap(address asset, uint256 exposureCapE18) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _requireRegistered(asset);
        if (exposureCapE18 == 0) revert InvalidExposureCap();
        _assets[asset].exposureCapE18 = exposureCapE18;
        emit ExposureCapUpdated(asset, exposureCapE18);
    }

    function setDepositsPaused(bool paused) external onlyRole(DEFAULT_ADMIN_ROLE) {
        depositsPaused = paused;
        emit DepositsPauseUpdated(paused);
    }

    function canOpenExposure(address asset) external view returns (bool) {
        return !depositsPaused && _assets[asset].status == AssetStatus.Active;
    }

    function canExit(address asset) external view returns (bool) {
        AssetStatus status = _assets[asset].status;
        return status == AssetStatus.Active || status == AssetStatus.ExitOnly || status == AssetStatus.Quarantined;
    }

    function maxVaultAum(address asset, uint16 weightBps) external view returns (uint256) {
        _requireRegistered(asset);
        if (weightBps == 0 || weightBps > BPS_DENOMINATOR) revert InvalidWeight(weightBps);
        return Math.mulDiv(_assets[asset].exposureCapE18, BPS_DENOMINATOR, weightBps);
    }

    /// @notice Resolves a live price without writing it to storage.
    function getPrice(address asset, address quote) external view returns (uint256 priceE18, uint256 updatedAt) {
        AssetConfig storage config = _assets[asset];
        if (config.status == AssetStatus.None) revert AssetNotRegistered(asset);
        if (quote == address(0)) revert InvalidAddress();

        try config.primaryOracle.getPrice(asset, quote) returns (uint256 price, uint256 timestamp) {
            if (_isFreshPrice(price, timestamp, config.maxPriceAge)) return (price, timestamp);
        } catch {}

        try config.fallbackOracle.getPrice(asset, quote) returns (uint256 price, uint256 timestamp) {
            if (_isFreshPrice(price, timestamp, config.maxPriceAge)) return (price, timestamp);
        } catch {}

        revert PriceUnavailable(asset, quote);
    }

    function proposeTreasury(address newTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newTreasury == address(0)) revert InvalidAddress();
        pendingTreasury = newTreasury;
        pendingTreasuryExecutableAt = uint48(block.timestamp) + ADMIN_TRANSFER_DELAY;
        emit TreasuryTransferProposed(newTreasury, pendingTreasuryExecutableAt);
    }

    function executeTreasuryTransfer() external {
        uint48 executableAt = pendingTreasuryExecutableAt;
        if (executableAt == 0 || block.timestamp < executableAt) revert TreasuryTransferNotReady(executableAt);

        address previousTreasury = treasury;
        treasury = pendingTreasury;
        delete pendingTreasury;
        delete pendingTreasuryExecutableAt;
        emit TreasuryTransferExecuted(previousTreasury, treasury);
    }

    function cancelTreasuryTransfer() external onlyRole(DEFAULT_ADMIN_ROLE) {
        delete pendingTreasury;
        delete pendingTreasuryExecutableAt;
        emit TreasuryTransferCancelled();
    }

    function _requireRegistered(address asset) private view {
        if (_assets[asset].status == AssetStatus.None) revert AssetNotRegistered(asset);
    }

    function _isFreshPrice(uint256 price, uint256 updatedAt, uint48 maxPriceAge) private view returns (bool) {
        return price != 0 && updatedAt <= block.timestamp && block.timestamp - updatedAt <= maxPriceAge;
    }
}
