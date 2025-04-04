// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./AgentManager.sol";

contract HawalaFactory is Ownable, ReentrancyGuard, Pausable {
    IERC20 public usdtToken;
    AgentManager public agentManager;
    address private operator;

    struct Trade {
        bytes32 id;
        address creator;
        uint256 btcAmount;
        uint256 usdtAmount;
        uint256 initialBtcAmount;
        uint256 initialUsdtAmount;
        uint256 price;
        bool isBTCToUSDT;
        bool isMarketPrice;
        TradeStatus status;
        uint256 creationTime;
        string btcAddress;
    }

    enum TradeStatus {
        Open,
        Completed,
        Cancelled
    }

    uint256 public constant MARKET_TRADE_TIMEOUT = 1 hours;
    uint256 public constant FIXED_TRADE_TIMEOUT = 24 hours;
    uint256 public constant MIN_RESIDUAL = 10000000000000; // 0.00001 BTC

    uint256 public marketFee = 25; // 0.25%
    uint256 public fixedFee = 200; // 2.00%
    uint256 public cashback_rate;
    uint256 public minMarketTradeSize;
    uint256 public minFixedTradeSize;
    uint256 public largeOrderThreshold;
    uint256 public platformUSDTFees;

    mapping(bytes32 => Trade) public trades;
    mapping(address => bool) public blockedWallets;
    mapping(address => bool) public operators;

    bytes32[] public allTradeIds;

    event TradeCreated(
        bytes32 indexed tradeId,
        address indexed creator,
        bool isMarketPrice,
        bool isBTCToUSDT
    );
    event TradeExecuted(
        bytes32 indexed tradeId,
        address indexed buyer,
        address indexed seller,
        uint256 executedBtcAmount,
        uint256 executedUsdtAmount,
        uint256 remainingBtcAmount,
        uint256 TradeUSDTFees
    );
    event TradeCancelled(bytes32 indexed tradeId);
    event TradeAutoCancelled(bytes32 indexed tradeId);
    event TradingPaused(uint256 timestamp);
    event TradingResumed(uint256 timestamp);
    event WalletBlocked(address indexed wallet);
    event WalletUnblocked(address indexed wallet);
    event TradeSizeUpdated(
        uint256 minMarketTradeSize,
        uint256 minFixedTradeSize
    );
    event FeesUpdated(uint256 minMarketFee, uint256 minFixedFee);
    event CashbackUpdated(uint256 cashback_rate);
    event LargeOrderThresholdUpdated(uint256 largeOrderThreshold);
    event FeesWithdrawn(uint256 usdtFees);
    event EmergencyWithdrawal(uint256 withdrawn_amount);
    event OperatorUpdated(address indexed operator, bool status);

    modifier notBlocked() {
        require(!blockedWallets[msg.sender], "Wallet is blocked");
        _;
    }

    modifier onlyOperator() {
        require(
            operators[msg.sender] || msg.sender == owner(),
            "Not authorized"
        );
        _;
    }

    constructor(
        address _usdtToken,
        address initialOwner,
        address _agentManager
    ) Ownable(initialOwner) {
        usdtToken = IERC20(_usdtToken);
        agentManager = AgentManager(_agentManager);
    }

    function createTrade(
        uint256 btcAmount,
        uint256 usdtAmount,
        uint256 price,
        bool isBTCToUSDT,
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
            initialBtcAmount: btcAmount,
            initialUsdtAmount: usdtAmount,
            price: price,
            isBTCToUSDT: isBTCToUSDT,
            isMarketPrice: isMarketPrice,
            status: blockedWallets[msg.sender]
                ? TradeStatus.Cancelled
                : TradeStatus.Open,
            creationTime: block.timestamp,
            btcAddress: btcAddress
        });

        allTradeIds.push(tradeId);

        address agent = agentManager.getAgentAddress(msg.sender);

        if (agent != address(0)) {
            agentManager.recordTrade(
                msg.sender,
                btcAmount,
                usdtAmount,
                isBTCToUSDT
            );
        }

        if (!isBTCToUSDT) {
            require(
                usdtToken.transferFrom(msg.sender, address(this), usdtAmount),
                "USDT transfer to escrow failed"
            );
        }

        emit TradeCreated(tradeId, msg.sender, isMarketPrice, isBTCToUSDT);
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

        uint256 usdtFee = calculateFees(
            amount,
            trade.price,
            trade.isMarketPrice
        );

        require(usdtFee <= usdtAmount, "Fee exceeds trade amount");
        uint256 amountAfterFee = usdtAmount - usdtFee;

        (bool hasExecutorAgent, uint256 executorCommission) = agentManager
            .addCommission(msg.sender, usdtFee);
        (bool hasCreatorAgent, uint256 creatorCommission) = agentManager
            .addCommission(trade.creator, usdtFee);

        require(
            (executorCommission + creatorCommission) <= usdtFee,
            "Total commission exceeds fee"
        );

        if (hasExecutorAgent) {
            agentManager.recordTrade(
                msg.sender,
                amount,
                usdtAmount,
                !trade.isBTCToUSDT
            );
        }

        if (trade.isBTCToUSDT) {
            require(
                usdtToken.transferFrom(msg.sender, address(this), usdtAmount),
                "USDT transfer failed"
            );
            require(
                usdtToken.transfer(trade.creator, amountAfterFee),
                "USDT transfer failed"
            );

            if (hasExecutorAgent) {
                usdtToken.transfer(
                    agentManager.getAgentAddress(msg.sender),
                    executorCommission
                );
            }
            if (hasCreatorAgent) {
                usdtToken.transfer(
                    agentManager.getAgentAddress(trade.creator),
                    creatorCommission
                );
            }

            platformUSDTFees +=
                usdtFee -
                executorCommission -
                creatorCommission;
        } else {
            require(
                usdtToken.transfer(msg.sender, amountAfterFee),
                "USDT transfer failed"
            );

            if (hasExecutorAgent) {
                usdtToken.transfer(
                    agentManager.getAgentAddress(msg.sender),
                    executorCommission
                );
            }
            if (hasCreatorAgent) {
                usdtToken.transfer(
                    agentManager.getAgentAddress(trade.creator),
                    creatorCommission
                );
            }

            platformUSDTFees +=
                usdtFee -
                executorCommission -
                creatorCommission;
        }

        if (trade.isMarketPrice && cashback_rate > 0) {
            uint256 cashback = (usdtFee * cashback_rate) / 100;
            require(
                usdtToken.transfer(msg.sender, cashback),
                "Cashback failed"
            );
        }

        trade.btcAmount -= amount;
        trade.usdtAmount -= usdtAmount;

        if (trade.btcAmount == 0 || trade.btcAmount < MIN_RESIDUAL) {
            trade.status = TradeStatus.Completed;
            if (trade.btcAmount > 0) {
                if (!trade.isBTCToUSDT) {
                    uint256 residualUSDT = (trade.btcAmount * trade.price) /
                        1e18;
                    require(
                        usdtToken.transfer(trade.creator, residualUSDT),
                        "Transfer failed"
                    );
                }

                emit TradeAutoCancelled(tradeId);
            }
        }

        emit TradeExecuted(
            tradeId,
            msg.sender,
            trade.creator,
            amount,
            usdtAmount,
            trade.btcAmount,
            usdtFee
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
            bool[] memory isBTCToUSDTs,
            bool[] memory isMarketPrices,
            address[] memory creators,
            string[] memory btcAddresses,
            TradeStatus[] memory statusses
        )
    {
        uint256 count = 0;
        for (uint256 i = 0; i < allTradeIds.length; i++) {
            Trade storage trade = trades[allTradeIds[i]];
            bool isExpired = block.timestamp >
                trade.creationTime +
                    (
                        trade.isMarketPrice
                            ? MARKET_TRADE_TIMEOUT
                            : FIXED_TRADE_TIMEOUT
                    );
            if (
                trades[allTradeIds[i]].status == TradeStatus.Open && !isExpired
            ) {
                count++;
            }
        }

        orderIds = new bytes32[](count);
        prices = new uint256[](count);
        usdtAmounts = new uint256[](count);
        btcAmounts = new uint256[](count);
        isBTCToUSDTs = new bool[](count);
        isMarketPrices = new bool[](count);
        creators = new address[](count);
        btcAddresses = new string[](count);
        statusses = new TradeStatus[](count);

        uint256 index = 0;
        for (uint256 i = 0; i < allTradeIds.length; i++) {
            Trade storage trade = trades[allTradeIds[i]];
            bool isExpired = block.timestamp >
                trade.creationTime +
                    (
                        trade.isMarketPrice
                            ? MARKET_TRADE_TIMEOUT
                            : FIXED_TRADE_TIMEOUT
                    );
            if (trade.status == TradeStatus.Open && !isExpired) {
                orderIds[index] = allTradeIds[i];
                prices[index] = trade.price;
                usdtAmounts[index] = trade.usdtAmount;
                btcAmounts[index] = trade.btcAmount;
                isBTCToUSDTs[index] = trade.isBTCToUSDT;
                isMarketPrices[index] = trade.isMarketPrice;
                creators[index] = trade.creator;
                btcAddresses[index] = trade.btcAddress;
                statusses[index] = trade.status;

                index++;
            }
        }
    }

    function getUserAllOrders(
        address user
    )
        external
        view
        returns (
            bytes32[] memory orderIds,
            uint256[] memory prices,
            uint256[] memory usdtAmounts,
            uint256[] memory btcAmounts,
            bool[] memory isBTCToUSDTs,
            bool[] memory isMarketPrices,
            string[] memory btcAddresses,
            TradeStatus[] memory statuses,
            uint256[] memory creationTimes
        )
    {
        uint256 count = 0;

        for (uint256 i = 0; i < allTradeIds.length; i++) {
            if (trades[allTradeIds[i]].creator == user) {
                count++;
            }
        }

        orderIds = new bytes32[](count);
        prices = new uint256[](count);
        usdtAmounts = new uint256[](count);
        btcAmounts = new uint256[](count);
        isBTCToUSDTs = new bool[](count);
        isMarketPrices = new bool[](count);
        btcAddresses = new string[](count);
        statuses = new TradeStatus[](count);
        creationTimes = new uint256[](count);

        uint256 index = 0;
        for (uint256 i = 0; i < allTradeIds.length; i++) {
            Trade storage trade = trades[allTradeIds[i]];
            if (trade.creator == user) {
                orderIds[index] = trade.id;
                prices[index] = trade.price;
                usdtAmounts[index] = trade.status == TradeStatus.Completed
                    ? trade.initialUsdtAmount
                    : trade.usdtAmount;
                btcAmounts[index] = trade.status == TradeStatus.Completed
                    ? trade.initialBtcAmount
                    : trade.btcAmount;
                isBTCToUSDTs[index] = trade.isBTCToUSDT;
                isMarketPrices[index] = trade.isMarketPrice;
                btcAddresses[index] = trade.btcAddress;
                statuses[index] = trade.status;
                creationTimes[index] = trade.creationTime;
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

    function setAgentManager(address _agentManager) external onlyOwner {
        agentManager = AgentManager(_agentManager);
    }

    function blockWallet(address[] calldata _addresses) external onlyOperator {
        require(_addresses.length > 0, "Empty address array");
        require(_addresses.length <= 100, "Array too large");

        for (uint256 i = 0; i < _addresses.length; i++) {
            require(!blockedWallets[_addresses[i]], "Address already blocked");
            blockedWallets[_addresses[i]] = true;
            emit WalletBlocked(_addresses[i]);
        }
    }

    function unblockWallet(
        address[] calldata _addresses
    ) external onlyOperator {
        require(_addresses.length > 0, "Empty address array");
        require(_addresses.length <= 100, "Array too large");
        for (uint256 i = 0; i < _addresses.length; i++) {
            require(blockedWallets[_addresses[i]], "Address already unblocked");
            blockedWallets[_addresses[i]] = false;
            emit WalletUnblocked(_addresses[i]);
            (_addresses[i]);
        }
    }

    function cancelTrade(bytes32 tradeId) external notBlocked {
        Trade storage trade = trades[tradeId];
        require(msg.sender == trade.creator, "Not trade creator");
        require(trade.status == TradeStatus.Open, "Trade not open");

        trade.status = TradeStatus.Cancelled;

        if (!trade.isBTCToUSDT) {
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
        require(_cashback <= 100, "Cashback rate cannot exceed 100%");
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

    function withdrawFees() external onlyOwner {
        uint256 usdtFees = platformUSDTFees;

        platformUSDTFees = 0;

        require(usdtToken.transfer(owner(), usdtFees), "Transfer failed");

        emit FeesWithdrawn(usdtFees);
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
    ) internal view returns (uint256 usdtFee) {
        uint256 feeRate = isMarketPrice ? marketFee : fixedFee;
        usdtFee = (btcAmount * price * feeRate) / (10000 * 1e18);
    }
}
