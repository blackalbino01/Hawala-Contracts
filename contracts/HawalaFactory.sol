// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract HawalaFactory is Ownable, ReentrancyGuard {
    IERC20 public usdtToken;

    struct Trade {
        address creator;
        uint256 amount;
        uint256 price;
        bool isBuyOrder;
        bool isMarketPrice;
        uint256 creationTime;
        TradeStatus status;
        bool isBTCtoUSDT;
    }

    enum TradeStatus {
        Open,
        Completed,
        Cancelled
    }

    // Constants
    uint256 public constant CASHBACK_RATE = 50; // 50% of fee
    uint256 public constant MARKET_TRADE_TIMEOUT = 1 hours;
    uint256 public constant ORDERBOOK_TRADE_TIMEOUT = 24 hours;

    // Configurable parameters
    uint256 public marketFee = 25; // 0.25%
    uint256 public orderBookFee = 200; // 2.00%
    uint256 public minMarketTradeSize;
    uint256 public minOrderBookTradeSize;
    uint256 public largeOrderThreshold;

    // Circuit breaker
    bool public tradingPaused;
    uint256 public lastPauseTime;

    mapping(bytes32 => Trade) public trades;
    mapping(address => uint256) public tradingVolume;

    event TradeCreated(
        bytes32 indexed tradeId,
        address indexed creator,
        bool isMarketPrice,
        bool isBTCtoUSDT
    );
    event TradeExecuted(
        bytes32 indexed tradeId,
        address indexed buyer,
        address indexed seller,
        uint256 amount,
        uint256 price
    );
    event TradeCancelled(bytes32 indexed tradeId);
    event TradingPaused(uint256 timestamp);
    event TradingResumed(uint256 timestamp);

    modifier whenNotPaused() {
        require(!tradingPaused, "Trading is paused");
        _;
    }

    constructor(
        address _usdtToken,
        address initialOwner
    ) Ownable(initialOwner) {
        usdtToken = IERC20(_usdtToken);
    }

    function createMarketTrade(
        uint256 amount,
        uint256 price,
        bool isBuyOrder,
        bool isBTCtoUSDT
    ) external nonReentrant whenNotPaused returns (bytes32) {
        require(amount >= minMarketTradeSize, "Below minimum trade size");
        require(
            amount < largeOrderThreshold,
            "Amount exceeds large order threshold"
        );

        bytes32 tradeId = keccak256(
            abi.encodePacked(
                block.timestamp,
                msg.sender,
                amount,
                price,
                "market",
                isBTCtoUSDT
            )
        );

        trades[tradeId] = Trade({
            creator: msg.sender,
            amount: amount,
            price: price,
            isBuyOrder: isBuyOrder,
            isMarketPrice: true,
            creationTime: block.timestamp,
            status: TradeStatus.Open,
            isBTCtoUSDT: isBTCtoUSDT
        });

        emit TradeCreated(tradeId, msg.sender, true, isBTCtoUSDT);
        return tradeId;
    }

    function createOrderBookTrade(
        uint256 amount,
        uint256 price,
        bool isBuyOrder,
        bool isBTCtoUSDT
    ) external nonReentrant whenNotPaused returns (bytes32) {
        require(amount >= minOrderBookTradeSize, "Below minimum trade size");
        require(
            amount < largeOrderThreshold,
            "Amount exceeds large order threshold"
        );

        bytes32 tradeId = keccak256(
            abi.encodePacked(
                block.timestamp,
                msg.sender,
                amount,
                price,
                "orderbook",
                isBTCtoUSDT
            )
        );

        trades[tradeId] = Trade({
            creator: msg.sender,
            amount: amount,
            price: price,
            isBuyOrder: isBuyOrder,
            isMarketPrice: false,
            creationTime: block.timestamp,
            status: TradeStatus.Open,
            isBTCtoUSDT: isBTCtoUSDT
        });

        emit TradeCreated(tradeId, msg.sender, false, isBTCtoUSDT);
        return tradeId;
    }

    function executeTrade(
        bytes32 tradeId,
        uint256 currentPrice
    ) external nonReentrant whenNotPaused {
        Trade storage trade = trades[tradeId];
        require(trade.status == TradeStatus.Open, "Trade not open");
        require(
            block.timestamp <=
                trade.creationTime +
                    (
                        trade.isMarketPrice
                            ? MARKET_TRADE_TIMEOUT
                            : ORDERBOOK_TRADE_TIMEOUT
                    ),
            "Trade expired"
        );

        uint256 price = trade.isMarketPrice ? currentPrice : trade.price;
        uint256 usdtAmount = trade.amount * price;
        uint256 fee = trade.isMarketPrice
            ? ((usdtAmount * marketFee) / 10000)
            : ((usdtAmount * orderBookFee) / 10000);
        uint256 amount = usdtAmount + fee;

        if (trade.isBuyOrder) {
            require(
                usdtToken.transferFrom(trade.creator, msg.sender, amount),
                "USDT transfer failed"
            );
        } else {
            require(
                usdtToken.transferFrom(msg.sender, trade.creator, amount),
                "USDT transfer failed"
            );
        }

        if (trade.isMarketPrice) {
            uint256 cashback = (fee * CASHBACK_RATE) / 100;
            require(
                usdtToken.transfer(msg.sender, cashback),
                "Cashback failed"
            );
        }

        tradingVolume[msg.sender] += usdtAmount;
        tradingVolume[trade.creator] += usdtAmount;

        trade.status = TradeStatus.Completed;
        emit TradeExecuted(
            tradeId,
            msg.sender,
            trade.creator,
            trade.amount,
            price
        );
    }

    function cancelTrade(bytes32 tradeId) external {
        Trade storage trade = trades[tradeId];
        require(msg.sender == trade.creator, "Not trade creator");
        require(trade.status == TradeStatus.Open, "Trade not open");
        require(
            block.timestamp >
                trade.creationTime +
                    (
                        trade.isMarketPrice
                            ? MARKET_TRADE_TIMEOUT
                            : ORDERBOOK_TRADE_TIMEOUT
                    ),
            "Trade not expired"
        );

        trade.status = TradeStatus.Cancelled;
        emit TradeCancelled(tradeId);
    }

    function setMinimumTradeSizes(
        uint256 _marketMin,
        uint256 _orderBookMin
    ) external onlyOwner {
        minMarketTradeSize = _marketMin;
        minOrderBookTradeSize = _orderBookMin;
    }

    function setLargeOrderThreshold(uint256 _threshold) external onlyOwner {
        largeOrderThreshold = _threshold;
    }

    function setFees(
        uint256 _marketFee,
        uint256 _orderBookFee
    ) external onlyOwner {
        require(_marketFee > 0 && _orderBookFee > 0, "Invalid fee values");
        marketFee = _marketFee;
        orderBookFee = _orderBookFee;
    }

    function pauseTrading() external onlyOwner {
        require(!tradingPaused, "Already paused");
        tradingPaused = true;
        lastPauseTime = block.timestamp;
        emit TradingPaused(block.timestamp);
    }

    function resumeTrading() external onlyOwner {
        require(tradingPaused, "Not paused");
        require(block.timestamp >= lastPauseTime, "Cooldown active");
        tradingPaused = false;
        emit TradingResumed(block.timestamp);
    }

    function withdrawFees(uint256 amount) external onlyOwner {
        require(usdtToken.transfer(owner(), amount), "Transfer failed");
    }

    function emergencyWithdraw() external onlyOwner {
        require(tradingPaused, "Trading must be paused");
        uint256 balance = usdtToken.balanceOf(address(this));
        require(usdtToken.transfer(owner(), balance), "Transfer failed");
    }
}
