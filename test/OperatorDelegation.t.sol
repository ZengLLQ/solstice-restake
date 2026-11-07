// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {OperatorRegistry} from "../src/protocol/OperatorRegistry.sol";
import {IOperatorRegistry} from "../src/interfaces/IOperatorRegistry.sol";

contract OperatorDelegationTest is Test {
    OperatorRegistry public registry;

    address public operator1 = address(0xAA11);
    address public operator2 = address(0xBB22);
    address public vaultMock = address(0xCC33);
    address public slasherMock = address(0xDD44);

    function setUp() public {
        registry = new OperatorRegistry();
        registry.setRestakingVault(vaultMock);
        registry.setSlashingCoordinator(slasherMock);
    }

    function test_RegisterOperator() public {
        vm.prank(operator1);
        registry.registerOperator(1000); // 10% commission

        IOperatorRegistry.OperatorInfo memory info = registry.getOperator(operator1);
        assertEq(info.operatorAddress, operator1);
        assertEq(uint256(info.status), uint256(IOperatorRegistry.OperatorStatus.ACTIVE));
        assertEq(info.commissionBps, 1000);
        assertEq(info.healthScore, 10_000);
        assertEq(registry.isOperatorActive(operator1), true);
    }

    function test_CommissionCapRevert() public {
        vm.prank(operator1);
        vm.expectRevert(OperatorRegistry.CommissionTooHigh.selector);
        registry.registerOperator(3500); // 35% > 30% max
    }

    function test_DelegationAndUndelegation() public {
        vm.prank(operator1);
        registry.registerOperator(500);

        // Vault delegates 100 ETH stake to operator1
        vm.prank(vaultMock);
        registry.delegateToOperator(operator1, 100 ether);

        IOperatorRegistry.OperatorInfo memory info = registry.getOperator(operator1);
        assertEq(info.delegatedETHValue, 100 ether);
        assertEq(registry.totalActiveDelegation(), 100 ether);

        // Vault undelegates 40 ETH stake
        vm.prank(vaultMock);
        registry.undelegateFromOperator(operator1, 40 ether);

        info = registry.getOperator(operator1);
        assertEq(info.delegatedETHValue, 60 ether);
        assertEq(registry.totalActiveDelegation(), 60 ether);
    }

    function test_SlashingAndHealthScoreDecay() public {
        vm.prank(operator1);
        registry.registerOperator(500);

        vm.prank(vaultMock);
        registry.delegateToOperator(operator1, 100 ether);

        // Slasher slashes 20 ETH
        vm.prank(slasherMock);
        registry.recordSlashing(operator1, 20 ether);

        IOperatorRegistry.OperatorInfo memory info = registry.getOperator(operator1);
        assertEq(info.delegatedETHValue, 80 ether);
        assertEq(info.healthScore, 7000); // 10000 - 3000
        assertEq(registry.isOperatorActive(operator1), true);

        // Slashing again reduces health further
        vm.prank(slasherMock);
        registry.recordSlashing(operator1, 30 ether);
        info = registry.getOperator(operator1);
        assertEq(info.healthScore, 4000);
        assertEq(registry.isOperatorActive(operator1), false); // Dropped below MIN_ACTIVE_HEALTH_SCORE (5000)
    }

    function test_HealthScoreFreeze() public {
        vm.prank(operator1);
        registry.registerOperator(500);

        // Governance updates health score below threshold
        registry.updateHealthScore(operator1, 4500);
        IOperatorRegistry.OperatorInfo memory info = registry.getOperator(operator1);
        assertEq(uint256(info.status), uint256(IOperatorRegistry.OperatorStatus.FROZEN));

        // Restore health score above threshold
        registry.updateHealthScore(operator1, 8000);
        info = registry.getOperator(operator1);
        assertEq(uint256(info.status), uint256(IOperatorRegistry.OperatorStatus.ACTIVE));
    }
}
