pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract BTCSeller {
    IERC20 public usdtToken;
    address public admin;
    uint256 public btcPrice; // Price in USDT per BTC
    uint256 public dailyBTCLimit;
    uint256 public btcSoldToday;
    uint256 public lastResetTimestamp;

    event BTCPurchased(address buyer, uint256 btcAmount, uint256 usdtAmount);

    constructor(
        address _usdtToken,
        uint256 _initialBTCPrice,
        uint256 _dailyBTCLimit
    ) {
        usdtToken = IERC20(_usdtToken);
        admin = msg.sender;
        btcPrice = _initialBTCPrice;
        dailyBTCLimit = _dailyBTCLimit;
        lastResetTimestamp = block.timestamp;
    }

    function buyBTC(uint256 btcAmount) external {
        require(btcAmount > 0, "Amount must be greater than 0");
        require(
            btcSoldToday + btcAmount <= dailyBTCLimit,
            "Exceeds daily limit"
        );

        uint256 usdtAmount = btcAmount * btcPrice;
        require(
            usdtToken.transferFrom(msg.sender, address(this), usdtAmount),
            "USDT transfer failed"
        );

        btcSoldToday += btcAmount;
        emit BTCPurchased(msg.sender, btcAmount, usdtAmount);
    }

    function updateBTCPrice(uint256 newPrice) external onlyAdmin {
        btcPrice = newPrice;
    }

    function resetDailyLimit() external {
        if (block.timestamp >= lastResetTimestamp + 1 days) {
            btcSoldToday = 0;
            lastResetTimestamp = block.timestamp;
        }
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "Only admin can call this function");
        _;
    }
}
