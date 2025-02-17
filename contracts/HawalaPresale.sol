// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

interface IVesting {
    function createVestingSchedule(address, uint256, uint8) external;
}

contract HawalaPresale is Ownable, ReentrancyGuard, Pausable {
    IERC20 public immutable hawalaToken;
    IVesting public immutable vesting;

    uint256 public constant TOTAL_TOKENS_FOR_SALE = 50_000_000e18; // 5% of total supply

    uint256 public totalTokenSold;
    uint256 public totalUSDRaised;

    event Investment(
        address indexed investor,
        bool isBTCPayment,
        uint256 tokenAmount,
        uint256 usdAmount
    );

    constructor(address _token, address _vesting) Ownable(msg.sender) {
        hawalaToken = IERC20(_token);
        vesting = IVesting(_vesting);
    }

    receive() external payable {}

    function invest(
        bool isBTCPayment,
        uint256 usdAmount,
        uint256 tokenAmount,
        address tokenAddress
    ) external payable nonReentrant whenNotPaused {
        require(
            totalTokenSold + tokenAmount <= TOTAL_TOKENS_FOR_SALE,
            "Exceeds round allocation"
        );

        if (!isBTCPayment) {
            if (tokenAddress == address(0)) {
                require(msg.value > 0, "Invalid amount");
            } else {
                IERC20(tokenAddress).transferFrom(
                    msg.sender,
                    address(this),
                    usdAmount
                );
            }
        }
        totalTokenSold += tokenAmount;
        totalUSDRaised += usdAmount;

        vesting.createVestingSchedule(msg.sender, tokenAmount, 1);

        emit Investment(msg.sender, isBTCPayment, tokenAmount, usdAmount);
    }

    function emergencyWithdraw(address token) external onlyOwner {
        if (token == address(0)) {
            uint256 balance = address(this).balance;
            require(balance > 0, "No balance to withdraw");
            (bool success, ) = msg.sender.call{value: balance}("");
            require(success, "Native token withdrawal failed");
        } else {
            uint256 balance = IERC20(token).balanceOf(address(this));
            require(balance > 0, "No tokens to withdraw");
            require(
                IERC20(token).transfer(msg.sender, balance),
                "Token transfer failed"
            );
        }
    }
}
