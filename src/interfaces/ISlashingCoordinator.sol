// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ISlashingCoordinator {
    enum InfractionType {
        DOUBLE_SIGNING,
        UNRESPONSIVENESS,
        MALICIOUS_EXECUTION
    }

    struct SlashingRecord {
        address operator;
        InfractionType infraction;
        uint256 penaltyBps; // e.g. 1000 = 10%
        uint256 slashedETHValue;
        uint256 timestamp;
        address challenger;
    }

    event SlashingExecuted(
        uint256 indexed disputeId,
        address indexed operator,
        InfractionType infraction,
        uint256 slashedAmount,
        address indexed challenger,
        uint256 bountyReward
    );

    function executeDoubleSignSlashing(
        address operator,
        bytes32 taskHashA,
        bytes32 taskHashB,
        bytes calldata signatureA,
        bytes calldata signatureB
    ) external returns (uint256 disputeId);

    function executeDowntimeSlashing(
        address operator,
        uint256 missedTasksCount,
        uint256 evaluationEpoch
    ) external returns (uint256 disputeId);
}
