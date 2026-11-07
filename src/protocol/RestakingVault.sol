// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IRestakingVault} from "../interfaces/IRestakingVault.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {SolETH} from "../tokens/SolETH.sol";
import {ExchangeRateOracle} from "../oracle/ExchangeRateOracle.sol";
import {IOperatorRegistry} from "../interfaces/IOperatorRegistry.sol";
import {SolsticeMath} from "../libraries/SolsticeMath.sol";

contract RestakingVault is IRestakingVault {
    using SolsticeMath for uint256;

    uint256 public constant DEFAULT_UNBONDING_PERIOD = 7 days;
    uint256 public constant BPS_DENOMINATOR = 10_000;

    address public owner;
    address public slashingCoordinator;
    address public instantUnstakePool;
    address public insuranceReserve;
    ExchangeRateOracle public immutable oracle;
    IOperatorRegistry public operatorRegistry;

    SolETH public solETH;
    uint256 public unbondingPeriod;
    bool public paused;

    address[] public supportedAssets;
    mapping(address => AssetConfig) public assetConfigs;
    WithdrawalRequest[] public withdrawalRequests;

    error Unauthorized();
    error ZeroAddress();
    error ContractPaused();
    error AssetAlreadySupported();
    error AssetNotSupported();
    error DepositCapExceeded();
    error InvalidAmount();
    error WithdrawalNotUnlocked();
    error WithdrawalAlreadyClaimed();
    error InsufficientVaultBalance();
    error TransferFailed();
    error ReentrancyGuard();

    uint256 private _locked = 1;
    modifier nonReentrant() {
        if (_locked != 1) revert ReentrancyGuard();
        _locked = 2;
        _;
        _locked = 1;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    constructor(address _oracle) {
        if (_oracle == address(0)) revert ZeroAddress();
        oracle = ExchangeRateOracle(_oracle);
        owner = msg.sender;
        unbondingPeriod = DEFAULT_UNBONDING_PERIOD;
    }

    function setSolETH(address _solETH) external onlyOwner {
        if (_solETH == address(0)) revert ZeroAddress();
        solETH = SolETH(_solETH);
    }

    function setOperatorRegistry(address _operatorRegistry) external onlyOwner {
        if (_operatorRegistry == address(0)) revert ZeroAddress();
        operatorRegistry = IOperatorRegistry(_operatorRegistry);
    }

    function setSlashingCoordinator(address _slashingCoordinator) external onlyOwner {
        if (_slashingCoordinator == address(0)) revert ZeroAddress();
        slashingCoordinator = _slashingCoordinator;
    }

    function setInstantUnstakePool(address _instantUnstakePool) external onlyOwner {
        if (_instantUnstakePool == address(0)) revert ZeroAddress();
        instantUnstakePool = _instantUnstakePool;
    }

    function setInsuranceReserve(address _insuranceReserve) external onlyOwner {
        if (_insuranceReserve == address(0)) revert ZeroAddress();
        insuranceReserve = _insuranceReserve;
    }

    function setUnbondingPeriod(uint256 _newPeriod) external onlyOwner {
        unbondingPeriod = _newPeriod;
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
    }

    function addSupportedAsset(
        address asset,
        uint16 riskHaircutBps,
        uint256 depositCap
    ) external onlyOwner {
        if (asset == address(0)) revert ZeroAddress();
        if (assetConfigs[asset].isSupported) revert AssetAlreadySupported();

        assetConfigs[asset] = AssetConfig({
            isSupported: true,
            riskHaircutBps: riskHaircutBps,
            depositCap: depositCap,
            totalDeposited: 0
        });

        supportedAssets.push(asset);
        emit AssetConfigUpdated(asset, true, riskHaircutBps, depositCap);
    }

    function updateAssetConfig(
        address asset,
        bool isSupported,
        uint16 riskHaircutBps,
        uint256 depositCap
    ) external onlyOwner {
        if (!assetConfigs[asset].isSupported) revert AssetNotSupported();
        assetConfigs[asset].isSupported = isSupported;
        assetConfigs[asset].riskHaircutBps = riskHaircutBps;
        assetConfigs[asset].depositCap = depositCap;

        emit AssetConfigUpdated(asset, isSupported, riskHaircutBps, depositCap);
    }

    function depositAsset(
        address asset,
        uint256 amount,
        address receiver
    ) external override nonReentrant whenNotPaused returns (uint256 shares) {
        AssetConfig storage config = assetConfigs[asset];
        if (!config.isSupported) revert AssetNotSupported();
        if (amount == 0) revert InvalidAmount();
        if (receiver == address(0)) revert ZeroAddress();

        if (config.totalDeposited + amount > config.depositCap) {
            revert DepositCapExceeded();
        }

        uint256 totalETHBefore = totalValueInETH();
        uint256 totalSharesBefore = solETH.totalSupply();

        // Transfer asset to vault
        config.totalDeposited += amount;
        bool success = IERC20(asset).transferFrom(msg.sender, address(this), amount);
        if (!success) revert TransferFailed();

        // Calculate effective ETH value with risk haircut
        uint256 oracleRate = oracle.getRate(asset);
        uint256 assetValueInETH = (amount * oracleRate) / SolsticeMath.WAD;
        uint256 effectiveETHValue = (assetValueInETH * (BPS_DENOMINATOR - config.riskHaircutBps)) / BPS_DENOMINATOR;

        // SolsticeMath virtual share offset to prevent inflation front-running
        shares = SolsticeMath.toSharesDown(effectiveETHValue, totalETHBefore, totalSharesBefore);

        solETH.mint(receiver, shares);

        emit AssetDeposited(receiver, asset, amount, shares);
    }

    function initiateWithdrawal(
        address asset,
        uint256 shares
    ) external override nonReentrant whenNotPaused returns (uint256 withdrawalId) {
        if (shares == 0) revert InvalidAmount();
        AssetConfig storage config = assetConfigs[asset];
        if (!config.isSupported) revert AssetNotSupported();

        uint256 assetAmount = convertSharesToAsset(asset, shares);
        if (assetAmount > config.totalDeposited) revert InsufficientVaultBalance();

        // Burn solETH shares from staker
        solETH.burn(msg.sender, shares);

        withdrawalId = withdrawalRequests.length;
        withdrawalRequests.push(
            WithdrawalRequest({
                staker: msg.sender,
                asset: asset,
                shares: shares,
                assetAmount: assetAmount,
                unlockTimestamp: block.timestamp + unbondingPeriod,
                isClaimed: false
            })
        );

        emit WithdrawalInitiated(withdrawalId, msg.sender, asset, shares, assetAmount);
    }

    function claimWithdrawal(uint256 withdrawalId) external override nonReentrant returns (uint256 amount) {
        if (withdrawalId >= withdrawalRequests.length) revert InvalidAmount();
        WithdrawalRequest storage request = withdrawalRequests[withdrawalId];

        if (msg.sender != request.staker) revert Unauthorized();
        if (request.isClaimed) revert WithdrawalAlreadyClaimed();
        if (block.timestamp < request.unlockTimestamp) revert WithdrawalNotUnlocked();

        request.isClaimed = true;
        amount = request.assetAmount;

        AssetConfig storage config = assetConfigs[request.asset];
        if (config.totalDeposited >= amount) {
            config.totalDeposited -= amount;
        } else {
            config.totalDeposited = 0;
        }

        bool success = IERC20(request.asset).transfer(msg.sender, amount);
        if (!success) revert TransferFailed();

        emit WithdrawalClaimed(withdrawalId, msg.sender, amount);
    }

    function instantUnstakeBurn(address user, uint256 shares) external {
        if (msg.sender != instantUnstakePool) revert Unauthorized();
        solETH.burn(user, shares);
    }

    function slashVaultAsset(address asset, uint256 amount) external override {
        if (msg.sender != slashingCoordinator && msg.sender != owner) revert Unauthorized();
        AssetConfig storage config = assetConfigs[asset];
        if (config.totalDeposited >= amount) {
            config.totalDeposited -= amount;
        } else {
            config.totalDeposited = 0;
        }
        emit SlashedFundsDeducted(asset, amount);
    }

    function slashVaultValue(
        uint256 ethAmount,
        address challenger,
        uint256 bountyReward
    ) external {
        if (msg.sender != slashingCoordinator) revert Unauthorized();

        // Deduct from the first supported asset that has balance
        uint256 remainingETHToSlash = ethAmount;
        for (uint256 i = 0; i < supportedAssets.length && remainingETHToSlash > 0; ) {
            address asset = supportedAssets[i];
            AssetConfig storage config = assetConfigs[asset];
            if (config.totalDeposited > 0) {
                uint256 rate = oracle.getRate(asset);
                uint256 assetValueInETH = (config.totalDeposited * rate) / SolsticeMath.WAD;

                if (assetValueInETH <= remainingETHToSlash) {
                    remainingETHToSlash -= assetValueInETH;
                    uint256 slashedAmount = config.totalDeposited;
                    config.totalDeposited = 0;
                    emit SlashedFundsDeducted(asset, slashedAmount);
                } else {
                    uint256 assetTokensToSlash = (remainingETHToSlash * SolsticeMath.WAD) / rate;
                    config.totalDeposited -= assetTokensToSlash;
                    remainingETHToSlash = 0;
                    emit SlashedFundsDeducted(asset, assetTokensToSlash);
                }
            }
            unchecked {
                ++i;
            }
        }

        // Payout challenger bounty if address provided
        if (challenger != address(0) && bountyReward > 0 && supportedAssets.length > 0) {
            address payoutAsset = supportedAssets[0];
            uint256 rate = oracle.getRate(payoutAsset);
            uint256 bountyAssetAmount = (bountyReward * SolsticeMath.WAD) / rate;
            if (IERC20(payoutAsset).balanceOf(address(this)) >= bountyAssetAmount) {
                IERC20(payoutAsset).transfer(challenger, bountyAssetAmount);
            }
        }
    }

    function convertSharesToAsset(address asset, uint256 shares) public view returns (uint256) {
        uint256 totalETH = totalValueInETH();
        uint256 totalShares = solETH.totalSupply();
        uint256 shareETHValue = SolsticeMath.toAssetsDown(shares, totalETH, totalShares);

        uint256 oracleRate = oracle.getRate(asset);
        return (shareETHValue * SolsticeMath.WAD) / oracleRate;
    }

    function totalValueInETH() public view override returns (uint256 totalETH) {
        uint256 len = supportedAssets.length;
        for (uint256 i = 0; i < len; ) {
            address asset = supportedAssets[i];
            AssetConfig memory config = assetConfigs[asset];
            if (config.totalDeposited > 0) {
                uint256 rate = oracle.getRate(asset);
                uint256 ethValue = (config.totalDeposited * rate) / SolsticeMath.WAD;
                totalETH += (ethValue * (BPS_DENOMINATOR - config.riskHaircutBps)) / BPS_DENOMINATOR;
            }
            unchecked {
                ++i;
            }
        }
    }

    function getAssetConfig(address asset) external view override returns (AssetConfig memory) {
        return assetConfigs[asset];
    }

    function getSupportedAssets() external view returns (address[] memory) {
        return supportedAssets;
    }

    function getWithdrawalCount() external view returns (uint256) {
        return withdrawalRequests.length;
    }
}
