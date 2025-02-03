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

    struct PriceTier {
        uint96 minInvestment;
        uint96 price;
        bool isActive;
    }

    PriceTier[4] private priceTiers;

    uint256 public constant TOTAL_TOKENS_FOR_SALE = 50_000_000e18; // 5% of total supply

    uint256 public totalTokenSold;

    event Investment(
        address indexed investor,
        bool isBTCPayment,
        uint256 tokenAmount
    );

    constructor(address _token, address _vesting) Ownable(msg.sender) {
        hawalaToken = IERC20(_token);
        vesting = IVesting(_vesting);

        priceTiers[0] = PriceTier(50000e18, 800, true); // $50,000+ = $0.008
        priceTiers[1] = PriceTier(25000e18, 1000, true); // $25,000+ = $0.010
        priceTiers[2] = PriceTier(10000e18, 1200, true); // $10,000+ = $0.012
        priceTiers[3] = PriceTier(250e18, 1500, true); // $250+ = $0.015
    }

    receive() external payable {}

    function getTokenPrice(
        uint256 investmentAmount
    ) public view returns (uint256) {
        for (uint256 i = 0; i < priceTiers.length; i++) {
            if (
                priceTiers[i].isActive &&
                investmentAmount >= priceTiers[i].minInvestment
            ) {
                return priceTiers[i].price;
            }
        }
        revert("Below minimum investment");
    }

    function invest(
        bool isBTCPayment,
        uint256 paymentAmount,
        uint256 tokenAmount,
        address tokenAddress
    ) external payable nonReentrant whenNotPaused {
        require(
            totalTokenSold + tokenAmount <= TOTAL_TOKENS_FOR_SALE,
            "Exceeds round allocation"
        );
        uint256 price = getTokenPrice(paymentAmount);
        require(
            tokenAmount == (paymentAmount * 100000) / price,
            "Invalid token amount"
        );

        if (!isBTCPayment) {
            if (msg.value > 0) {
                require(msg.value == paymentAmount, "Invalid amount");
            } else {
                IERC20(tokenAddress).transferFrom(
                    msg.sender,
                    address(this),
                    paymentAmount
                );
            }
        }
        totalTokenSold += tokenAmount;

        vesting.createVestingSchedule(msg.sender, tokenAmount, 1);

        emit Investment(msg.sender, isBTCPayment, tokenAmount);
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

    function updatePriceTier(
        uint8 index,
        uint96 minInvestment,
        uint96 price
    ) external onlyOwner {
        require(index < priceTiers.length, "Invalid tier index");
        priceTiers[index] = PriceTier(minInvestment, price, true);
    }
}
