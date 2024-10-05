// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract BTCMarketplace {
    IERC20 public usdtToken;
    address public recipient;

    event BTCPurchased(address buyer, uint256 amount);

    constructor(
        address _usdtToken,
        address _recipient
    ) {
        usdtToken = IERC20(_usdtToken);
        recipient = _recipient;
    }

    function buyBTC(uint256 amount) external {
        require(amount > 0, "Amount must be greater than 0");
        require(
            usdtToken.transferFrom(msg.sender, recipient, amount),
            "USDT transfer failed"
        );

        emit BTCPurchased(msg.sender, amount);
    }
}
