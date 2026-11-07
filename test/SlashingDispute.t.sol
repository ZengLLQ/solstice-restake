// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {SlashingCoordinator} from "../src/protocol/SlashingCoordinator.sol";
import {OperatorRegistry} from "../src/protocol/OperatorRegistry.sol";
import {RestakingVault} from "../src/protocol/RestakingVault.sol";
import {ExchangeRateOracle} from "../src/oracle/ExchangeRateOracle.sol";
import {SolETH} from "../src/tokens/SolETH.sol";
import {MockLST} from "../src/tokens/MockLST.sol";
import {InsuranceReserve} from "../src/protocol/InsuranceReserve.sol";
import {ISlashingCoordinator} from "../src/interfaces/ISlashingCoordinator.sol";
import {IOperatorRegistry} from "../src/interfaces/IOperatorRegistry.sol";
import {SignatureVerifier} from "../src/libraries/SignatureVerifier.sol";

contract SlashingDisputeTest is Test {
    SlashingCoordinator public slasher;
    OperatorRegistry public registry;
    RestakingVault public vault;
    ExchangeRateOracle public oracle;
    SolETH public solETH;
    MockLST public stETH;
    InsuranceReserve public reserve;

    uint256 internal operatorKey = 0xDEADBEEF;
    address internal operator;
    address internal challenger = address(0xCAFE);

    function setUp() public {
        operator = vm.addr(operatorKey);

        oracle = new ExchangeRateOracle();
        vault = new RestakingVault(address(oracle));
        solETH = new SolETH(address(vault));
        vault.setSolETH(address(solETH));

        stETH = new MockLST("Lido Staked ETH", "stETH", 18);
        oracle.setAssetOracle(address(stETH), 1e18, 86400, 500);
        vault.addSupportedAsset(address(stETH), 100, 10_000 ether);

        reserve = new InsuranceReserve();
        registry = new OperatorRegistry();
        slasher = new SlashingCoordinator(address(registry));

        vault.setSlashingCoordinator(address(slasher));
        vault.setInsuranceReserve(address(reserve));
        registry.setSlashingCoordinator(address(slasher));
        registry.setRestakingVault(address(vault));
        slasher.setVaultAndInsurance(address(vault), address(reserve));

        // Register operator
        vm.prank(operator);
        registry.registerOperator(1000);

        // Deposit stETH to vault and delegate to operator
        stETH.mint(address(this), 100 ether);
        stETH.approve(address(vault), type(uint256).max);
        vault.depositAsset(address(stETH), 100 ether, address(this));

        registry.delegateToOperator(operator, 100 ether);
    }

    function test_DoubleSignSlashing() public {
        bytes32 taskHashA = keccak256("TaskA_Block100");
        bytes32 taskHashB = keccak256("TaskB_Block100_Conflicting");

        bytes32 digestA = SignatureVerifier.toEthSignedMessageHash(
            keccak256(abi.encodePacked(operator, taskHashA, block.chainid))
        );
        bytes32 digestB = SignatureVerifier.toEthSignedMessageHash(
            keccak256(abi.encodePacked(operator, taskHashB, block.chainid))
        );

        (uint8 vA, bytes32 rA, bytes32 sA) = vm.sign(operatorKey, digestA);
        (uint8 vB, bytes32 rB, bytes32 sB) = vm.sign(operatorKey, digestB);

        bytes memory sigA = abi.encodePacked(rA, sA, vA);
        bytes memory sigB = abi.encodePacked(rB, sB, vB);

        uint256 challengerStETHBefore = stETH.balanceOf(challenger);

        vm.prank(challenger);
        uint256 disputeId = slasher.executeDoubleSignSlashing(operator, taskHashA, taskHashB, sigA, sigB);

        ISlashingCoordinator.SlashingRecord memory record = slasher.getDispute(disputeId);
        assertEq(record.operator, operator);
        assertEq(record.challenger, challenger);
        assertEq(record.slashedETHValue, 20 ether); // 20% of 100 ETH

        // Operator stake deducted by 20 ETH
        IOperatorRegistry.OperatorInfo memory info = registry.getOperator(operator);
        assertEq(info.delegatedETHValue, 80 ether);

        // Challenger received 20% of slashed funds = 4 ETH bounty in stETH
        assertGt(stETH.balanceOf(challenger), challengerStETHBefore);
    }

    function test_IdenticalTaskHashReverts() public {
        bytes32 taskHash = keccak256("SameTask");
        vm.expectRevert(SlashingCoordinator.IdenticalTaskHashes.selector);
        slasher.executeDoubleSignSlashing(operator, taskHash, taskHash, "", "");
    }

    function test_DowntimeSlashing() public {
        uint256 missedTasks = 6;
        uint256 epoch = 12;

        vm.prank(challenger);
        uint256 disputeId = slasher.executeDowntimeSlashing(operator, missedTasks, epoch);

        ISlashingCoordinator.SlashingRecord memory record = slasher.getDispute(disputeId);
        assertEq(record.slashedETHValue, 5 ether); // 5% of 100 ETH

        IOperatorRegistry.OperatorInfo memory info = registry.getOperator(operator);
        assertEq(info.delegatedETHValue, 95 ether);
    }

    function test_InsufficientDowntimeReverts() public {
        vm.expectRevert(SlashingCoordinator.InsufficientMissedTasks.selector);
        slasher.executeDowntimeSlashing(operator, 3, 12);
    }
}
