// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IAVSManager {
    enum TaskStatus {
        PENDING,
        COMPLETED,
        EXPIRED,
        CHALLENGED
    }

    struct Task {
        uint256 taskIndex;
        bytes32 taskHash;
        uint256 blockCreated;
        uint256 deadline;
        uint16 quorumThresholdBps; // e.g., 6667 = 66.67%
        TaskStatus status;
        bytes32 resultHash;
        uint256 totalSignerWeight;
    }

    event TaskCreated(uint256 indexed taskIndex, bytes32 indexed taskHash, uint256 deadline, uint16 quorumThresholdBps);
    event TaskResponded(uint256 indexed taskIndex, bytes32 indexed resultHash, uint256 signerWeightAchieved);
    event TaskChallenged(uint256 indexed taskIndex, address indexed challenger, bytes reason);

    function createNewTask(bytes32 taskHash, uint256 duration, uint16 quorumThresholdBps) external returns (uint256 taskIndex);
    function submitTaskResponse(uint256 taskIndex, bytes32 resultHash, address[] calldata signers, bytes[] calldata signatures) external;
    function getTask(uint256 taskIndex) external view returns (Task memory);
}
