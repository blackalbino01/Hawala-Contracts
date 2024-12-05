// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IVesting {
    function createVestingSchedule(address, uint256, uint8) external;
}

contract HawalaPresale is Ownable, ReentrancyGuard {
    IERC20 public immutable token;
    IERC20 public immutable usdt;
    IVesting public immutable vesting;

    uint256[] public INVESTMENT_LOTS = [
        5000 * 10 ** 6, // 5,000 USDT
        10000 * 10 ** 6, // 10,000 USDT
        20000 * 10 ** 6, // 20,000 USDT
        50000 * 10 ** 6 // 50,000 USDT
    ];

    struct Round {
        uint256 price; // Price in USDT (6 decimals)
        uint256 allocation; // Total tokens for the round
        uint256 sold; // Tokens sold in the round
        bool isActive; // Round status
    }

    Round public currentRound;
    uint256 public roundNumber;

    event RoundStarted(uint256 indexed round, uint256 price);
    event Investment(
        address indexed investor,
        uint256 usdtAmount,
        uint256 tokenAmount
    );

    constructor(
        address _token,
        address _usdt,
        address _vesting,
        address initialOwner
    ) Ownable(initialOwner) {
        token = IERC20(_token);
        usdt = IERC20(_usdt);
        vesting = IVesting(_vesting);
    }

    function startPrivateSale() external onlyOwner {
        require(roundNumber == 0, "Sale already started");
        currentRound = Round({
            price: 500, // $0.005 * 100000
            allocation: 50_000_000 * 10 ** 18,
            sold: 0,
            isActive: true
        });
        roundNumber = 1;
        emit RoundStarted(roundNumber, currentRound.price);
    }

    function invest(uint256 usdtAmount) external nonReentrant {
        require(currentRound.isActive, "Round not active");
        require(isValidLot(usdtAmount), "Invalid investment amount");

        uint256 tokenAmount = calculateTokenAmount(usdtAmount);
        require(
            currentRound.sold + tokenAmount <= currentRound.allocation,
            "Exceeds round allocation"
        );

        require(
            usdt.transferFrom(msg.sender, address(this), usdtAmount),
            "USDT transfer failed"
        );
        currentRound.sold += tokenAmount;

        vesting.createVestingSchedule(
            msg.sender,
            tokenAmount,
            uint8(roundNumber - 1)
        );

        emit Investment(msg.sender, usdtAmount, tokenAmount);

        if (currentRound.sold >= currentRound.allocation) {
            progressToNextRound();
        }
    }

    function isValidLot(uint256 amount) public view returns (bool) {
        if (roundNumber == 1) {
            for (uint256 i = 0; i < INVESTMENT_LOTS.length; i++) {
                if (amount == INVESTMENT_LOTS[i]) return true;
            }
            return false;
        }
        return true;
    }

    function calculateTokenAmount(
        uint256 usdtAmount
    ) public view returns (uint256) {
        return (usdtAmount * 10 ** 12) / currentRound.price;
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

    function withdrawUSDT() external onlyOwner {
        uint256 balance = usdt.balanceOf(address(this));
        require(usdt.transfer(owner(), balance), "Transfer failed");
    }

    function emergencyStop() external onlyOwner {
        currentRound.isActive = false;
    }
}
