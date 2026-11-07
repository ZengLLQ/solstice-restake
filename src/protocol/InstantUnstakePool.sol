// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IInstantUnstakePool} from "../interfaces/IInstantUnstakePool.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {SolETH} from "../tokens/SolETH.sol";
import {SolsticeMath} from "../libraries/SolsticeMath.sol";

interface IRestakingVaultForPool {
    function convertSharesToAsset(address asset, uint256 shares) external view returns (uint256);
    function instantUnstakeBurn(address user, uint256 shares) external;
}

contract InstantUnstakePool is IInstantUnstakePool {
    using SolsticeMath for uint256;

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant BASE_FEE_BPS = 30; // 0.30%
    uint256 public constant KINK_UTILIZATION_BPS = 7500; // 75.00%
    uint256 public constant KINK_FEE_BPS = 150; // 1.50%
    uint256 public constant MAX_FEE_BPS = 800; // 8.00%

    address public owner;
    address public restakingVault;
    SolETH public solETH;

    struct PoolLiquidity {
        uint256 totalLiquidity;
        uint256 utilizedLiquidity;
        uint256 totalLPShares;
    }

    mapping(address => PoolLiquidity) public pools;
    mapping(address => mapping(address => uint256)) public lpBalances; // asset => user => lpShares

    error Unauthorized();
    error ZeroAddress();
    error InsufficientPoolLiquidity();
    error InsufficientLPBalance();
    error InvalidAmount();
    error TransferFailed();

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    constructor(address _solETH) {
        if (_solETH == address(0)) revert ZeroAddress();
        solETH = SolETH(_solETH);
        owner = msg.sender;
    }

    function setRestakingVault(address _restakingVault) external onlyOwner {
        if (_restakingVault == address(0)) revert ZeroAddress();
        restakingVault = _restakingVault;
    }

    function addLiquidity(address asset, uint256 amount) external returns (uint256 lpShares) {
        if (asset == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();

        PoolLiquidity storage pool = pools[asset];
        if (pool.totalLiquidity == 0 || pool.totalLPShares == 0) {
            lpShares = amount;
        } else {
            lpShares = (amount * pool.totalLPShares) / pool.totalLiquidity;
        }

        pool.totalLiquidity += amount;
        pool.totalLPShares += lpShares;
        lpBalances[asset][msg.sender] += lpShares;

        bool success = IERC20(asset).transferFrom(msg.sender, address(this), amount);
        if (!success) revert TransferFailed();

        emit LiquidityAdded(msg.sender, asset, amount);
    }

    function removeLiquidity(address asset, uint256 lpShares) external returns (uint256 amount) {
        if (lpShares == 0) revert InvalidAmount();
        PoolLiquidity storage pool = pools[asset];
        if (lpBalances[asset][msg.sender] < lpShares) revert InsufficientLPBalance();

        amount = (lpShares * pool.totalLiquidity) / pool.totalLPShares;
        uint256 availableLiquidity = pool.totalLiquidity - pool.utilizedLiquidity;
        if (amount > availableLiquidity) revert InsufficientPoolLiquidity();

        pool.totalLPShares -= lpShares;
        pool.totalLiquidity -= amount;
        lpBalances[asset][msg.sender] -= lpShares;

        bool success = IERC20(asset).transfer(msg.sender, amount);
        if (!success) revert TransferFailed();

        emit LiquidityRemoved(msg.sender, asset, amount);
    }

    function instantUnstake(address asset, uint256 shares) external override returns (uint256 netAmount) {
        if (shares == 0) revert InvalidAmount();
        (uint256 grossAmount, uint256 feeDeducted, uint256 net) = quoteInstantUnstake(asset, shares);
        netAmount = net;

        PoolLiquidity storage pool = pools[asset];
        uint256 availableLiquidity = pool.totalLiquidity - pool.utilizedLiquidity;
        if (grossAmount > availableLiquidity) revert InsufficientPoolLiquidity();

        // Burn solETH shares from staker via vault
        IRestakingVaultForPool(restakingVault).instantUnstakeBurn(msg.sender, shares);

        // Deduct gross from available liquidity, but keep fee inside totalLiquidity as LP yield
        pool.totalLiquidity -= netAmount;

        bool success = IERC20(asset).transfer(msg.sender, netAmount);
        if (!success) revert TransferFailed();

        emit InstantUnstake(msg.sender, asset, shares, grossAmount, feeDeducted, netAmount);
    }

    function quoteInstantUnstake(
        address asset,
        uint256 shares
    ) public view override returns (uint256 grossAmount, uint256 feeDeducted, uint256 netAmount) {
        grossAmount = IRestakingVaultForPool(restakingVault).convertSharesToAsset(asset, shares);
        uint256 feeBps = calculateFeeBps(asset);

        feeDeducted = (grossAmount * feeBps) / BPS_DENOMINATOR;
        netAmount = grossAmount - feeDeducted;
    }

    function calculateFeeBps(address asset) public view returns (uint256) {
        uint256 u = getUtilizationRate(asset);

        if (u <= KINK_UTILIZATION_BPS) {
            // fee = base + (u / kink_u) * (kink_fee - base)
            return BASE_FEE_BPS + (u * (KINK_FEE_BPS - BASE_FEE_BPS)) / KINK_UTILIZATION_BPS;
        } else {
            // Convex quadratic surge above kink
            uint256 deltaU = u - KINK_UTILIZATION_BPS;
            uint256 excessSpan = BPS_DENOMINATOR - KINK_UTILIZATION_BPS;
            uint256 feeSpread = MAX_FEE_BPS - KINK_FEE_BPS;
            uint256 quadraticIncrease = (deltaU * deltaU * feeSpread) / (excessSpan * excessSpan);
            return KINK_FEE_BPS + quadraticIncrease;
        }
    }

    function getUtilizationRate(address asset) public view override returns (uint256) {
        PoolLiquidity memory pool = pools[asset];
        if (pool.totalLiquidity == 0) return 0;
        return (pool.utilizedLiquidity * BPS_DENOMINATOR) / pool.totalLiquidity;
    }

    function getPool(address asset) external view returns (PoolLiquidity memory) {
        return pools[asset];
    }
}
