// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IAVSManager} from "../interfaces/IAVSManager.sol";
import {IOperatorRegistry} from "../interfaces/IOperatorRegistry.sol";
import {SignatureVerifier} from "../libraries/SignatureVerifier.sol";

contract AVSManager is IAVSManager {
    using SignatureVerifier for bytes32;

    IOperatorRegistry public immutable operatorRegistry;
    address public owner;

    Task[] private _tasks;

    error Unauthorized();
    error ZeroAddress();
    error TaskDoesNotExist();
    error TaskNotPending();
    error TaskExpired();
    error InvalidDuration();
    error InvalidQuorumThreshold();
    error ArrayLengthMismatch();
    error NoSignersProvided();
    error SignersNotAscending();
    error InactiveOperator(address operator);
    error InvalidOperatorSignature(address operator);
    error QuorumNotAchieved(uint256 weightAchieved, uint256 weightRequired);

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    constructor(address _operatorRegistry) {
        if (_operatorRegistry == address(0)) revert ZeroAddress();
        operatorRegistry = IOperatorRegistry(_operatorRegistry);
        owner = msg.sender;
    }

    function createNewTask(
        bytes32 taskHash,
        uint256 duration,
        uint16 quorumThresholdBps
    ) external override returns (uint256 taskIndex) {
        if (duration == 0) revert InvalidDuration();
        if (quorumThresholdBps < 5000 || quorumThresholdBps > 10_000) revert InvalidQuorumThreshold();

        taskIndex = _tasks.length;
        uint256 deadline = block.timestamp + duration;

        _tasks.push(
            Task({
                taskIndex: taskIndex,
                taskHash: taskHash,
                blockCreated: block.number,
                deadline: deadline,
                quorumThresholdBps: quorumThresholdBps,
                status: TaskStatus.PENDING,
                resultHash: bytes32(0),
                totalSignerWeight: 0
            })
        );

        emit TaskCreated(taskIndex, taskHash, deadline, quorumThresholdBps);
    }

    function submitTaskResponse(
        uint256 taskIndex,
        bytes32 resultHash,
        address[] calldata signers,
        bytes[] calldata signatures
    ) external override {
        if (taskIndex >= _tasks.length) revert TaskDoesNotExist();
        Task storage task = _tasks[taskIndex];

        if (task.status != TaskStatus.PENDING) revert TaskNotPending();
        if (block.timestamp > task.deadline) {
            task.status = TaskStatus.EXPIRED;
            revert TaskExpired();
        }

        uint256 numSigners = signers.length;
        if (numSigners == 0) revert NoSignersProvided();
        if (numSigners != signatures.length) revert ArrayLengthMismatch();

        // Construct EIP-191 prefixed digest
        bytes32 structHash = keccak256(
            abi.encodePacked(taskIndex, task.taskHash, resultHash, address(this), block.chainid)
        );
        bytes32 messageHash = SignatureVerifier.toEthSignedMessageHash(structHash);

        uint256 signerWeight = 0;
        address previousSigner = address(0);

        for (uint256 i = 0; i < numSigners; ) {
            address signer = signers[i];
            // Enforce strict ascending order to guarantee uniqueness
            if (signer <= previousSigner) revert SignersNotAscending();
            previousSigner = signer;

            if (!operatorRegistry.isOperatorActive(signer)) revert InactiveOperator(signer);

            address recovered = SignatureVerifier.recoverSigner(messageHash, signatures[i]);
            if (recovered != signer) revert InvalidOperatorSignature(signer);

            IOperatorRegistry.OperatorInfo memory info = operatorRegistry.getOperator(signer);
            signerWeight += info.delegatedETHValue;

            unchecked {
                ++i;
            }
        }

        uint256 totalActiveStake = operatorRegistry.totalActiveDelegation();
        uint256 weightRequired = (totalActiveStake * task.quorumThresholdBps) / 10_000;

        if (signerWeight < weightRequired) {
            revert QuorumNotAchieved(signerWeight, weightRequired);
        }

        task.status = TaskStatus.COMPLETED;
        task.resultHash = resultHash;
        task.totalSignerWeight = signerWeight;

        emit TaskResponded(taskIndex, resultHash, signerWeight);
    }

    function challengeTask(uint256 taskIndex, bytes calldata reason) external {
        if (taskIndex >= _tasks.length) revert TaskDoesNotExist();
        Task storage task = _tasks[taskIndex];
        task.status = TaskStatus.CHALLENGED;
        emit TaskChallenged(taskIndex, msg.sender, reason);
    }

    function getTask(uint256 taskIndex) external view override returns (Task memory) {
        if (taskIndex >= _tasks.length) revert TaskDoesNotExist();
        return _tasks[taskIndex];
    }

    function taskCount() external view returns (uint256) {
        return _tasks.length;
    }
}
