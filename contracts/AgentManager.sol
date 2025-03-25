// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract AgentManager is Ownable, ReentrancyGuard {
    address public hawalaFactory;
    address[] public allAgents;

    mapping(address => bool) public operators;

    struct Transaction {
        address wallet;
        uint256 btcAmount;
        bool orderType;
    }

    struct Agent {
        bool isActive;
        uint256 commissionRate; // in basis points (e.g., 250 = 2.5%)
        uint256 totalCommission;
        uint256 totalBtcVolume;
        uint256 totalUsdtVolume;
    }

    mapping(address => Agent) public agents;
    mapping(address => address) public clientToAgent;
    mapping(address => Transaction[]) public agentToTransactions;

    event AgentSuspended(address indexed agent);
    event AgentApproved(address indexed agent);
    event AgentDeleted(address indexed agent);
    event AgentUpdated(address indexed agent, uint256 commissionRate);
    event AgentRegistered(address indexed agent, uint256 commissionRate);
    event ClientAssigned(address indexed client, address indexed agent);
    event CommissionEarned(
        address indexed agent,
        address indexed client,
        uint256 amount
    );
    event OperatorUpdated(address indexed operator, bool status);

    modifier onlyOperator() {
        require(
            operators[msg.sender] || msg.sender == owner(),
            "Not authorized: operator only"
        );
        _;
    }

    modifier onlyFactory() {
        require(msg.sender == hawalaFactory, "Not authorized: factory only");
        _;
    }

    constructor(address initialOwner) Ownable(initialOwner) {}

    function setHawalaFactory(address _factory) external onlyOwner {
        hawalaFactory = _factory;
    }

    function setOperator(address _operator, bool _status) external onlyOwner {
        operators[_operator] = _status;
        emit OperatorUpdated(_operator, _status);
    }
    function suspendAgent(address agent) external onlyOperator {
        require(agents[agent].isActive, "Agent not active");
        agents[agent].isActive = false;
        emit AgentSuspended(agent);
    }

    function updateAgent(
        address agent,
        uint256 newCommission
    ) external onlyOperator {
        require(agents[agent].isActive, "Agent not active");
        require(newCommission <= 7500, "Commission rate too high");
        agents[agent].commissionRate = newCommission;
        emit AgentUpdated(agent, newCommission);
    }

    function approveAgent(
        address agent,
        uint256 commissionRate
    ) external onlyOperator {
        require(agent != address(0), "Invalid agent address");
        require(commissionRate <= 7500, "Commission rate too high");
        require(!agents[agent].isActive, "Agent already registered and active");

        if (agents[agent].commissionRate == 0) {
            allAgents.push(agent);
            agents[agent] = Agent({
                isActive: true,
                commissionRate: commissionRate,
                totalCommission: 0,
                totalBtcVolume: 0,
                totalUsdtVolume: 0
            });

            emit AgentRegistered(agent, commissionRate);
        } else {
            agents[agent].isActive = true;
            emit AgentApproved(agent);
        }
    }

    function deleteAgent(address agent) external onlyOperator {
        require(agents[agent].commissionRate > 0, "Agent not registered");
        delete agents[agent];

        for (uint i = 0; i < allAgents.length; i++) {
            if (allAgents[i] == agent) {
                allAgents[i] = allAgents[allAgents.length - 1];
                allAgents.pop();
                break;
            }
        }

        emit AgentDeleted(agent);
    }

    function assignClientToAgent(
        address client,
        address agent
    ) external onlyOperator {
        require(agents[agent].isActive, "Agent not active");
        clientToAgent[client] = agent;
        emit ClientAssigned(client, agent);
    }

    function recordTrade(
        address trader,
        uint256 btcAmount,
        uint256 usdtAmount,
        bool isBTCToUSDT
    ) external onlyFactory {
        address agent = clientToAgent[trader];
        if (agent != address(0) && agents[agent].isActive) {
            agentToTransactions[agent].push(
                Transaction({
                    wallet: trader,
                    btcAmount: btcAmount,
                    orderType: isBTCToUSDT
                })
            );
            agents[agent].totalBtcVolume += btcAmount;
            agents[agent].totalUsdtVolume += usdtAmount;
        }
    }

    function getAgentTransactions(
        address agent
    ) external view returns (Transaction[] memory) {
        return agentToTransactions[agent];
    }

    function addCommission(
        address trader,
        uint256 amount
    ) external onlyFactory returns (bool, uint256) {
        address agent = clientToAgent[trader];
        if (agent != address(0) && agents[agent].isActive) {
            uint256 commission = (amount * agents[agent].commissionRate) /
                10000;
            agents[agent].totalCommission += commission;
            emit CommissionEarned(agent, trader, commission);
            return (true, commission);
        }
        return (false, 0);
    }

    function getAgentAddress(
        address trader
    ) external view onlyFactory returns (address) {
        return clientToAgent[trader];
    }

    function isClientAssigned(address client) external view returns (bool) {
        return clientToAgent[client] != address(0);
    }

    function getAllAgentsData()
        external
        view
        returns (
            address[] memory agentAddresses,
            bool[] memory isActive,
            uint256[] memory commissionRates,
            uint256[] memory totalCommissions,
            uint256[] memory btcVolumes,
            uint256[] memory usdtVolumes
        )
    {
        uint256 agentCount = allAgents.length;

        agentAddresses = new address[](agentCount);
        isActive = new bool[](agentCount);
        commissionRates = new uint256[](agentCount);
        totalCommissions = new uint256[](agentCount);
        btcVolumes = new uint256[](agentCount);
        usdtVolumes = new uint256[](agentCount);

        for (uint256 i = 0; i < agentCount; i++) {
            address agentAddr = allAgents[i];
            agentAddresses[i] = agentAddr;
            isActive[i] = agents[agentAddr].isActive;
            commissionRates[i] = agents[agentAddr].commissionRate;
            totalCommissions[i] = agents[agentAddr].totalCommission;
            btcVolumes[i] = agents[agentAddr].totalBtcVolume;
            usdtVolumes[i] = agents[agentAddr].totalUsdtVolume;
        }

        return (
            agentAddresses,
            isActive,
            commissionRates,
            totalCommissions,
            btcVolumes,
            usdtVolumes
        );
    }
}
