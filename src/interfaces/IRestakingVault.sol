// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "./IERC20.sol";

interface IRestakingVault {
    struct AssetConfig {
        bool isSupported;
        uint16 riskHaircutBps; // Risk haircut (e.g., 100 = 1%)
        uint256 depositCap;
        uint256 totalDeposited;
    }

    struct WithdrawalRequest {
        address staker;
        address asset;
        uint256 shares;
        uint256 assetAmount;
        uint256 unlockTimestamp;
        bool isClaimed;
    }

    event AssetDeposited(address indexed staker, address indexed asset, uint256 amount, uint256 sharesMinted);
    event WithdrawalInitiated(uint256 indexed withdrawalId, address indexed staker, address indexed asset, uint256 shares, uint256 amount);
    event WithdrawalClaimed(uint256 indexed withdrawalId, address indexed staker, uint256 amount);
    event AssetConfigUpdated(address indexed asset, bool isSupported, uint16 riskHaircutBps, uint256 depositCap);
    event SlashedFundsDeducted(address indexed asset, uint256 amount);

    function depositAsset(address asset, uint256 amount, address receiver) external returns (uint256 shares);
    function initiateWithdrawal(address asset, uint256 shares) external returns (uint256 withdrawalId);
    function claimWithdrawal(uint256 withdrawalId) external returns (uint256 amount);
    function slashVaultAsset(address asset, uint256 amount) external;
    function totalValueInETH() external view returns (uint256);
    function getAssetConfig(address asset) external view returns (AssetConfig memory);
}
