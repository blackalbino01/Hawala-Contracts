// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract HawalaVesting is Ownable, ReentrancyGuard {
    IERC20 public immutable token;

    struct VestingSchedule {
        uint256 totalAmount;
        uint256 cliffEnd;
        uint256 vestingEnd;
        uint256 lastClaim;
        uint256 amountClaimed;
        bool isActive;
        VestingType vestingType;
    }

    enum VestingType {
        PRIVATE_SALE,
        PUBLIC_SALE_1,
        PUBLIC_SALE_2,
        PUBLIC_SALE_3,
        DEX,
        CEX,
        TRADING_AIRDROP,
        MARKETING,
        AIRDROP,
        DEV
    }

    mapping(address => VestingSchedule) public vestingSchedules;

    uint256 private constant MONTH = 30 days;
    uint256 private constant CLIFF = 90 days;
    uint256 private constant TRADING_LOCK = 270 days;

    event ScheduleCreated(
        address indexed beneficiary,
        VestingType vestingType,
        uint256 amount
    );
    event TokensClaimed(address indexed beneficiary, uint256 amount);

    constructor(address _token, address initialOwner) Ownable(initialOwner) {
        token = IERC20(_token);
    }

    function createVestingSchedule(
        address beneficiary,
        uint256 amount,
        VestingType vestingType
    ) external onlyOwner {
        require(beneficiary != address(0), "Invalid address");
        require(amount > 0, "Amount must be > 0");

        uint256 cliffDuration = getCliffDuration(vestingType);
        uint256 vestingDuration = getVestingDuration(vestingType);

        vestingSchedules[beneficiary] = VestingSchedule({
            totalAmount: amount,
            cliffEnd: block.timestamp + cliffDuration,
            vestingEnd: block.timestamp + cliffDuration + vestingDuration,
            lastClaim: block.timestamp + cliffDuration,
            amountClaimed: 0,
            isActive: true,
            vestingType: vestingType
        });

        emit ScheduleCreated(beneficiary, vestingType, amount);
    }

    function getCliffDuration(
        VestingType vestingType
    ) private pure returns (uint256) {
        if (vestingType == VestingType.TRADING_AIRDROP) return TRADING_LOCK;
        if (
            vestingType == VestingType.DEX ||
            vestingType == VestingType.CEX ||
            vestingType == VestingType.MARKETING
        ) return 0;
        return CLIFF;
    }

    function getVestingDuration(
        VestingType vestingType
    ) private pure returns (uint256) {
        if (
            vestingType == VestingType.DEX ||
            vestingType == VestingType.CEX ||
            vestingType == VestingType.MARKETING
        ) return 0;
        if (vestingType == VestingType.TRADING_AIRDROP) return 0;
        if (vestingType == VestingType.AIRDROP) return 300 days; // 10 months

        if (vestingType == VestingType.DEV) return 240 days; // 8 months

        return 360 days; // 12 months for all sales rounds
    }

    function claim() external nonReentrant {
        VestingSchedule storage schedule = vestingSchedules[msg.sender];
        require(schedule.isActive, "No active schedule");
        require(block.timestamp >= schedule.cliffEnd, "Cliff period active");

        uint256 claimable = calculateClaimable(schedule);
        require(claimable > 0, "Nothing to claim");

        schedule.lastClaim = block.timestamp;
        schedule.amountClaimed += claimable;

        if (schedule.amountClaimed >= schedule.totalAmount) {
            schedule.isActive = false;
        }

        require(token.transfer(msg.sender, claimable), "Transfer failed");
        emit TokensClaimed(msg.sender, claimable);
    }

    function calculateClaimable(
        VestingSchedule storage schedule
    ) private view returns (uint256) {
        if (!schedule.isActive) return 0;

        if (
            schedule.vestingType == VestingType.DEX ||
            schedule.vestingType == VestingType.CEX ||
            schedule.vestingType == VestingType.MARKETING
        ) {
            return schedule.totalAmount - schedule.amountClaimed;
        }

        if (schedule.vestingType == VestingType.TRADING_AIRDROP) {
            if (block.timestamp >= schedule.cliffEnd) {
                return schedule.totalAmount - schedule.amountClaimed;
            }
            return 0;
        }

        if (block.timestamp < schedule.cliffEnd) return 0;

        uint256 monthsPassed = (block.timestamp - schedule.lastClaim) / MONTH;
        uint256 monthlyAmount = schedule.totalAmount / 12;
        uint256 claimable = monthsPassed * monthlyAmount;

        if (block.timestamp >= schedule.vestingEnd) {
            return schedule.totalAmount - schedule.amountClaimed;
        }

        return claimable;
    }
}
