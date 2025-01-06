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
        bool isBTCtoUSDT;
        bool isMarketPrice;
        uint256 creationTime;
        TradeStatus status;
        string btcAddress;
    }

    struct Agent {
        bool isActive;
        uint256 commissionRate;
        uint256 totalCommission;
    }

    enum TradeStatus {
        Open,
        Completed,
        Cancelled
    }

    // Constants
    uint256 public constant MARKET_TRADE_TIMEOUT = 1 hours;
    uint256 public constant FIXED_TRADE_TIMEOUT = 24 hours;

    // Configurable parameters
    uint256 public marketFee = 25; // 0.25%
    uint256 public fixedFee = 200; // 2.00%
    uint256 public cashback_rate = 50; // 50% of fee
    uint256 public minMarketTradeSize;
    uint256 public minFixedTradeSize;
    uint256 public largeOrderThreshold;

    // Circuit breaker
    bool public tradingPaused;
    uint256 public lastPauseTime;

    mapping(bytes32 => Trade) public trades;
    mapping(address => uint256) public tradingVolume;
    mapping(address => bool) public blockedWallets;
    mapping(address => address) public clientToAgent;
    mapping(address => Agent) public agents;

    bytes32[] public allTradeIds;

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
        uint256 amount
    );
    event TradeCancelled(bytes32 indexed tradeId);
    event TradingPaused(uint256 timestamp);
    event TradingResumed(uint256 timestamp);
    event WalletBlocked(address indexed wallet);
    event WalletUnblocked(address indexed wallet);
    event AgentRegistered(address indexed agent, uint256 commissionRate);
    event ClientAssigned(address indexed client, address indexed agent);
    event TradeSizeUpdated(
        uint256 minMarketTradeSize,
        uint256 minFixedTradeSize
    );
    event FeesUpdated(uint256 minMarketFee, uint256 minFixedFee);
    event CashbackUpdated(uint256 cashback_rate);
    event LargeOrderThresholdUpdated(uint256 largeOrderThreshold);
    event FeesWithdrawn(uint256 fees);
    event EmergencyWithdrawal(uint256 withdrawn_amount);

    modifier whenNotPaused() {
        require(!tradingPaused, "Trading is paused");
        _;
    }

    modifier notBlocked() {
        require(!blockedWallets[msg.sender], "Wallet is blocked");
        _;
    }

    constructor(
        address _usdtToken,
        address initialOwner
    ) Ownable(initialOwner) {
        usdtToken = IERC20(_usdtToken);
    }

    function createTrade(
        uint256 amount,
        uint256 price,
        bool isBTCtoUSDT,
        bool isMarketPrice,
        string memory btcAddress
    ) public nonReentrant whenNotPaused returns (bytes32) {
        require(amount > 0, "Invalid amount");
        require(
            amount >= (isMarketPrice ? minMarketTradeSize : minFixedTradeSize),
            "Below minimum trade size"
        );
        require(
            amount < largeOrderThreshold,
            "Amount exceeds large order threshold"
        );
        if (!isMarketPrice) require(price > 0, "Invalid price");

        bytes32 tradeId = keccak256(
            abi.encodePacked(
                block.timestamp,
                msg.sender,
                amount,
                price,
                isMarketPrice ? "market" : "fixed",
                isBTCtoUSDT
            )
        );

        trades[tradeId] = Trade({
            creator: msg.sender,
            amount: amount,
            price: price,
            isBTCtoUSDT: isBTCtoUSDT,
            isMarketPrice: isMarketPrice,
            creationTime: block.timestamp,
            status: TradeStatus.Open,
            btcAddress: btcAddress
        });
        allTradeIds.push(tradeId);

        if (!isBTCtoUSDT) {
            require(
                usdtToken.transferFrom(msg.sender, address(this), amount),
                "USDT transfer to escrow failed"
            );
        }

        emit TradeCreated(tradeId, msg.sender, isMarketPrice, isBTCtoUSDT);
        return tradeId;
    }

    function executeTrade(
        bytes32 tradeId
    ) external nonReentrant whenNotPaused notBlocked {
        Trade storage trade = trades[tradeId];
        require(trade.status == TradeStatus.Open, "Trade not open");
        require(
            block.timestamp <=
                trade.creationTime +
                    (
                        trade.isMarketPrice
                            ? MARKET_TRADE_TIMEOUT
                            : FIXED_TRADE_TIMEOUT
                    ),
            "Trade expired"
        );

        uint256 usdtAmount = trade.amount;
        uint256 fee = trade.isMarketPrice
            ? ((usdtAmount * marketFee) / 10000)
            : ((usdtAmount * fixedFee) / 10000);

        if (clientToAgent[trade.creator] != address(0)) {
            address agent = clientToAgent[trade.creator];
            uint256 agentCommission = (fee * agents[agent].commissionRate) /
                10000;
            agents[agent].totalCommission += agentCommission;
            require(
                usdtToken.transfer(agent, agentCommission),
                "Agent commission transfer failed"
            );
            fee -= agentCommission;
        }

        if (trade.isBTCtoUSDT) {
            require(
                usdtToken.transferFrom(
                    msg.sender,
                    address(this),
                    usdtAmount + fee
                ),
                "USDT transfer failed"
            );
            require(
                usdtToken.transfer(trade.creator, usdtAmount),
                "USDT transfer failed"
            );
        } else {
            require(
                usdtToken.transfer(msg.sender, usdtAmount - fee),
                "USDT transfer failed"
            );
        }

        if (trade.isMarketPrice) {
            uint256 cashback = (fee * cashback_rate) / 100;
            require(
                usdtToken.transfer(msg.sender, cashback),
                "Cashback failed"
            );
        }

        tradingVolume[msg.sender] += usdtAmount;
        tradingVolume[trade.creator] += usdtAmount;
        trade.status = TradeStatus.Completed;

        emit TradeExecuted(tradeId, msg.sender, trade.creator, trade.amount);
    }

    function getOpenOrders()
        external
        view
        returns (
            bytes32[] memory orderIds,
            uint256[] memory prices,
            uint256[] memory amounts,
            bool[] memory isBTCtoUSDTs,
            address[] memory creators,
            string[] memory btcAddresses
        )
    {
        uint256 count = 0;
        for (uint256 i = 0; i < allTradeIds.length; i++) {
            if (trades[allTradeIds[i]].status == TradeStatus.Open) {
                count++;
            }
        }

        orderIds = new bytes32[](count);
        prices = new uint256[](count);
        amounts = new uint256[](count);
        isBTCtoUSDTs = new bool[](count);
        creators = new address[](count);
        btcAddresses = new string[](count);

        uint256 index = 0;
        for (uint256 i = 0; i < allTradeIds.length; i++) {
            Trade storage trade = trades[allTradeIds[i]];
            if (trade.status == TradeStatus.Open) {
                orderIds[index] = allTradeIds[i];
                prices[index] = trade.price;
                amounts[index] = trade.amount;
                isBTCtoUSDTs[index] = trade.isBTCtoUSDT;
                creators[index] = trade.creator;
                btcAddresses[index] = trade.btcAddress;

                index++;
            }
        }
    }

    function registerAgent(
        address agent,
        uint256 commissionRate
    ) external onlyOwner {
        require(commissionRate <= 5000, "Max 50% commission");
        agents[agent] = Agent({
            isActive: true,
            commissionRate: commissionRate,
            totalCommission: 0
        });
        emit AgentRegistered(agent, commissionRate);
    }

    function setClientAgent(address agent) external notBlocked {
        require(agents[agent].isActive, "Invalid agent");
        clientToAgent[msg.sender] = agent;
        emit ClientAssigned(msg.sender, agent);
    }

    function blockWallet(address wallet) external onlyOwner {
        blockedWallets[wallet] = true;
        emit WalletBlocked(wallet);
    }

    function unblockWallet(address wallet) external onlyOwner {
        blockedWallets[wallet] = false;
        emit WalletUnblocked(wallet);
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
                            : FIXED_TRADE_TIMEOUT
                    ),
            "Trade not expired"
        );

        trade.status = TradeStatus.Cancelled;

        if (!trade.isBTCtoUSDT) {
            require(
                usdtToken.transfer(trade.creator, trade.amount),
                "USDT return failed"
            );
        }
        emit TradeCancelled(tradeId);
    }

    function setMinimumTradeSizes(
        uint256 _marketMin,
        uint256 _fixedMin
    ) external onlyOwner {
        require(_marketMin > 0 && _fixedMin > 0, "Invalid Sizes");
        minMarketTradeSize = _marketMin;
        minFixedTradeSize = _fixedMin;

        emit TradeSizeUpdated(_marketMin, _fixedMin);
    }

    function setLargeOrderThreshold(uint256 _threshold) external onlyOwner {
        require(_threshold > 0, "Invalid Threshold");
        largeOrderThreshold = _threshold;

        emit LargeOrderThresholdUpdated(_threshold);
    }

    function setCashBack(uint256 _cashback) external onlyOwner {
        require(_cashback > 0, "Invalid cashback");
        cashback_rate = _cashback;

        emit CashbackUpdated(_cashback);
    }

    function setFees(uint256 _marketFee, uint256 _fixedFee) external onlyOwner {
        require(_marketFee > 0 && _fixedFee > 0, "Invalid fee values");
        marketFee = _marketFee;
        fixedFee = _fixedFee;

        emit FeesUpdated(_marketFee, _fixedFee);
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

        emit FeesWithdrawn(amount);
    }

    function emergencyWithdraw() external onlyOwner {
        require(tradingPaused, "Trading must be paused");
        uint256 balance = usdtToken.balanceOf(address(this));
        require(usdtToken.transfer(owner(), balance), "Transfer failed");

        emit EmergencyWithdrawal(balance);
    }
}
