// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IOperatorRegistry} from "../interfaces/IOperatorRegistry.sol";

contract OperatorRegistry is IOperatorRegistry {
    uint256 public constant MAX_COMMISSION_BPS = 3000; // 30%
    uint256 public constant MIN_ACTIVE_HEALTH_SCORE = 5000; // 50%
    uint256 public constant MAX_HEALTH_SCORE = 10_000;

    address public owner;
    address public slashingCoordinator;
    address public restakingVault;

    uint256 private _totalActiveDelegation;
    mapping(address => OperatorInfo) private _operators;
    address[] private _operatorList;

    error Unauthorized();
    error ZeroAddress();
    error OperatorAlreadyRegistered();
    error OperatorNotRegistered();
    error OperatorNotActive();
    error CommissionTooHigh();
    error InsufficientDelegatedStake();
    error InvalidHealthScore();

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier onlyAuthorizedOrVault() {
        if (msg.sender != owner && msg.sender != restakingVault) revert Unauthorized();
        _;
    }

    modifier onlySlasher() {
        if (msg.sender != slashingCoordinator && msg.sender != owner) revert Unauthorized();
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    function setSlashingCoordinator(address _slashingCoordinator) external onlyOwner {
        if (_slashingCoordinator == address(0)) revert ZeroAddress();
        slashingCoordinator = _slashingCoordinator;
    }

    function setRestakingVault(address _restakingVault) external onlyOwner {
        if (_restakingVault == address(0)) revert ZeroAddress();
        restakingVault = _restakingVault;
    }

    function registerOperator(uint256 commissionBps) external override {
        if (commissionBps > MAX_COMMISSION_BPS) revert CommissionTooHigh();
        OperatorInfo storage op = _operators[msg.sender];
        if (op.registeredAt != 0) revert OperatorAlreadyRegistered();

        op.operatorAddress = msg.sender;
        op.status = OperatorStatus.ACTIVE;
        op.commissionBps = commissionBps;
        op.registeredAt = block.timestamp;
        op.healthScore = MAX_HEALTH_SCORE;

        _operatorList.push(msg.sender);

        emit OperatorRegistered(msg.sender, commissionBps);
        emit OperatorStatusChanged(msg.sender, OperatorStatus.INACTIVE, OperatorStatus.ACTIVE);
    }

    function delegateToOperator(address operator, uint256 ethValue) external override onlyAuthorizedOrVault {
        OperatorInfo storage op = _operators[operator];
        if (op.registeredAt == 0) revert OperatorNotRegistered();
        if (op.status != OperatorStatus.ACTIVE) revert OperatorNotActive();

        op.delegatedETHValue += ethValue;
        _totalActiveDelegation += ethValue;

        emit StakeDelegated(msg.sender, operator, ethValue);
    }

    function undelegateFromOperator(address operator, uint256 ethValue) external override onlyAuthorizedOrVault {
        OperatorInfo storage op = _operators[operator];
        if (op.delegatedETHValue < ethValue) revert InsufficientDelegatedStake();

        unchecked {
            op.delegatedETHValue -= ethValue;
            _totalActiveDelegation -= ethValue;
        }

        emit StakeUndelegated(msg.sender, operator, ethValue);
    }

    function recordSlashing(address operator, uint256 ethAmountToSlash) external override onlySlasher {
        OperatorInfo storage op = _operators[operator];
        if (op.registeredAt == 0) revert OperatorNotRegistered();

        uint256 actualSlash = ethAmountToSlash > op.delegatedETHValue ? op.delegatedETHValue : ethAmountToSlash;
        op.delegatedETHValue -= actualSlash;
        _totalActiveDelegation -= actualSlash;

        // Health score reduction
        uint256 penaltyScore = (MAX_HEALTH_SCORE * 3000) / 10000; // 30% reduction
        if (op.healthScore > penaltyScore) {
            op.healthScore -= penaltyScore;
        } else {
            op.healthScore = 0;
            OperatorStatus oldStatus = op.status;
            op.status = OperatorStatus.SLASHED;
            emit OperatorStatusChanged(operator, oldStatus, OperatorStatus.SLASHED);
        }

        emit OperatorSlashed(operator, actualSlash);
        emit HealthScoreUpdated(operator, op.healthScore);
    }

    function updateHealthScore(address operator, uint256 newScore) external override onlyOwner {
        if (newScore > MAX_HEALTH_SCORE) revert InvalidHealthScore();
        OperatorInfo storage op = _operators[operator];
        if (op.registeredAt == 0) revert OperatorNotRegistered();

        op.healthScore = newScore;
        if (newScore < MIN_ACTIVE_HEALTH_SCORE && op.status == OperatorStatus.ACTIVE) {
            op.status = OperatorStatus.FROZEN;
            emit OperatorStatusChanged(operator, OperatorStatus.ACTIVE, OperatorStatus.FROZEN);
        } else if (newScore >= MIN_ACTIVE_HEALTH_SCORE && op.status == OperatorStatus.FROZEN) {
            op.status = OperatorStatus.ACTIVE;
            emit OperatorStatusChanged(operator, OperatorStatus.FROZEN, OperatorStatus.ACTIVE);
        }

        emit HealthScoreUpdated(operator, newScore);
    }

    function getOperator(address operator) external view override returns (OperatorInfo memory) {
        return _operators[operator];
    }

    function totalActiveDelegation() external view override returns (uint256) {
        return _totalActiveDelegation;
    }

    function isOperatorActive(address operator) external view override returns (bool) {
        OperatorInfo memory op = _operators[operator];
        return op.status == OperatorStatus.ACTIVE && op.healthScore >= MIN_ACTIVE_HEALTH_SCORE;
    }

    function getOperatorCount() external view returns (uint256) {
        return _operatorList.length;
    }
}
