// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IVesting {
    function createVestingSchedule(address, uint256, uint8) external;
}

contract HawalaPresale is Ownable, ReentrancyGuard {
    IERC20 public immutable hawalaToken;
    IVesting public immutable vesting;

    struct Round {
        uint256 price;
        uint256 allocation;
        uint256 sold;
        bool isActive;
    }

    Round public currentRound;
    uint8 public roundNumber;
    bool public paused;

    event RoundStarted(uint8 indexed round, uint256 price);
    event Investment(
        address indexed investor,
        bool isBTCPayment,
        uint256 tokenAmount
    );

    modifier whenNotPaused() {
        require(!paused, "Sale is paused");
        _;
    }

    constructor(address _token, address _vesting) Ownable(msg.sender) {
        hawalaToken = IERC20(_token);
        vesting = IVesting(_vesting);
    }

    receive() external payable {}

    function startPrivateSale() external onlyOwner {
        require(roundNumber == 0, "Sale already started");
        currentRound = Round({
            price: 800, // $0.008 * 100000
            allocation: 50_000_000 * 10 ** 18,
            sold: 0,
            isActive: true
        });
        roundNumber = 1;
        emit RoundStarted(roundNumber, currentRound.price);
    }

    function getCurrentRoundInfo()
        external
        view
        returns (
            uint256 price,
            uint256 allocation,
            uint256 sold,
            bool isActive,
            uint8 round
        )
    {
        return (
            currentRound.price,
            currentRound.allocation,
            currentRound.sold,
            currentRound.isActive,
            roundNumber
        );
    }

    function getRoundPrices()
        external
        pure
        returns (
            uint256 privateSalePrice, // $0.008
            uint256 publicSale1Price, // $0.010
            uint256 publicSale2Price, // $0.012
            uint256 publicSale3Price // $0.015
        )
    {
        return (500, 1000, 1200, 1500); // Prices multiplied by 100000
    }

    function getTotalRaised() external view returns (uint256, uint256) {
        uint256 raisedAmount = 0;
        uint256 targetAmount = 2250000;

        // Calculate total raised across all rounds
        if (roundNumber >= 1) {
            // Add current round's raised amount
            raisedAmount += (currentRound.sold * currentRound.price) / 100000;

            // Add amounts from completed rounds
            if (roundNumber > 1) {
                raisedAmount += (50_000_000 * 10 ** 18 * 800) / 100000; // Private Sale ($400,000)
                if (roundNumber > 2) {
                    raisedAmount += (50_000_000 * 10 ** 18 * 1000) / 100000; // Public Sale 1 ($500,000)
                    if (roundNumber > 3) {
                        raisedAmount += (50_000_000 * 10 ** 18 * 1200) / 100000; // Public Sale 2 ($600,000)
                        if (roundNumber > 4) {
                            raisedAmount +=
                                (50_000_000 * 10 ** 18 * 1500) /
                                100000; // Public Sale 3 ($750,000)
                        }
                    }
                }
            }
        }

        return (raisedAmount, targetAmount);
    }

    function invest(
        bool isBTCPayment,
        uint256 paymentAmount,
        uint256 tokenAmount,
        address tokenAddress
    ) external payable nonReentrant whenNotPaused {
        require(currentRound.isActive, "Round not active");
        require(
            currentRound.sold + tokenAmount <= currentRound.allocation,
            "Exceeds round allocation"
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
        currentRound.sold += tokenAmount;

        vesting.createVestingSchedule(msg.sender, tokenAmount, roundNumber);

        if (currentRound.sold >= currentRound.allocation) {
            progressToNextRound();
        }

        emit Investment(msg.sender, isBTCPayment, tokenAmount);
    }
    function progressToNextRound() private {
        if (roundNumber < 4) {
            roundNumber++;
            uint256 newPrice = roundNumber == 2
                ? 1000 // $0.010
                : roundNumber == 3
                    ? 1200 // $0.012
                    : 1500; // $0.015

            currentRound = Round({
                price: newPrice,
                allocation: 50_000_000 * 10 ** 18,
                sold: 0,
                isActive: true
            });

            emit RoundStarted(roundNumber, newPrice);
        } else {
            currentRound.isActive = false;
        }
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
    function togglePause() external onlyOwner {
        paused = !paused;
    }
}
