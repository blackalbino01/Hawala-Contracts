// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract HawalaFactory is Ownable, ReentrancyGuard, Pausable {
    IERC20 public usdtToken;
    address private operator;

    struct Trade {
        bytes32 id;
        address creator;
        uint256 btcAmount; // Amount in wei (1e18)
        uint256 usdtAmount; // Amount in wei (1e18)
        uint256 price; // USDT per BTC in wei
        bool isBTCtoUSDT; // true if market price, false if fixed
        bool isMarketPrice; // true if market price, false if fixed
        TradeStatus status;
        uint256 creationTime;
        uint256 btcFee; // Fee in satoshis
        uint256 usdtFee; // Fee converted to USDT in wei
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
    uint256 public cashback_rate;
    uint256 public minMarketTradeSize;
    uint256 public minFixedTradeSize;
    uint256 public largeOrderThreshold;

    mapping(bytes32 => Trade) public trades;
    mapping(address => uint256) public tradingVolume;
    mapping(address => bool) public blockedWallets;
    mapping(address => address[]) public agentToClients;
    mapping(address => address) private clientToAgent;
    mapping(address => Agent) public agents;
    mapping(address => bool) public operators;

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
        uint256 executedBtcAmount,
        uint256 executedUsdtAmount,
        uint256 remainingBtcAmount
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
    event AgentSuspended(address indexed agent);
    event AgentDeleted(address indexed agent);
    event AgentApproved(address indexed agent);
    event OperatorUpdated(address indexed operator, bool status);

    modifier notBlocked() {
        require(!blockedWallets[msg.sender], "Wallet is blocked");
        _;
    }

    modifier onlyOperator() {
        require(operators[msg.sender], "Not authorized");
        _;
    }

    constructor(
        address _usdtToken,
        address initialOwner
    ) Ownable(initialOwner) {
        usdtToken = IERC20(_usdtToken);
    }

    function createTrade(
        uint256 btcAmount,
        uint256 usdtAmount,
        uint256 price,
        bool isBTCtoUSDT,
        bool isMarketPrice,
        string memory btcAddress
    ) external nonReentrant whenNotPaused returns (bytes32) {
        require(
            btcAmount > 0 && usdtAmount > 0 && price > 0,
            "Invalid amounts"
        );
        require(
            usdtAmount >=
                (isMarketPrice ? minMarketTradeSize : minFixedTradeSize),
            "Below minimum trade size"
        );
        require(
            usdtAmount < largeOrderThreshold,
            "Amount exceeds large order threshold"
        );

        bytes32 tradeId = keccak256(
            abi.encodePacked(block.timestamp, msg.sender, btcAmount, usdtAmount)
        );

        trades[tradeId] = Trade({
            id: tradeId,
            creator: msg.sender,
            btcAmount: btcAmount,
            usdtAmount: usdtAmount,
            price: price,
            isBTCtoUSDT: isBTCtoUSDT,
            isMarketPrice: isMarketPrice,
            status: blockedWallets[msg.sender]
                ? TradeStatus.Cancelled
                : TradeStatus.Open,
            creationTime: block.timestamp,
            btcFee: 0,
            usdtFee: 0,
            btcAddress: btcAddress
        });

        allTradeIds.push(tradeId);

        if (!isBTCtoUSDT) {
            require(
                usdtToken.transferFrom(msg.sender, address(this), usdtAmount),
                "USDT transfer to escrow failed"
            );
        }

        emit TradeCreated(tradeId, msg.sender, isMarketPrice, isBTCtoUSDT);
        return tradeId;
    }

    function executeTrade(
        bytes32 tradeId,
        uint256 amount
    ) external nonReentrant whenNotPaused notBlocked {
        Trade storage trade = trades[tradeId];
        require(trade.status == TradeStatus.Open, "Trade not open");
        require(amount > 0, "Invalid amount");
        require(amount <= trade.btcAmount, "Execution amount high");
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
        uint256 usdtAmount = (amount * trade.price) / 1e18;
        require(usdtAmount <= trade.usdtAmount, "Invalid USDT amount");

        (uint256 btcFee, uint256 usdtFee) = calculateFees(
            amount,
            trade.price,
            trade.isMarketPrice
        );

        trade.btcFee = btcFee;
        trade.usdtFee = usdtFee;

        address agent = clientToAgent[msg.sender];
        if (agent != address(0) && agents[agent].isActive) {
            uint256 agentCommission = (usdtFee * agents[agent].commissionRate) /
                10000;
            agents[agent].totalCommission += agentCommission;
            require(
                usdtToken.transfer(agent, agentCommission),
                "Agent commission transfer failed"
            );
        }

        uint256 amountAfterFee = usdtAmount - usdtFee;

        if (trade.isBTCtoUSDT) {
            require(
                usdtToken.transferFrom(msg.sender, address(this), usdtAmount),
                "USDT transfer failed"
            );
            require(
                usdtToken.transfer(trade.creator, amountAfterFee),
                "USDT transfer failed"
            );
        } else {
            require(
                usdtToken.transfer(msg.sender, amountAfterFee),
                "USDT transfer failed"
            );
        }

        if (trade.isMarketPrice && cashback_rate > 0) {
            uint256 cashback = (usdtFee * cashback_rate) / 100;
            require(
                usdtToken.transfer(msg.sender, cashback),
                "Cashback failed"
            );
        }

        tradingVolume[msg.sender] += usdtAmount;
        tradingVolume[trade.creator] += usdtAmount;
        trade.btcAmount -= amount;
        trade.usdtAmount -= usdtAmount;

        if (trade.btcAmount == 0) {
            trade.status = TradeStatus.Completed;
        }

        emit TradeExecuted(
            tradeId,
            msg.sender,
            trade.creator,
            amount,
            usdtAmount,
            trade.btcAmount
        );
    }

    function getOpenOrders()
        external
        view
        returns (
            bytes32[] memory orderIds,
            uint256[] memory prices,
            uint256[] memory usdtAmounts,
            uint256[] memory btcAmounts,
            bool[] memory isBTCtoUSDTs,
            bool[] memory isMarketPrices,
            address[] memory creators,
            string[] memory btcAddresses,
            TradeStatus[] memory statusses
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
        usdtAmounts = new uint256[](count);
        btcAmounts = new uint256[](count);
        isBTCtoUSDTs = new bool[](count);
        isMarketPrices = new bool[](count);
        creators = new address[](count);
        btcAddresses = new string[](count);
        statusses = new TradeStatus[](count);

        uint256 index = 0;
        for (uint256 i = 0; i < allTradeIds.length; i++) {
            Trade storage trade = trades[allTradeIds[i]];
            if (trade.status == TradeStatus.Open) {
                orderIds[index] = allTradeIds[i];
                prices[index] = trade.price;
                usdtAmounts[index] = trade.usdtAmount;
                btcAmounts[index] = trade.btcAmount;
                isBTCtoUSDTs[index] = trade.isBTCtoUSDT;
                isMarketPrices[index] = trade.isMarketPrice;
                creators[index] = trade.creator;
                btcAddresses[index] = trade.btcAddress;
                statusses[index] = trade.status;

                index++;
            }
        }
    }

    function updateOperator(
        address _operator,
        bool _status
    ) external onlyOwner {
        operators[_operator] = _status;
        emit OperatorUpdated(_operator, _status);
    }

    function registerAgent(
        address agent,
        uint256 commissionRate
    ) external onlyOperator {
        require(commissionRate <= 7500, "Max 75% commission");
        require(!agents[agent].isActive, "Agent already registered");

        agents[agent] = Agent({
            isActive: true,
            commissionRate: commissionRate,
            totalCommission: 0
        });
        emit AgentRegistered(agent, commissionRate);
    }

    function assignClientToAgent(address client) external onlyOperator {
        require(agents[msg.sender].isActive, "Invalid agent");
        require(clientToAgent[client] == address(0), "Client already assigned");
        clientToAgent[client] = msg.sender;
        agentToClients[msg.sender].push(client);

        emit ClientAssigned(client, msg.sender);
    }

    function suspendAgent(address agent) external onlyOperator {
        require(agents[agent].isActive, "Agent not active");
        agents[agent].isActive = false;
        emit AgentSuspended(agent);
    }

    function deleteAgent(address agent) external onlyOperator {
        require(
            agents[agent].isActive || !agents[agent].isActive,
            "Agent doesn't exist"
        );

        if (agents[agent].totalCommission > 0) {
            require(
                usdtToken.transfer(agent, agents[agent].totalCommission),
                "Commission transfer failed"
            );
        }

        address[] storage clients = agentToClients[agent];
        for (uint i = 0; i < clients.length; i++) {
            delete clientToAgent[clients[i]];
        }

        delete agentToClients[agent];
        delete agents[agent];

        emit AgentDeleted(agent);
    }

    function approveAgent(address agent) external onlyOperator {
        require(!agents[agent].isActive, "Agent is active");
        agents[agent].isActive = true;
        emit AgentApproved(agent);
    }

    function blockWallet(address wallet) external onlyOperator {
        blockedWallets[wallet] = true;
        emit WalletBlocked(wallet);
    }

    function unblockWallet(address wallet) external onlyOperator {
        blockedWallets[wallet] = false;
        emit WalletUnblocked(wallet);
    }

    function cancelTrade(bytes32 tradeId) external notBlocked {
        Trade storage trade = trades[tradeId];
        require(msg.sender == trade.creator, "Not trade creator");
        require(trade.status == TradeStatus.Open, "Trade not open");

        trade.status = TradeStatus.Cancelled;

        if (!trade.isBTCtoUSDT) {
            require(
                usdtToken.transfer(trade.creator, trade.usdtAmount),
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
        _pause();
    }

    function resumeTrading() external onlyOwner {
        _unpause();
    }

    function withdrawFees(uint256 amount) external onlyOwner {
        require(usdtToken.transfer(owner(), amount), "Transfer failed");

        emit FeesWithdrawn(amount);
    }

    function emergencyWithdraw() external onlyOwner whenPaused {
        uint256 balance = usdtToken.balanceOf(address(this));
        require(usdtToken.transfer(owner(), balance), "Transfer failed");

        emit EmergencyWithdrawal(balance);
    }

    function calculateFees(
        uint256 btcAmount,
        uint256 price,
        bool isMarketPrice
    ) internal view returns (uint256 btcFee, uint256 usdtFee) {
        uint256 feeRate = isMarketPrice ? marketFee : fixedFee;
        btcFee = (btcAmount * feeRate) / 10000;

        usdtFee = (btcFee * price) / 1e8;
    }
}
