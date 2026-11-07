// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "../interfaces/IERC20.sol";

contract InsuranceReserve {
    address public owner;
    address public slashingCoordinator;
    address public restakingVault;

    mapping(address => uint256) public assetReserves;
    uint256 public ethReserve;

    event ReserveDeposited(address indexed asset, uint256 amount, address indexed source);
    event PayoutExecuted(address indexed asset, address indexed recipient, uint256 amount);
    event SlashingCoordinatorUpdated(address indexed newCoordinator);
    event RestakingVaultUpdated(address indexed newVault);

    error Unauthorized();
    error ZeroAddress();
    error InsufficientReserveBalance();
    error TransferFailed();

    modifier onlyAuthorized() {
        if (msg.sender != owner && msg.sender != slashingCoordinator && msg.sender != restakingVault) {
            revert Unauthorized();
        }
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    function setSlashingCoordinator(address _slashingCoordinator) external onlyOwner {
        if (_slashingCoordinator == address(0)) revert ZeroAddress();
        slashingCoordinator = _slashingCoordinator;
        emit SlashingCoordinatorUpdated(_slashingCoordinator);
    }

    function setRestakingVault(address _restakingVault) external onlyOwner {
        if (_restakingVault == address(0)) revert ZeroAddress();
        restakingVault = _restakingVault;
        emit RestakingVaultUpdated(_restakingVault);
    }

    function deposit(address asset, uint256 amount) external onlyAuthorized {
        if (asset == address(0)) {
            revert ZeroAddress();
        }
        assetReserves[asset] += amount;
        bool success = IERC20(asset).transferFrom(msg.sender, address(this), amount);
        if (!success) revert TransferFailed();
        emit ReserveDeposited(asset, amount, msg.sender);
    }

    function depositETH() external payable {
        ethReserve += msg.value;
        emit ReserveDeposited(address(0), msg.value, msg.sender);
    }

    receive() external payable {
        ethReserve += msg.value;
        emit ReserveDeposited(address(0), msg.value, msg.sender);
    }

    function payout(address asset, address recipient, uint256 amount) external onlyAuthorized {
        if (recipient == address(0)) revert ZeroAddress();

        if (asset == address(0)) {
            if (ethReserve < amount) revert InsufficientReserveBalance();
            ethReserve -= amount;
            (bool success, ) = payable(recipient).call{value: amount}("");
            if (!success) revert TransferFailed();
        } else {
            if (assetReserves[asset] < amount) revert InsufficientReserveBalance();
            assetReserves[asset] -= amount;
            bool success = IERC20(asset).transfer(recipient, amount);
            if (!success) revert TransferFailed();
        }

        emit PayoutExecuted(asset, recipient, amount);
    }

    function getReserveBalance(address asset) external view returns (uint256) {
        if (asset == address(0)) {
            return ethReserve;
        }
        return assetReserves[asset];
    }
}
