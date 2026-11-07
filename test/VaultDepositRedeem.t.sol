// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/src/Test.sol";
import {RestakingVault} from "../src/protocol/RestakingVault.sol";
import {ExchangeRateOracle} from "../src/oracle/ExchangeRateOracle.sol";
import {SolETH} from "../src/tokens/SolETH.sol";
import {MockLST} from "../src/tokens/MockLST.sol";

contract VaultDepositRedeemTest is Test {
    RestakingVault public vault;
    ExchangeRateOracle public oracle;
    SolETH public solETH;
    MockLST public stETH;
    MockLST public rETH;

    address public alice = address(0x1111);
    address public bob = address(0x2222);
    address public attacker = address(0x9999);

    function setUp() public {
        oracle = new ExchangeRateOracle();
        vault = new RestakingVault(address(oracle));
        solETH = new SolETH(address(vault));
        vault.setSolETH(address(solETH));

        stETH = new MockLST("Lido Staked ETH", "stETH", 18);
        rETH = new MockLST("Rocket Pool ETH", "rETH", 18);

        // Configure oracle feeds (1 stETH = 1.0 ETH, 1 rETH = 1.05 ETH)
        oracle.setAssetOracle(address(stETH), 1e18, 86400, 500);
        oracle.setAssetOracle(address(rETH), 1.05e18, 86400, 500);

        // Add assets to vault: 1% haircut (100 bps) for stETH, 2% (200 bps) for rETH
        vault.addSupportedAsset(address(stETH), 100, 10_000 ether);
        vault.addSupportedAsset(address(rETH), 200, 10_000 ether);

        // Mint tokens to users
        stETH.mint(alice, 100 ether);
        stETH.mint(bob, 100 ether);
        stETH.mint(attacker, 100 ether);
        rETH.mint(alice, 100 ether);

        vm.prank(alice);
        stETH.approve(address(vault), type(uint256).max);
        vm.prank(alice);
        rETH.approve(address(vault), type(uint256).max);

        vm.prank(bob);
        stETH.approve(address(vault), type(uint256).max);

        vm.prank(attacker);
        stETH.approve(address(vault), type(uint256).max);
    }

    function test_InitialDepositAndShareMinting() public {
        vm.prank(alice);
        uint256 shares = vault.depositAsset(address(stETH), 10 ether, alice);

        // 10 stETH with 1% haircut = 9.9 ETH effective value
        // Virtual share offset: (9.9e18 * (0 + 1000)) / (0 + 1) = 9.9e21
        assertGt(shares, 0);
        assertEq(solETH.balanceOf(alice), shares);
        assertEq(stETH.balanceOf(address(vault)), 10 ether);
        assertGt(vault.totalValueInETH(), 0);
    }

    function test_MultiAssetDeposits() public {
        vm.prank(alice);
        vault.depositAsset(address(stETH), 10 ether, alice);

        vm.prank(alice);
        uint256 rETHShares = vault.depositAsset(address(rETH), 10 ether, alice);

        assertGt(rETHShares, 0);
        assertEq(stETH.balanceOf(address(vault)), 10 ether);
        assertEq(rETH.balanceOf(address(vault)), 10 ether);
    }

    function test_InflationAttackImmunity() public {
        // Attacker deposits tiny amount (1 wei) to initiate vault
        vm.prank(attacker);
        uint256 attackerShares = vault.depositAsset(address(stETH), 1, attacker);
        assertGt(attackerShares, 0);

        // Attacker attempts donation attack: directly transfers 10 ether to vault
        vm.prank(attacker);
        stETH.transfer(address(vault), 10 ether);

        // Victim (Alice) deposits 5 ether
        vm.prank(alice);
        uint256 aliceShares = vault.depositAsset(address(stETH), 5 ether, alice);

        // In naive ERC-4626, Alice would receive 0 shares due to share price manipulation.
        // With SolsticeMath virtual offset (1000 shares, 1 asset), Alice receives non-zero shares!
        assertGt(aliceShares, 0);
        assertGt(aliceShares, attackerShares);
    }

    function test_QueuedWithdrawalCycle() public {
        vm.prank(alice);
        uint256 shares = vault.depositAsset(address(stETH), 20 ether, alice);

        // Initiate withdrawal
        vm.prank(alice);
        uint256 withdrawalId = vault.initiateWithdrawal(address(stETH), shares / 2);

        // Claiming before 7 days must revert
        vm.prank(alice);
        vm.expectRevert(RestakingVault.WithdrawalNotUnlocked.selector);
        vault.claimWithdrawal(withdrawalId);

        // Warp time forward 7 days + 1 second
        vm.warp(block.timestamp + 7 days + 1);

        uint256 stETHBalanceBefore = stETH.balanceOf(alice);
        vm.prank(alice);
        uint256 claimedAmount = vault.claimWithdrawal(withdrawalId);

        assertGt(claimedAmount, 0);
        assertEq(stETH.balanceOf(alice), stETHBalanceBefore + claimedAmount);

        // Double claim must revert
        vm.prank(alice);
        vm.expectRevert(RestakingVault.WithdrawalAlreadyClaimed.selector);
        vault.claimWithdrawal(withdrawalId);
    }

    function test_DepositCapEnforcement() public {
        // Update deposit cap to 5 ether
        vault.updateAssetConfig(address(stETH), true, 100, 5 ether);

        vm.prank(alice);
        vault.depositAsset(address(stETH), 4 ether, alice);

        // Exceeding 5 ether cap must revert
        vm.prank(alice);
        vm.expectRevert(RestakingVault.DepositCapExceeded.selector);
        vault.depositAsset(address(stETH), 2 ether, alice);
    }

    function test_UnsupportedAssetRevert() public {
        MockLST fakeLST = new MockLST("Fake LST", "fLST", 18);
        fakeLST.mint(alice, 10 ether);
        vm.prank(alice);
        fakeLST.approve(address(vault), type(uint256).max);

        vm.prank(alice);
        vm.expectRevert(RestakingVault.AssetNotSupported.selector);
        vault.depositAsset(address(fakeLST), 1 ether, alice);
    }
}
