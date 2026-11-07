// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AVSManager} from "../src/protocol/AVSManager.sol";
import {OperatorRegistry} from "../src/protocol/OperatorRegistry.sol";
import {IAVSManager} from "../src/interfaces/IAVSManager.sol";
import {SignatureVerifier} from "../src/libraries/SignatureVerifier.sol";

contract AVSTaskQuorumTest is Test {
    AVSManager public avsManager;
    OperatorRegistry public registry;

    uint256 internal opKey1 = 0xA111;
    uint256 internal opKey2 = 0xB222;
    uint256 internal opKey3 = 0xC333;

    address internal op1;
    address internal op2;
    address internal op3;

    function setUp() public {
        op1 = vm.addr(opKey1);
        op2 = vm.addr(opKey2);
        op3 = vm.addr(opKey3);

        // Ensure addresses are sorted op1 < op2 < op3 to satisfy ascending order check
        if (op1 > op2) {
            (op1, op2) = (op2, op1);
            (opKey1, opKey2) = (opKey2, opKey1);
        }
        if (op2 > op3) {
            (op2, op3) = (op3, op2);
            (opKey2, opKey3) = (opKey3, opKey2);
        }
        if (op1 > op2) {
            (op1, op2) = (op2, op1);
            (opKey1, opKey2) = (opKey2, opKey1);
        }

        registry = new OperatorRegistry();
        avsManager = new AVSManager(address(registry));

        // Register operators
        vm.prank(op1);
        registry.registerOperator(500);
        vm.prank(op2);
        registry.registerOperator(500);
        vm.prank(op3);
        registry.registerOperator(500);

        // Delegate stakes: op1 = 40 ETH, op2 = 40 ETH, op3 = 20 ETH (total = 100 ETH)
        registry.delegateToOperator(op1, 40 ether);
        registry.delegateToOperator(op2, 40 ether);
        registry.delegateToOperator(op3, 20 ether);
    }

    function test_CreateTask() public {
        bytes32 taskHash = keccak256("ComputeExecutionPayload(block #1200)");
        uint256 taskIndex = avsManager.createNewTask(taskHash, 1 hours, 6667); // 66.67% quorum

        IAVSManager.Task memory task = avsManager.getTask(taskIndex);
        assertEq(task.taskIndex, 0);
        assertEq(task.taskHash, taskHash);
        assertEq(uint256(task.status), uint256(IAVSManager.TaskStatus.PENDING));
        assertEq(task.quorumThresholdBps, 6667);
    }

    function test_SubmitValidQuorumResponse() public {
        bytes32 taskHash = keccak256("ComputeExecutionPayload(block #1200)");
        uint256 taskIndex = avsManager.createNewTask(taskHash, 1 hours, 6667); // 66.67% quorum

        bytes32 resultHash = keccak256("StateRoot(0x9a8b...)");

        // Compute expected message hash
        bytes32 structHash = keccak256(
            abi.encodePacked(taskIndex, taskHash, resultHash, address(avsManager), block.chainid)
        );
        bytes32 ethSignedMessageHash = SignatureVerifier.toEthSignedMessageHash(structHash);

        // Sign with op1 (40 ETH) and op2 (40 ETH) = 80 ETH / 100 ETH = 80% >= 66.67%
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(opKey1, ethSignedMessageHash);
        bytes memory sig1 = abi.encodePacked(r1, s1, v1);

        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(opKey2, ethSignedMessageHash);
        bytes memory sig2 = abi.encodePacked(r2, s2, v2);

        address[] memory signers = new address[](2);
        signers[0] = op1;
        signers[1] = op2;

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = sig1;
        signatures[1] = sig2;

        avsManager.submitTaskResponse(taskIndex, resultHash, signers, signatures);

        IAVSManager.Task memory task = avsManager.getTask(taskIndex);
        assertEq(uint256(task.status), uint256(IAVSManager.TaskStatus.COMPLETED));
        assertEq(task.resultHash, resultHash);
        assertEq(task.totalSignerWeight, 80 ether);
    }

    function test_QuorumFailureWhenInsufficientStake() public {
        bytes32 taskHash = keccak256("ComputeExecutionPayload(block #1201)");
        uint256 taskIndex = avsManager.createNewTask(taskHash, 1 hours, 6667);

        bytes32 resultHash = keccak256("StateRoot(0x1234...)");
        bytes32 structHash = keccak256(
            abi.encodePacked(taskIndex, taskHash, resultHash, address(avsManager), block.chainid)
        );
        bytes32 ethSignedMessageHash = SignatureVerifier.toEthSignedMessageHash(structHash);

        // Only op3 signs (20 ETH / 100 ETH = 20% < 66.67%)
        (uint8 v3, bytes32 r3, bytes32 s3) = vm.sign(opKey3, ethSignedMessageHash);
        bytes memory sig3 = abi.encodePacked(r3, s3, v3);

        address[] memory signers = new address[](1);
        signers[0] = op3;
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = sig3;

        vm.expectRevert();
        avsManager.submitTaskResponse(taskIndex, resultHash, signers, signatures);
    }

    function test_TaskExpiredRevert() public {
        bytes32 taskHash = keccak256("ComputeExecutionPayload(block #1202)");
        uint256 taskIndex = avsManager.createNewTask(taskHash, 30 minutes, 6667);

        // Warp past deadline
        vm.warp(block.timestamp + 31 minutes);

        address[] memory signers = new address[](1);
        signers[0] = op1;
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = "";

        vm.expectRevert(AVSManager.TaskExpired.selector);
        avsManager.submitTaskResponse(taskIndex, bytes32(0), signers, signatures);
    }
}
