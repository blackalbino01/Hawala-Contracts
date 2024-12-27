// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract HawalaToken is ERC20, Ownable {
    address public vestingContract;

    struct VestingSchedule {
        uint256 totalAmount;
        uint256 cliffEnd;
        uint256 vestingEnd;
        uint256 lastClaimTime;
        uint256 monthlyAmount;
        uint256 amountClaimed;
        uint8 round;
    }

    mapping(address => mapping(uint8 => VestingSchedule))
        public vestingSchedules;
    mapping(address => uint8[]) public userRounds;

    constructor() Ownable(msg.sender) ERC20("HawalaDex token", "HAWALA") {
        _mint(msg.sender, 1_000_000_000 * 10 ** decimals());
    }

    function setVestingContract(address _vestingContract) external onlyOwner {
        require(_vestingContract != address(0), "Invalid vesting contract");
        vestingContract = _vestingContract;
    }

    function calculateAvailableTokens(
        address account,
        uint8 round
    ) public view returns (uint256) {
        VestingSchedule storage schedule = vestingSchedules[account][round];

        if (block.timestamp < schedule.cliffEnd) return 0;
        if (block.timestamp >= schedule.vestingEnd) return schedule.totalAmount;

        uint256 monthsSinceLastClaim = (block.timestamp -
            schedule.lastClaimTime) / 30 days;
        uint256 newVestedAmount = monthsSinceLastClaim * schedule.monthlyAmount;
        uint256 totalVested = schedule.amountClaimed + newVestedAmount;

        return
            totalVested > schedule.totalAmount
                ? schedule.totalAmount
                : totalVested;
    }

    function setVestingSchedule(
        address investor,
        uint256 amount,
        uint8 round,
        uint256 vestingDuration,
        uint256 cliffDuration
    ) external {
        require(msg.sender == vestingContract, "Only vesting contract");
        require(investor != address(0), "Invalid investor address");

        uint256 monthlyAmount = (amount * 30 days) / vestingDuration;

        vestingSchedules[investor][round] = VestingSchedule({
            totalAmount: amount,
            cliffEnd: block.timestamp + cliffDuration,
            vestingEnd: block.timestamp + cliffDuration + vestingDuration,
            lastClaimTime: block.timestamp + cliffDuration,
            monthlyAmount: monthlyAmount,
            amountClaimed: 0,
            round: round
        });

        userRounds[investor].push(round);
    }

    function getUserRounds(
        address user
    ) external view returns (uint8[] memory) {
        return userRounds[user];
    }

    function _update(
        address from,
        address to,
        uint256 value
    ) internal virtual override {
        if (from != address(0) && from != owner() && from != vestingContract) {
            uint256 totalVested = 0;
            uint256 vestedBalance = 0;

            uint8[] storage rounds = userRounds[from];
            if (rounds.length > 0) {
                for (uint i = 0; i < rounds.length; i++) {
                    VestingSchedule storage schedule = vestingSchedules[from][
                        rounds[i]
                    ];
                    if (block.timestamp >= schedule.cliffEnd) {
                        totalVested += calculateAvailableTokens(
                            from,
                            rounds[i]
                        );
                    }
                    vestedBalance += schedule.totalAmount;
                }

                uint256 freeBalance = balanceOf(from) > vestedBalance
                    ? balanceOf(from) - vestedBalance
                    : 0;
                require(
                    value <= freeBalance + totalVested,
                    "Amount exceeds available tokens"
                );
            }
        }
        super._update(from, to, value);
    }
}
