// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SolsticeMath} from "../libraries/SolsticeMath.sol";

contract ExchangeRateOracle {
    using SolsticeMath for uint256;

    struct AssetOracleData {
        uint256 spotRateWAD;
        uint256 emaRateWAD;
        uint256 lastUpdated;
        uint256 heartbeat;
        uint16 maxDeviationBps;
        bool isActive;
    }

    address public owner;
    mapping(address => AssetOracleData) public assetFeeds;

    event OracleFeedConfigured(
        address indexed asset,
        uint256 initialRate,
        uint256 heartbeat,
        uint16 maxDeviationBps
    );
    event RateUpdated(address indexed asset, uint256 newSpotRate, uint256 newEMARate, uint256 timestamp);
    event RateForced(address indexed asset, uint256 forcedRate, uint256 timestamp);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error Unauthorized();
    error ZeroAddress();
    error AssetNotSupported();
    error StalePriceFeed(uint256 timeDelta, uint256 heartbeat);
    error PriceDeviationExceeded(uint256 deviationBps, uint256 maxAllowedBps);
    error InvalidRate();

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function setAssetOracle(
        address asset,
        uint256 initialRateWAD,
        uint256 heartbeat,
        uint16 maxDeviationBps
    ) external onlyOwner {
        if (asset == address(0)) revert ZeroAddress();
        if (initialRateWAD == 0) revert InvalidRate();

        assetFeeds[asset] = AssetOracleData({
            spotRateWAD: initialRateWAD,
            emaRateWAD: initialRateWAD,
            lastUpdated: block.timestamp,
            heartbeat: heartbeat,
            maxDeviationBps: maxDeviationBps,
            isActive: true
        });

        emit OracleFeedConfigured(asset, initialRateWAD, heartbeat, maxDeviationBps);
    }

    function updateRate(address asset, uint256 newRateWAD) external onlyOwner {
        AssetOracleData storage feed = assetFeeds[asset];
        if (!feed.isActive) revert AssetNotSupported();
        if (newRateWAD == 0) revert InvalidRate();

        uint256 currentSpot = feed.spotRateWAD;
        uint256 diff = newRateWAD > currentSpot ? newRateWAD - currentSpot : currentSpot - newRateWAD;
        uint256 deviationBps = (diff * SolsticeMath.BPS_DIVISOR) / currentSpot;

        if (deviationBps > feed.maxDeviationBps) {
            revert PriceDeviationExceeded(deviationBps, feed.maxDeviationBps);
        }

        // Smooth with 20% alpha (2000 bps)
        uint256 newEMA = feed.emaRateWAD.updateEMA(newRateWAD, 2000);

        feed.spotRateWAD = newRateWAD;
        feed.emaRateWAD = newEMA;
        feed.lastUpdated = block.timestamp;

        emit RateUpdated(asset, newRateWAD, newEMA, block.timestamp);
    }

    function forceUpdateRate(address asset, uint256 newRateWAD) external onlyOwner {
        AssetOracleData storage feed = assetFeeds[asset];
        if (!feed.isActive) revert AssetNotSupported();
        if (newRateWAD == 0) revert InvalidRate();

        feed.spotRateWAD = newRateWAD;
        feed.emaRateWAD = newRateWAD;
        feed.lastUpdated = block.timestamp;

        emit RateForced(asset, newRateWAD, block.timestamp);
    }

    function getRate(address asset) external view returns (uint256) {
        AssetOracleData memory feed = assetFeeds[asset];
        if (!feed.isActive) revert AssetNotSupported();

        uint256 timeDelta = block.timestamp - feed.lastUpdated;
        if (feed.heartbeat > 0 && timeDelta > feed.heartbeat) {
            revert StalePriceFeed(timeDelta, feed.heartbeat);
        }

        return feed.emaRateWAD;
    }

    function getSpotRate(address asset) external view returns (uint256) {
        AssetOracleData memory feed = assetFeeds[asset];
        if (!feed.isActive) revert AssetNotSupported();
        return feed.spotRateWAD;
    }
}
