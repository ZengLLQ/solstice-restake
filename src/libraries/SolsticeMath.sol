// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library SolsticeMath {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS_DIVISOR = 10_000;
    uint256 internal constant VIRTUAL_SHARES_OFFSET = 1e3;
    uint256 internal constant VIRTUAL_ASSETS_OFFSET = 1;

    error DivisionByZero();
    error MathOverflow();

    function wadMul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0 || b == 0) return 0;
        return (a * b) / WAD;
    }

    function wadDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        if (b == 0) revert DivisionByZero();
        return (a * WAD) / b;
    }

    function bpsMul(uint256 a, uint256 bps) internal pure returns (uint256) {
        return (a * bps) / BPS_DIVISOR;
    }

    /// @notice Calculates shares minted for a given asset deposit with virtual offset protection
    /// Rounds DOWN in favor of the vault
    function toSharesDown(
        uint256 assets,
        uint256 totalAssets,
        uint256 totalShares
    ) internal pure returns (uint256) {
        return (assets * (totalShares + VIRTUAL_SHARES_OFFSET)) / (totalAssets + VIRTUAL_ASSETS_OFFSET);
    }

    /// @notice Calculates assets required to mint target shares with virtual offset protection
    /// Rounds UP in favor of the vault
    function toAssetsUp(
        uint256 shares,
        uint256 totalAssets,
        uint256 totalShares
    ) internal pure returns (uint256) {
        uint256 numerator = shares * (totalAssets + VIRTUAL_ASSETS_OFFSET);
        uint256 denominator = totalShares + VIRTUAL_SHARES_OFFSET;
        return (numerator + denominator - 1) / denominator;
    }

    /// @notice Calculates assets redeemed for given shares with virtual offset protection
    /// Rounds DOWN in favor of the vault
    function toAssetsDown(
        uint256 shares,
        uint256 totalAssets,
        uint256 totalShares
    ) internal pure returns (uint256) {
        return (shares * (totalAssets + VIRTUAL_ASSETS_OFFSET)) / (totalShares + VIRTUAL_SHARES_OFFSET);
    }

    /// @notice Calculates shares burned for given assets with virtual offset protection
    /// Rounds UP in favor of the vault
    function toSharesUp(
        uint256 assets,
        uint256 totalAssets,
        uint256 totalShares
    ) internal pure returns (uint256) {
        uint256 numerator = assets * (totalShares + VIRTUAL_SHARES_OFFSET);
        uint256 denominator = totalAssets + VIRTUAL_ASSETS_OFFSET;
        return (numerator + denominator - 1) / denominator;
    }

    /// @notice Exponential Moving Average (EMA) smoothing step
    /// alphaBps: weight of new sample (e.g. 2000 = 20%)
    function updateEMA(
        uint256 currentEMA,
        uint256 newSample,
        uint256 alphaBps
    ) internal pure returns (uint256) {
        if (currentEMA == 0) return newSample;
        uint256 weightedSample = (newSample * alphaBps) / BPS_DIVISOR;
        uint256 weightedCurrent = (currentEMA * (BPS_DIVISOR - alphaBps)) / BPS_DIVISOR;
        return weightedSample + weightedCurrent;
    }

    /// @notice Integer square root using Babylonian method
    function sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}
