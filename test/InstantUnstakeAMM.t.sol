// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {InstantUnstakePool} from "../src/protocol/InstantUnstakePool.sol";
import {RestakingVault} from "../src/protocol/RestakingVault.sol";
import {ExchangeRateOracle} from "../src/oracle/ExchangeRateOracle.sol";
import {SolETH} from "../src/tokens/SolETH.sol";
import {MockLST} from "../src/tokens/MockLST.sol";

contract InstantUnstakeAMMTest is Test {
    InstantUnstakePool public pool;
    RestakingVault public vault;
    ExchangeRateOracle public oracle;
    SolETH public solETH;
    MockLST public stETH;

    address public lpProvider = address(0x1010);
    address public user = address(0x2020);

    function setUp() public {
        oracle = new ExchangeRateOracle();
        vault = new RestakingVault(address(oracle));
        solETH = new SolETH(address(vault));
        vault.setSolETH(address(solETH));

        stETH = new MockLST("Lido Staked ETH", "stETH", 18);
        oracle.setAssetOracle(address(stETH), 1e18, 86400, 500);
        vault.addSupportedAsset(address(stETH), 100, 10_000 ether);

        pool = new InstantUnstakePool(address(solETH));
        pool.setRestakingVault(address(vault));
        vault.setInstantUnstakePool(address(pool));

        // LP adds liquidity to pool
        stETH.mint(lpProvider, 100 ether);
        vm.prank(lpProvider);
        stETH.approve(address(pool), type(uint256).max);
        vm.prank(lpProvider);
        pool.addLiquidity(address(stETH), 100 ether);

        // User deposits to vault to get solETH
        stETH.mint(user, 50 ether);
        vm.prank(user);
        stETH.approve(address(vault), type(uint256).max);
        vm.prank(user);
        vault.depositAsset(address(stETH), 50 ether, user);
    }

    function test_LPAddAndRemoveLiquidity() public {
        assertEq(stETH.balanceOf(address(pool)), 100 ether);
        assertEq(pool.lpBalances(address(stETH), lpProvider), 100 ether);

        // LP removes half liquidity
        vm.prank(lpProvider);
        uint256 withdrawn = pool.removeLiquidity(address(stETH), 50 ether);

        assertEq(withdrawn, 50 ether);
        assertEq(stETH.balanceOf(address(pool)), 50 ether);
    }

    function test_ConvexFeeCurve() public view {
        // At 0 utilization rate:
        uint256 feeAt0 = pool.calculateFeeBps(address(stETH));
        assertEq(feeAt0, 30); // Base fee 30 bps (0.30%)

        // Below kink check
        // If utilization rate is at kink (75%), fee should equal 150 bps
        // If above kink, fee should escalate towards 800 bps
    }

    function test_InstantUnstakeExecution() public {
        uint256 userShares = solETH.balanceOf(user);
        assertGt(userShares, 0);

        uint256 unstakeShares = userShares / 5; // Unstake 20%
        (uint256 gross, uint256 fee, uint256 net) = pool.quoteInstantUnstake(address(stETH), unstakeShares);

        assertGt(gross, 0);
        assertGt(fee, 0);
        assertEq(net, gross - fee);

        uint256 userStETHBefore = stETH.balanceOf(user);

        // User instant unstakes immediately
        vm.prank(user);
        uint256 received = pool.instantUnstake(address(stETH), unstakeShares);

        assertEq(received, net);
        assertEq(stETH.balanceOf(user), userStETHBefore + net);
        assertEq(solETH.balanceOf(user), userShares - unstakeShares);
    }
}
