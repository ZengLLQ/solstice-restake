// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/src/Test.sol";
import {RestakingVault} from "../src/protocol/RestakingVault.sol";
import {ExchangeRateOracle} from "../src/oracle/ExchangeRateOracle.sol";
import {SolETH} from "../src/tokens/SolETH.sol";
import {MockLST} from "../src/tokens/MockLST.sol";
import {OperatorRegistry} from "../src/protocol/OperatorRegistry.sol";

contract FuzzInvariantsTest is Test {
    RestakingVault public vault;
    ExchangeRateOracle public oracle;
    SolETH public solETH;
    MockLST public stETH;
    OperatorRegistry public registry;

    address public user = address(0x5555);

    function setUp() public {
        oracle = new ExchangeRateOracle();
        vault = new RestakingVault(address(oracle));
        solETH = new SolETH(address(vault));
        vault.setSolETH(address(solETH));

        stETH = new MockLST("Lido Staked ETH", "stETH", 18);
        oracle.setAssetOracle(address(stETH), 1e18, 86400, 500);
        vault.addSupportedAsset(address(stETH), 100, 1_000_000 ether);

        registry = new OperatorRegistry();
        registry.setRestakingVault(address(vault));

        stETH.mint(user, 1_000_000 ether);
        vm.prank(user);
        stETH.approve(address(vault), type(uint256).max);
    }

    function testFuzz_DepositSolvency(uint256 amount) public {
        // Bound amount between 10_000 wei and 10,000 ether
        amount = bound(amount, 1e14, 10_000 ether);

        vm.prank(user);
        uint256 shares = vault.depositAsset(address(stETH), amount, user);

        assertGt(shares, 0);
        assertEq(solETH.balanceOf(user), shares);

        uint256 vaultETHValue = vault.totalValueInETH();
        assertGt(vaultETHValue, 0);

        // Vault should hold exactly amount deposited
        assertEq(stETH.balanceOf(address(vault)), amount);
    }

    function testFuzz_OperatorStakeConservation(uint96 stake1, uint96 stake2) public {
        uint256 s1 = bound(uint256(stake1), 1 ether, 50_000 ether);
        uint256 s2 = bound(uint256(stake2), 1 ether, 50_000 ether);

        address op1 = address(0x1001);
        address op2 = address(0x1002);

        vm.prank(op1);
        registry.registerOperator(500);
        vm.prank(op2);
        registry.registerOperator(800);

        // Vault delegates
        vm.prank(address(vault));
        registry.delegateToOperator(op1, s1);

        vm.prank(address(vault));
        registry.delegateToOperator(op2, s2);

        assertEq(registry.totalActiveDelegation(), s1 + s2);

        // Undelegate partially
        uint256 undelegateAmount = s1 / 2;
        vm.prank(address(vault));
        registry.undelegateFromOperator(op1, undelegateAmount);

        assertEq(registry.totalActiveDelegation(), (s1 - undelegateAmount) + s2);
    }
}
