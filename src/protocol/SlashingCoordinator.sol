// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ISlashingCoordinator} from "../interfaces/ISlashingCoordinator.sol";
import {IOperatorRegistry} from "../interfaces/IOperatorRegistry.sol";
import {SignatureVerifier} from "../libraries/SignatureVerifier.sol";

interface IRestakingVaultForSlashing {
    function slashVaultValue(uint256 ethAmount, address challenger, uint256 bountyReward) external;
}

contract SlashingCoordinator is ISlashingCoordinator {
    using SignatureVerifier for bytes32;

    uint256 public constant DOUBLE_SIGN_PENALTY_BPS = 2000; // 20.00%
    uint256 public constant DOWNTIME_PENALTY_BPS = 500; // 5.00%
    uint256 public constant BOUNTY_SHARE_BPS = 2000; // 20.00% of slashed funds
    uint256 public constant MIN_MISSED_FOR_DOWNTIME = 5;

    IOperatorRegistry public immutable operatorRegistry;
    address public restakingVault;
    address public insuranceReserve;
    address public owner;

    SlashingRecord[] private _disputes;
    mapping(bytes32 => bool) public executedDisputes;

    error Unauthorized();
    error ZeroAddress();
    error IdenticalTaskHashes();
    error InvalidDoubleSignProof();
    error InsufficientMissedTasks();
    error DisputeAlreadyExecuted();
    error OperatorNotRegistered();
    error NoStakeToSlash();

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    constructor(address _operatorRegistry) {
        if (_operatorRegistry == address(0)) revert ZeroAddress();
        operatorRegistry = IOperatorRegistry(_operatorRegistry);
        owner = msg.sender;
    }

    function setVaultAndInsurance(address _restakingVault, address _insuranceReserve) external onlyOwner {
        if (_restakingVault == address(0) || _insuranceReserve == address(0)) revert ZeroAddress();
        restakingVault = _restakingVault;
        insuranceReserve = _insuranceReserve;
    }

    function executeDoubleSignSlashing(
        address operator,
        bytes32 taskHashA,
        bytes32 taskHashB,
        bytes calldata signatureA,
        bytes calldata signatureB
    ) external override returns (uint256 disputeId) {
        if (taskHashA == taskHashB) revert IdenticalTaskHashes();

        bytes32 disputeKey = keccak256(abi.encodePacked(operator, taskHashA, taskHashB));
        if (executedDisputes[disputeKey]) revert DisputeAlreadyExecuted();

        // Verify cryptographic signatures for both contradictory commitments
        bytes32 digestA = SignatureVerifier.toEthSignedMessageHash(
            keccak256(abi.encodePacked(operator, taskHashA, block.chainid))
        );
        bytes32 digestB = SignatureVerifier.toEthSignedMessageHash(
            keccak256(abi.encodePacked(operator, taskHashB, block.chainid))
        );

        address recoveredA = SignatureVerifier.recoverSigner(digestA, signatureA);
        address recoveredB = SignatureVerifier.recoverSigner(digestB, signatureB);

        if (recoveredA != operator || recoveredB != operator) {
            revert InvalidDoubleSignProof();
        }

        IOperatorRegistry.OperatorInfo memory info = operatorRegistry.getOperator(operator);
        if (info.registeredAt == 0) revert OperatorNotRegistered();
        if (info.delegatedETHValue == 0) revert NoStakeToSlash();

        uint256 slashedETHValue = (info.delegatedETHValue * DOUBLE_SIGN_PENALTY_BPS) / 10_000;
        uint256 bountyReward = (slashedETHValue * BOUNTY_SHARE_BPS) / 10_000;

        // Mark executed
        executedDisputes[disputeKey] = true;

        // Update Operator Registry
        operatorRegistry.recordSlashing(operator, slashedETHValue);

        // Slash vault balance and distribute bounty
        if (restakingVault != address(0)) {
            IRestakingVaultForSlashing(restakingVault).slashVaultValue(slashedETHValue, msg.sender, bountyReward);
        }

        disputeId = _disputes.length;
        _disputes.push(
            SlashingRecord({
                operator: operator,
                infraction: InfractionType.DOUBLE_SIGNING,
                penaltyBps: DOUBLE_SIGN_PENALTY_BPS,
                slashedETHValue: slashedETHValue,
                timestamp: block.timestamp,
                challenger: msg.sender
            })
        );

        emit SlashingExecuted(
            disputeId,
            operator,
            InfractionType.DOUBLE_SIGNING,
            slashedETHValue,
            msg.sender,
            bountyReward
        );
    }

    function executeDowntimeSlashing(
        address operator,
        uint256 missedTasksCount,
        uint256 evaluationEpoch
    ) external override returns (uint256 disputeId) {
        if (missedTasksCount < MIN_MISSED_FOR_DOWNTIME) revert InsufficientMissedTasks();

        bytes32 disputeKey = keccak256(abi.encodePacked(operator, evaluationEpoch));
        if (executedDisputes[disputeKey]) revert DisputeAlreadyExecuted();

        IOperatorRegistry.OperatorInfo memory info = operatorRegistry.getOperator(operator);
        if (info.registeredAt == 0) revert OperatorNotRegistered();
        if (info.delegatedETHValue == 0) revert NoStakeToSlash();

        uint256 slashedETHValue = (info.delegatedETHValue * DOWNTIME_PENALTY_BPS) / 10_000;
        uint256 bountyReward = (slashedETHValue * BOUNTY_SHARE_BPS) / 10_000;

        executedDisputes[disputeKey] = true;

        operatorRegistry.recordSlashing(operator, slashedETHValue);

        if (restakingVault != address(0)) {
            IRestakingVaultForSlashing(restakingVault).slashVaultValue(slashedETHValue, msg.sender, bountyReward);
        }

        disputeId = _disputes.length;
        _disputes.push(
            SlashingRecord({
                operator: operator,
                infraction: InfractionType.UNRESPONSIVENESS,
                penaltyBps: DOWNTIME_PENALTY_BPS,
                slashedETHValue: slashedETHValue,
                timestamp: block.timestamp,
                challenger: msg.sender
            })
        );

        emit SlashingExecuted(
            disputeId,
            operator,
            InfractionType.UNRESPONSIVENESS,
            slashedETHValue,
            msg.sender,
            bountyReward
        );
    }

    function getDispute(uint256 disputeId) external view returns (SlashingRecord memory) {
        return _disputes[disputeId];
    }

    function totalDisputes() external view returns (uint256) {
        return _disputes.length;
    }
}
