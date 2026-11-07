// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IInstantUnstakePool {
    event InstantUnstake(
        address indexed user,
        address indexed asset,
        uint256 sharesBurned,
        uint256 grossAmount,
        uint256 feeDeducted,
        uint256 netAmountReceived
    );
    event LiquidityAdded(address indexed provider, address indexed asset, uint256 amount);
    event LiquidityRemoved(address indexed provider, address indexed asset, uint256 amount);

    function instantUnstake(address asset, uint256 shares) external returns (uint256 netAmount);
    function quoteInstantUnstake(address asset, uint256 shares) external view returns (uint256 grossAmount, uint256 feeDeducted, uint256 netAmount);
    function getUtilizationRate(address asset) external view returns (uint256);
}
