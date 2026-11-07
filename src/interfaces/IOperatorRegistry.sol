// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IOperatorRegistry {
    enum OperatorStatus {
        INACTIVE,
        ACTIVE,
        SLASHED,
        FROZEN
    }

    struct OperatorInfo {
        address operatorAddress;
        OperatorStatus status;
        uint256 delegatedETHValue;
        uint256 commissionBps;
        uint256 registeredAt;
        uint256 healthScore; // Scale 0-10000 (10000 = 100% optimal performance)
    }

    event OperatorRegistered(address indexed operator, uint256 commissionBps);
    event OperatorStatusChanged(address indexed operator, OperatorStatus oldStatus, OperatorStatus newStatus);
    event StakeDelegated(address indexed staker, address indexed operator, uint256 ethValue);
    event StakeUndelegated(address indexed staker, address indexed operator, uint256 ethValue);
    event OperatorSlashed(address indexed operator, uint256 slashedAmount);
    event HealthScoreUpdated(address indexed operator, uint256 newScore);

    function registerOperator(uint256 commissionBps) external;
    function delegateToOperator(address operator, uint256 ethValue) external;
    function undelegateFromOperator(address operator, uint256 ethValue) external;
    function recordSlashing(address operator, uint256 ethAmountToSlash) external;
    function updateHealthScore(address operator, uint256 newScore) external;
    function getOperator(address operator) external view returns (OperatorInfo memory);
    function totalActiveDelegation() external view returns (uint256);
    function isOperatorActive(address operator) external view returns (bool);
}
