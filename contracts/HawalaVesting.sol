// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./HawalaToken.sol";

contract HawalaVesting is Ownable, ReentrancyGuard {
    HawalaToken public immutable token;
    address public presaleContract;

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
        PUBLIC_SALE,
        DEX,
        CEX,
        TRADING_AIRDROP,
        MARKETING,
        AIRDROP,
        DEV,
        TEAM
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
    event PresaleContractUpdated(address indexed newPresaleContract);

    modifier onlyAuthorized() {
        require(
            msg.sender == owner() || msg.sender == presaleContract,
            "Not authorized"
        );
        _;
    }

    constructor(address _token) Ownable(msg.sender) {
        token = HawalaToken(_token);
    }

    function createVestingSchedule(
        address beneficiary,
        uint256 amount,
        VestingType vestingType
    ) external onlyAuthorized {
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

        if (vestingType == VestingType.PUBLIC_SALE) {
            token.transfer(beneficiary, amount);

            token.setVestingSchedule(
                beneficiary,
                amount,
                uint8(vestingType),
                vestingDuration,
                cliffDuration
            );
        }

        emit ScheduleCreated(beneficiary, vestingType, amount);
    }

    function setPresaleContract(address _presaleContract) external onlyOwner {
        require(_presaleContract != address(0), "Invalid address");
        presaleContract = _presaleContract;
        emit PresaleContractUpdated(_presaleContract);
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
        if (vestingType == VestingType.PUBLIC_SALE) return 270 days; // 9 months
        if (vestingType == VestingType.AIRDROP) return 360 days; // 12 months
        if (vestingType == VestingType.DEV) return 360 days; // 12 months
        if (vestingType == VestingType.TEAM) return 0; // 12 months
        if (
            vestingType == VestingType.DEX ||
            vestingType == VestingType.CEX ||
            vestingType == VestingType.MARKETING ||
            vestingType == VestingType.TRADING_AIRDROP
        ) return 0; // Unlocked

        revert("Invalid vesting type");
    }

    function claim() external nonReentrant {
        VestingSchedule storage schedule = vestingSchedules[msg.sender];
        require(block.timestamp >= schedule.cliffEnd, "Cliff period active");

        uint256 claimable = calculateClaimable(schedule);
        require(claimable > 0, "Nothing to claim");

        schedule.lastClaim = block.timestamp;
        schedule.amountClaimed += claimable;

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
