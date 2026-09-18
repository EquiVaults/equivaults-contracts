// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {AssetRegistry} from "./AssetRegistry.sol";
import {IAsyncVault} from "./interfaces/IAsyncVault.sol";
import {ISwapRouter} from "./interfaces/ISwapRouter.sol";

/// @notice Per-vault compartment for progressive investments.
/// @dev Request balances are accounting credits, never inferred from this contract's token balances.
/// Donations consequently cannot be assigned to a request or included in the vault's shared NAV.
contract InvestmentEscrow is ReentrancyGuard {
    using Math for uint256;
    using SafeERC20 for IERC20;

    /// @notice Protocol release implemented by escrow instances deployed from this source.
    function protocolVersion() public pure returns (uint256) {
        return 2;
    }

    uint16 internal constant BPS_DENOMINATOR = 10_000;

    enum RequestStatus {
        Open,
        Stopped,
        Closed
    }

    struct Request {
        address owner;
        bytes32 version;
        uint256 sequence;
        RequestStatus status;
        uint256 deposited;
        uint256 available;
        uint256 spent;
        uint256 refunded;
        uint256 integratedCost;
        uint256 shares;
    }

    /// @dev Cost is the settlement input spent to acquire the still-personal token quantity.
    struct Position {
        uint256 quantity;
        uint256 cost;
    }

    IAsyncVault public immutable vault;
    IERC20 public immutable settlement;
    AssetRegistry public immutable registry;

    uint256 public nextRequestId = 1;
    mapping(uint256 requestId => Request request) private _requests;
    mapping(uint256 requestId => address[] assets) private _requestAssets;
    mapping(uint256 requestId => mapping(address token => Position position)) private _positions;

    error UnknownRequest(uint256 requestId);
    error NotRequestOwner(address caller, address owner);
    error InvalidAmount();
    error RequestNotOpen(uint256 requestId, RequestStatus actual);
    error RequestNotStopped(uint256 requestId, RequestStatus actual);
    error RequestVersionMismatch(bytes32 expected, bytes32 actual);
    error SequenceMismatch(uint256 expected, uint256 actual);
    error DeadlineExpired(uint256 deadline);
    error AssetNotOpen(address asset);
    error InvalidAssetIndex(uint256 index);
    error InsufficientAvailable(uint256 available, uint256 requested);
    error EmptyPosition(uint256 requestId, address asset);
    error ZeroMinOut(address asset, uint256 amountIn);
    error RouteSpentUnexpected(uint256 expected, uint256 actual);
    error RouteOutputBelowMinimum(address asset, uint256 minimum, uint256 actual);
    error FillExceedsLegBudget(uint256 requestId, uint256 index, uint256 requested, uint256 maximum);
    error SharedBasketHasNoValue();
    error BasketLengthMismatch(uint256 assets, uint256 weights);
    error InexactTokenTransfer(address token, uint256 expected, uint256 senderDelta, uint256 recipientDelta);
    error PreviewLengthMismatch(uint256 expected, uint256 actual);
    error NoIntegrableTranche(uint256 requestId);
    error VaultPullMismatch(address asset, uint256 expected, uint256 actual);
    error IntegrationSharesMismatch(uint256 previewed, uint256 actual);

    event RequestCreated(
        uint256 indexed requestId, address indexed owner, bytes32 indexed version, uint256 deposited, address[] assets
    );
    event RequestFilled(
        uint256 indexed requestId,
        uint256 indexed index,
        address indexed asset,
        address route,
        uint256 sequence,
        uint256 spent,
        uint256 priceE18,
        uint256 minOut,
        uint256 actualOut
    );
    event RequestIntegrated(
        uint256 indexed requestId,
        address indexed owner,
        uint256 sequence,
        uint256 acquisitionCost,
        uint256 valueReceived,
        uint256 shares,
        uint256[] amounts
    );
    event RequestStopped(uint256 indexed requestId, address indexed owner, uint256 refunded);
    event PositionClaimed(
        uint256 indexed requestId, address indexed owner, address indexed asset, uint256 quantity, uint256 cost
    );
    event RequestClosed(uint256 indexed requestId, address indexed owner);

    constructor(address vault_, IERC20 settlement_, AssetRegistry registry_) {
        if (vault_ == address(0) || address(settlement_) == address(0) || address(registry_) == address(0)) {
            revert InvalidAmount();
        }
        vault = IAsyncVault(vault_);
        settlement = settlement_;
        registry = registry_;
    }

    function getRequest(uint256 requestId) external view returns (Request memory) {
        return _request(requestId);
    }

    function requestAssets(uint256 requestId) external view returns (address[] memory) {
        _request(requestId);
        return _requestAssets[requestId];
    }

    function positions(uint256 requestId, address token) external view returns (uint256 quantity, uint256 cost) {
        _request(requestId);
        Position storage position = _positions[requestId][token];
        return (position.quantity, position.cost);
    }

    /// @notice Current maximum settlement input for one basket leg under this request's personal budget.
    /// @dev Off-chain sponsors can read this exact protocol bound before preparing a permissionless fill.
    function maxFillAmount(uint256 requestId, uint256 index) external view returns (uint256) {
        Request storage request = _request(requestId);
        if (request.status != RequestStatus.Open) revert RequestNotOpen(requestId, request.status);
        bytes32 currentVersion = vault.investmentVersion();
        if (request.version != currentVersion) revert RequestVersionMismatch(request.version, currentVersion);
        address[] storage assets = _requestAssets[requestId];
        if (index >= assets.length) revert InvalidAssetIndex(index);
        address asset = assets[index];
        if (!registry.canOpenExposure(asset)) revert AssetNotOpen(asset);
        (uint256 price,) = registry.getPrice(asset, address(settlement));
        return _maxFillAmount(requestId, index, request, price);
    }

    /// @notice Deposits exact settlement units and freezes the current basket/version into a request.
    /// @dev There are deliberately no oracle or route calls here: a temporarily unavailable route cannot block recovery.
    function createRequest(uint256 amount, bytes32 expectedVersion, uint256 deadline)
        external
        nonReentrant
        returns (uint256 requestId)
    {
        if (deadline < block.timestamp) revert DeadlineExpired(deadline);
        if (amount == 0) revert InvalidAmount();

        bytes32 currentVersion = vault.investmentVersion();
        if (expectedVersion != currentVersion) revert RequestVersionMismatch(expectedVersion, currentVersion);

        address[] memory assets = vault.basketAssets();
        uint256 n = assets.length;
        for (uint256 i = 0; i < n; ++i) {
            if (!registry.canOpenExposure(assets[i])) revert AssetNotOpen(assets[i]);
        }

        requestId = nextRequestId++;
        Request storage request = _requests[requestId];
        request.owner = msg.sender;
        request.version = currentVersion;
        request.status = RequestStatus.Open;
        request.deposited = amount;
        request.available = amount;
        _requestAssets[requestId] = assets;

        _transferFromExact(settlement, msg.sender, amount);
        emit RequestCreated(requestId, msg.sender, currentVersion, amount, assets);
    }

    /// @notice Buys exactly one current request-basket asset through its registry route.
    /// @dev The actual token balance delta, not a route return value, is credited to the request.
    function fill(uint256 requestId, uint256 index, uint256 amount, uint256 expectedSequence, uint256 deadline)
        external
        nonReentrant
        returns (uint256 actualOut)
    {
        Request storage request = _openRequest(requestId, expectedSequence, deadline);
        if (amount == 0) revert InvalidAmount();
        if (amount > request.available) revert InsufficientAvailable(request.available, amount);

        address[] storage assets = _requestAssets[requestId];
        if (index >= assets.length) revert InvalidAssetIndex(index);
        address asset = assets[index];
        if (!registry.canOpenExposure(asset)) revert AssetNotOpen(asset);
        AssetRegistry.AssetConfig memory config = registry.assetConfig(asset);
        address route = config.liquidityRoute;

        (uint256 price,) = registry.getPrice(asset, address(settlement));
        uint256 maxAmount = _maxFillAmount(requestId, index, request, price);
        if (amount > maxAmount) revert FillExceedsLegBudget(requestId, index, amount, maxAmount);
        // Apply the slippage factor in the same rational operation as the quote. Two independent
        // floors would halve the effective bound for low-decimal assets (for example 2 -> 1).
        uint256 minOut = amount.mulDiv(
            (10 ** uint256(config.decimals)) * 1e18 * (BPS_DENOMINATOR - vault.maxSlippageBps()),
            price * (10 ** uint256(vault.settlementDecimals())) * BPS_DENOMINATOR,
            Math.Rounding.Ceil
        );
        if (minOut == 0) revert ZeroMinOut(asset, amount);

        uint256 settlementBefore = settlement.balanceOf(address(this));
        uint256 assetBefore = IERC20(asset).balanceOf(address(this));
        settlement.forceApprove(route, 0);
        settlement.forceApprove(route, amount);
        ISwapRouter(route).swapExactIn(address(settlement), asset, amount, minOut);
        settlement.forceApprove(route, 0);

        // A route can call arbitrary contracts. Re-check the consented composition before accepting
        // its result so a reallocation executed from that call cannot turn a stale fill into credit.
        bytes32 currentVersion = vault.investmentVersion();
        if (request.version != currentVersion) revert RequestVersionMismatch(request.version, currentVersion);

        uint256 settlementAfter = settlement.balanceOf(address(this));
        if (settlementAfter > settlementBefore) revert RouteSpentUnexpected(amount, 0);
        uint256 actualSpent = settlementBefore - settlementAfter;
        if (actualSpent != amount) revert RouteSpentUnexpected(amount, actualSpent);
        uint256 assetAfter = IERC20(asset).balanceOf(address(this));
        actualOut = assetAfter >= assetBefore ? assetAfter - assetBefore : 0;
        if (actualOut < minOut) revert RouteOutputBelowMinimum(asset, minOut, actualOut);

        request.available -= amount;
        request.spent += amount;
        Position storage position = _positions[requestId][asset];
        position.quantity += actualOut;
        position.cost += amount;
        unchecked {
            ++request.sequence;
        }
        emit RequestFilled(requestId, index, asset, route, request.sequence, amount, price, minOut, actualOut);
    }

    /// @notice Atomically transfers a complete proportional tranche to the vault and mints its shares to the owner.
    function integrate(uint256 requestId, uint256 expectedSequence) external nonReentrant returns (uint256 shares) {
        Request storage request = _openRequest(requestId, expectedSequence, type(uint256).max);
        address[] storage assets = _requestAssets[requestId];
        uint256 n = assets.length;
        uint256[] memory available = new uint256[](n);
        uint256[] memory balancesBefore = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            available[i] = _positions[requestId][assets[i]].quantity;
        }

        (uint256 previewShares, uint256[] memory amounts, uint256 valueReceived) = vault.previewInvestment(available);
        if (previewShares == 0) revert NoIntegrableTranche(requestId);
        if (amounts.length != n) revert PreviewLengthMismatch(n, amounts.length);

        uint256 totalCost;
        for (uint256 i = 0; i < n; ++i) {
            Position storage position = _positions[requestId][assets[i]];
            uint256 amount = amounts[i];
            if (amount > position.quantity) revert InsufficientAvailable(position.quantity, amount);
            if (amount == 0) continue;
            uint256 cost = amount == position.quantity ? position.cost : position.cost.mulDiv(amount, position.quantity);
            position.quantity -= amount;
            position.cost -= cost;
            totalCost += cost;
            IERC20 token = IERC20(assets[i]);
            balancesBefore[i] = token.balanceOf(address(this));
            token.forceApprove(address(vault), 0);
            token.forceApprove(address(vault), amount);
        }

        shares = vault.integrateInvestment(request.owner, amounts, totalCost);
        if (shares == 0) revert NoIntegrableTranche(requestId);
        if (shares != previewShares) revert IntegrationSharesMismatch(previewShares, shares);
        bytes32 currentVersion = vault.investmentVersion();
        if (request.version != currentVersion) revert RequestVersionMismatch(request.version, currentVersion);

        for (uint256 i = 0; i < n; ++i) {
            uint256 amount = amounts[i];
            if (amount == 0) continue;
            IERC20 token = IERC20(assets[i]);
            uint256 balanceAfter = token.balanceOf(address(this));
            if (balanceAfter > balancesBefore[i]) revert VaultPullMismatch(assets[i], amount, 0);
            uint256 actualPulled = balancesBefore[i] - balanceAfter;
            if (actualPulled != amount) revert VaultPullMismatch(assets[i], amount, actualPulled);
            token.forceApprove(address(vault), 0);
        }

        request.integratedCost += totalCost;
        request.shares += shares;
        unchecked {
            ++request.sequence;
        }
        emit RequestIntegrated(requestId, request.owner, request.sequence, totalCost, valueReceived, shares, amounts);
        _closeIfSettled(requestId, request);
    }

    /// @notice Stops future fills and returns only still-unspent settlement. Bought tokens remain separately claimable.
    function stop(uint256 requestId) external nonReentrant {
        Request storage request = _request(requestId);
        if (msg.sender != request.owner) revert NotRequestOwner(msg.sender, request.owner);
        if (request.status != RequestStatus.Open) revert RequestNotOpen(requestId, request.status);

        request.status = RequestStatus.Stopped;
        uint256 refundable = request.available;
        if (refundable != 0) {
            request.available = 0;
            request.refunded += refundable;
            _transferExact(settlement, request.owner, refundable);
        }
        emit RequestStopped(requestId, request.owner, refundable);
        _closeIfSettled(requestId, request);
    }

    /// @notice Claims one bought token after stop, without depending on a price, registry state, DEX, or keeper.
    function claim(uint256 requestId, uint256 index) external nonReentrant {
        Request storage request = _request(requestId);
        if (msg.sender != request.owner) revert NotRequestOwner(msg.sender, request.owner);
        if (request.status != RequestStatus.Stopped) revert RequestNotStopped(requestId, request.status);
        address[] storage assets = _requestAssets[requestId];
        if (index >= assets.length) revert InvalidAssetIndex(index);
        address asset = assets[index];
        Position storage position = _positions[requestId][asset];
        uint256 quantity = position.quantity;
        if (quantity == 0) revert EmptyPosition(requestId, asset);
        uint256 cost = position.cost;

        position.quantity = 0;
        position.cost = 0;
        _transferExact(IERC20(asset), request.owner, quantity);
        emit PositionClaimed(requestId, request.owner, asset, quantity, cost);
        _closeIfSettled(requestId, request);
    }

    function _openRequest(uint256 requestId, uint256 expectedSequence, uint256 deadline)
        private
        view
        returns (Request storage request)
    {
        request = _request(requestId);
        if (request.status != RequestStatus.Open) revert RequestNotOpen(requestId, request.status);
        if (deadline < block.timestamp) revert DeadlineExpired(deadline);
        bytes32 currentVersion = vault.investmentVersion();
        if (request.version != currentVersion) revert RequestVersionMismatch(request.version, currentVersion);
        if (request.sequence != expectedSequence) revert SequenceMismatch(expectedSequence, request.sequence);
    }

    function _request(uint256 requestId) private view returns (Request storage request) {
        request = _requests[requestId];
        if (request.owner == address(0)) revert UnknownRequest(requestId);
    }

    function _closeIfSettled(uint256 requestId, Request storage request) private {
        if (request.status == RequestStatus.Closed || request.available != 0) return;
        address[] storage assets = _requestAssets[requestId];
        for (uint256 i = 0; i < assets.length; ++i) {
            if (_positions[requestId][assets[i]].quantity != 0) return;
        }
        request.status = RequestStatus.Closed;
        emit RequestClosed(requestId, request.owner);
    }

    /// @dev Caps each purchase by the request's still-personal acquisition budget. This is kept in
    /// settlement cost units, intentionally separate from the later token-value admission/mint:
    /// external swap loss remains the request owner's loss and cannot be reallocated to a later leg.
    /// With an empty vault it uses target basket weights; otherwise it samples every shared basket
    /// holding at one fresh registry price set and follows the current composition.
    function _maxFillAmount(uint256 requestId, uint256 selectedIndex, Request storage request, uint256 selectedPrice)
        private
        view
        returns (uint256)
    {
        address[] storage assets = _requestAssets[requestId];
        uint16[] memory weights = vault.basketWeightsBps();
        uint256 n = assets.length;
        if (n != weights.length) revert BasketLengthMismatch(n, weights.length);

        uint256 personalBudget = _personalBudget(requestId, request.available, assets);
        uint256 targetCost;
        if (vault.totalSupply() == 0) {
            targetCost = personalBudget.mulDiv(weights[selectedIndex], _weightSum(weights));
        } else {
            (uint256 selectedSharedValue, uint256 sharedValue) = _sharedValues(assets, selectedIndex, selectedPrice);
            if (sharedValue == 0) revert SharedBasketHasNoValue();
            targetCost = personalBudget.mulDiv(selectedSharedValue, sharedValue);
        }
        uint256 currentCost = _positions[requestId][assets[selectedIndex]].cost;
        uint256 deficit = targetCost > currentCost ? targetCost - currentCost : 0;
        return Math.min(request.available, deficit);
    }

    function _personalBudget(uint256 requestId, uint256 available, address[] storage assets)
        private
        view
        returns (uint256 personalBudget)
    {
        personalBudget = available;
        for (uint256 i = 0; i < assets.length; ++i) {
            personalBudget += _positions[requestId][assets[i]].cost;
        }
    }

    function _weightSum(uint16[] memory weights) private pure returns (uint256 total) {
        for (uint256 i = 0; i < weights.length; ++i) {
            total += weights[i];
        }
    }

    function _sharedValues(address[] storage assets, uint256 selectedIndex, uint256 selectedPrice)
        private
        view
        returns (uint256 selectedValue, uint256 totalValue)
    {
        uint256 settlementScale = 10 ** uint256(vault.settlementDecimals());
        for (uint256 i = 0; i < assets.length; ++i) {
            address asset = assets[i];
            if (!registry.canOpenExposure(asset)) revert AssetNotOpen(asset);
            AssetRegistry.AssetConfig memory config = registry.assetConfig(asset);
            uint256 price;
            if (i == selectedIndex) {
                price = selectedPrice;
            } else {
                (price,) = registry.getPrice(asset, address(settlement));
            }
            uint256 value = IERC20(asset).balanceOf(address(vault))
                .mulDiv(price * settlementScale, (10 ** uint256(config.decimals)) * 1e18);
            totalValue += value;
            if (i == selectedIndex) selectedValue = value;
        }
    }

    function _transferFromExact(IERC20 token, address from, uint256 amount) private {
        uint256 recipientBefore = token.balanceOf(address(this));
        uint256 senderBefore = token.balanceOf(from);
        token.safeTransferFrom(from, address(this), amount);
        uint256 recipientAfter = token.balanceOf(address(this));
        uint256 senderAfter = token.balanceOf(from);
        uint256 recipientDelta = recipientAfter >= recipientBefore ? recipientAfter - recipientBefore : 0;
        uint256 senderDelta = senderBefore >= senderAfter ? senderBefore - senderAfter : 0;
        if (senderDelta != amount || recipientDelta != amount) {
            revert InexactTokenTransfer(address(token), amount, senderDelta, recipientDelta);
        }
    }

    function _transferExact(IERC20 token, address to, uint256 amount) private {
        uint256 senderBefore = token.balanceOf(address(this));
        uint256 recipientBefore = token.balanceOf(to);
        token.safeTransfer(to, amount);
        uint256 senderAfter = token.balanceOf(address(this));
        uint256 recipientAfter = token.balanceOf(to);
        uint256 senderDelta = senderBefore >= senderAfter ? senderBefore - senderAfter : 0;
        uint256 recipientDelta = recipientAfter >= recipientBefore ? recipientAfter - recipientBefore : 0;
        if (senderDelta != amount || recipientDelta != amount) {
            revert InexactTokenTransfer(address(token), amount, senderDelta, recipientDelta);
        }
    }
}
