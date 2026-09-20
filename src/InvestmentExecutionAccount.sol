// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {InvestmentEscrow} from "./InvestmentEscrow.sol";
import {IAccount} from "../lib/account-abstraction/contracts/interfaces/IAccount.sol";
import {IEntryPoint} from "../lib/account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "../lib/account-abstraction/contracts/interfaces/PackedUserOperation.sol";

/// @notice A narrowly-scoped ERC-4337 account which can only progress one personal investment request.
/// @dev The EntryPoint deposit is the whole execution budget. This account never owns request assets or protocol funds.
contract InvestmentExecutionAccount is IAccount {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    uint256 public constant MIN_VERIFICATION_GAS = 100_000;
    uint256 public constant MAX_VERIFICATION_GAS = 500_000;
    uint256 public constant MIN_CALL_GAS = 100_000;
    uint256 public constant MAX_CALL_GAS = 1_000_000;
    uint256 public constant MIN_PRE_VERIFICATION_GAS = 25_000;
    uint256 public constant MAX_PRE_VERIFICATION_GAS = 300_000;

    struct Policy {
        uint128 maxFeePerGas;
        uint128 maxAttemptFee;
        uint32 maxAttempts;
        uint48 validUntil;
        uint256 minFillAmount;
    }

    IEntryPoint public immutable entryPoint;
    InvestmentEscrow public immutable escrow;
    uint256 public immutable requestId;
    address public immutable owner;
    address public immutable executor;
    Policy private _policy;

    uint32 public attempts;
    bool public paused;
    uint192 public policyEpoch;
    uint256 public totalFunded;
    uint256 public totalWithdrawn;

    error NotEntryPoint(address caller);
    error NotOwner(address caller);
    error InvalidPolicy();
    error InvalidFundingAmount();
    error InvalidUserOperation();
    error AccountPaused();
    error AccountNotPaused();
    error AttemptLimitReached();
    error NoProgress();
    error NativeTransferFailed();

    event AccountFunded(address indexed owner, uint256 amount, uint256 totalFunded);
    event BudgetWithdrawn(address indexed owner, uint256 amount, uint256 totalWithdrawn);
    event ExecutionAttempt(bytes4 indexed operation, uint32 attempts, uint192 policyEpoch);
    event ExecutionPaused(uint32 attempts, uint192 policyEpoch);
    event ExecutionRearmed(uint192 policyEpoch);

    constructor(IEntryPoint entryPoint_, InvestmentEscrow escrow_, uint256 requestId_, address owner_, address executor_, Policy memory policy_)
        payable
    {
        if (address(entryPoint_) == address(0) || address(escrow_) == address(0) || owner_ == address(0)
            || executor_ == address(0) || policy_.maxFeePerGas == 0 || policy_.maxAttemptFee == 0
            || policy_.maxAttempts == 0 || policy_.validUntil == 0 || policy_.minFillAmount == 0
            || policy_.validUntil <= block.timestamp) {
            revert InvalidPolicy();
        }
        if (policy_.maxAttempts > type(uint256).max / policy_.maxAttemptFee
            || msg.value < uint256(policy_.maxAttempts) * policy_.maxAttemptFee) revert InvalidFundingAmount();
        entryPoint = entryPoint_;
        escrow = escrow_;
        requestId = requestId_;
        owner = owner_;
        executor = executor_;
        _policy = policy_;
        if (msg.value != 0) {
            totalFunded = msg.value;
            entryPoint_.depositTo{value: msg.value}(address(this));
            emit AccountFunded(owner_, msg.value, msg.value);
        }
    }

    function policy() external view returns (Policy memory) {
        return _policy;
    }

    function getBudget() external view returns (uint256) {
        return entryPoint.balanceOf(address(this));
    }

    /// @notice Adds native budget directly to this account's EntryPoint deposit without changing execution state.
    function topUp() external payable onlyOwner {
        if (msg.value == 0) revert InvalidFundingAmount();
        totalFunded += msg.value;
        entryPoint.depositTo{value: msg.value}(address(this));
        emit AccountFunded(owner, msg.value, totalFunded);
    }

    /// @notice Recovers unused EntryPoint budget to the request owner and invalidates outstanding signatures.
    function withdrawBudget(uint256 amount) external onlyOwner {
        _pauseAndInvalidate();
        entryPoint.withdrawTo(payable(owner), amount);
        totalWithdrawn += amount;
        emit BudgetWithdrawn(owner, amount, totalWithdrawn);
    }

    /// @notice Re-arms a previously stopped account; it never replenishes lifetime attempts or its policy.
    function resume() external onlyOwner {
        if (!paused) revert AccountNotPaused();
        if (attempts >= _policy.maxAttempts) revert AttemptLimitReached();
        paused = false;
        unchecked {
            ++policyEpoch;
        }
        emit ExecutionRearmed(policyEpoch);
    }

    /// @notice Returns ETH force-sent to this account without accepting ordinary funding outside EntryPoint.
    function recoverForcedNative(uint256 amount) external onlyOwner {
        _pauseAndInvalidate();
        (bool sent,) = payable(owner).call{value: amount}("");
        if (!sent) revert NativeTransferFailed();
    }

    /// @notice Executes exactly one consented request fill after EntryPoint validation.
    function executeFill(uint256 index, uint256 amount, uint256 expectedSequence, uint256 deadline) external onlyEntryPoint {
        if (!paused) revert AccountNotPaused();
        uint256 permitted = escrow.maxFillAmount(requestId, index);
        if (amount < _policy.minFillAmount && amount != permitted) revert NoProgress();
        escrow.fill(requestId, index, amount, expectedSequence, deadline);
        _rearmAfterProgress();
    }

    /// @notice Integrates one complete personal tranche after EntryPoint validation.
    function executeIntegrate(uint256 expectedSequence) external onlyEntryPoint {
        if (!paused) revert AccountNotPaused();
        InvestmentEscrow.Request memory beforeRequest = escrow.getRequest(requestId);
        uint256 shares = escrow.integrate(requestId, expectedSequence);
        if (shares == 0) revert NoProgress();
        InvestmentEscrow.Request memory afterRequest = escrow.getRequest(requestId);
        uint256 integrated = afterRequest.integratedCost - beforeRequest.integratedCost;
        // A smaller final tranche is useful only when it consumes every bought position. This keeps an executor
        // from turning one request into a sequence of paid dust integrations.
        if (integrated < _policy.minFillAmount && afterRequest.spent != afterRequest.integratedCost) revert NoProgress();
        _rearmAfterProgress();
    }

    /// @inheritdoc IAccount
    function validateUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash, uint256 missingAccountFunds)
        external
        override
        onlyEntryPoint
        returns (uint256 validationData)
    {
        if (!_isValidOperation(userOp, missingAccountFunds)
            || userOpHash.toEthSignedMessageHash().recover(userOp.signature) != executor) {
            return _signatureFailure();
        }
        _pauseAndInvalidate();
        unchecked {
            ++attempts;
        }
        bytes calldata callData = userOp.callData;
        bytes4 selector;
        assembly ("memory-safe") {
            selector := calldataload(callData.offset)
        }
        emit ExecutionAttempt(selector, attempts, policyEpoch);
        return uint256(_policy.validUntil) << 160;
    }

    function _isValidOperation(PackedUserOperation calldata userOp, uint256 missingAccountFunds) private view returns (bool) {
        if (paused || attempts >= _policy.maxAttempts || userOp.sender != address(this) || userOp.initCode.length != 0
            || userOp.paymasterAndData.length != 0 || missingAccountFunds != 0 || uint192(userOp.nonce >> 64) != policyEpoch) {
            return false;
        }

        uint256 limits = uint256(userOp.accountGasLimits);
        uint256 verificationGas = limits >> 128;
        uint256 callGas = uint128(limits);
        uint256 fees = uint256(userOp.gasFees);
        uint256 maxPriorityFeePerGas = fees >> 128;
        uint256 maxFeePerGas = uint128(fees);
        if (verificationGas < MIN_VERIFICATION_GAS || verificationGas > MAX_VERIFICATION_GAS || callGas < MIN_CALL_GAS
            || callGas > MAX_CALL_GAS || userOp.preVerificationGas < MIN_PRE_VERIFICATION_GAS
            || userOp.preVerificationGas > MAX_PRE_VERIFICATION_GAS || maxFeePerGas == 0
            || maxFeePerGas > _policy.maxFeePerGas || maxPriorityFeePerGas > maxFeePerGas) return false;

        uint256 gasUnits = verificationGas + callGas + userOp.preVerificationGas;
        if (gasUnits > type(uint256).max / maxFeePerGas || gasUnits * maxFeePerGas > _policy.maxAttemptFee) return false;
        if (entryPoint.balanceOf(address(this)) < gasUnits * maxFeePerGas) return false;

        return _isExactAction(userOp.callData);
    }

    function _isExactAction(bytes calldata callData) private pure returns (bool) {
        if (callData.length == 4 + 32 * 4) {
            bytes4 selector;
            assembly ("memory-safe") {
                selector := calldataload(callData.offset)
            }
            return selector == this.executeFill.selector;
        }
        if (callData.length == 4 + 32) {
            bytes4 selector;
            assembly ("memory-safe") {
                selector := calldataload(callData.offset)
            }
            return selector == this.executeIntegrate.selector;
        }
        return false;
    }

    function _pauseAndInvalidate() private {
        paused = true;
        unchecked {
            ++policyEpoch;
        }
        emit ExecutionPaused(attempts, policyEpoch);
    }

    function _rearmAfterProgress() private {
        if (attempts >= _policy.maxAttempts) return;
        paused = false;
        emit ExecutionRearmed(policyEpoch);
    }

    function _signatureFailure() private pure returns (uint256) {
        return 1;
    }

    modifier onlyEntryPoint() {
        if (msg.sender != address(entryPoint)) revert NotEntryPoint(msg.sender);
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner(msg.sender);
        _;
    }
}
