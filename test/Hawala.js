const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("HawalaFactory", function () {
    let HawalaFactory, factory, USDT, usdt;
    let owner, seller, buyer, addrs;
    const INITIAL_SUPPLY = ethers.parseUnits("1000000", 6); // 1M USDT

    beforeEach(async function () {
        // Deploy mock USDT
        const USDTToken = await ethers.getContractFactory("MockUSDT");
        usdt = await USDTToken.deploy();
        
        // Deploy HawalaFactory
        HawalaFactory = await ethers.getContractFactory("HawalaFactory");
        factory = await HawalaFactory.deploy(usdt.address);
        
        [owner, seller, buyer, ...addrs] = await ethers.getSigners();

        // Set initial configurations
        await factory.setMinimumTradeSizes(
            ethers.parseUnits("100", 6),  // 100 USDT min for market
            ethers.parseUnits("1000", 6)  // 1000 USDT min for orderbook
        );
        await factory.setLargeOrderThreshold(ethers.parseUnits("10000", 6)); // 10k USDT
    });

    describe("Initialization", function () {
        it("Should set the correct USDT token address", async function () {
            expect(await factory.usdtToken()).to.equal(usdt.address);
        });

        it("Should not be paused initially", async function () {
            expect(await factory.tradingPaused()).to.equal(false);
        });
    });

    describe("Market Trade Creation", function () {
        it("Should create a market buy trade", async function () {
            const amount = ethers.parseUnits("500", 6); // 500 USDT
            const tx = await factory.createMarketTrade(amount, true, true);
            const receipt = await tx.wait();
            
            const event = receipt.events.find(e => e.event === 'TradeCreated');
            expect(event).to.not.be.undefined;
            
            const tradeId = event.args.tradeId;
            const trade = await factory.trades(tradeId);
            
            expect(trade.creator).to.equal(owner.address);
            expect(trade.amount).to.equal(amount);
            expect(trade.isBuyOrder).to.be.true;
            expect(trade.isMarketPrice).to.be.true;
        });

        it("Should reject trades below minimum size", async function () {
            const amount = ethers.parseUnits("50", 6); // 50 USDT
            await expect(
                factory.createMarketTrade(amount, true, true)
            ).to.be.revertedWith("Below minimum trade size");
        });

        it("Should reject trades above threshold", async function () {
            const amount = ethers.parseUnits("20000", 6); // 20k USDT
            await expect(
                factory.createMarketTrade(amount, true, true)
            ).to.be.revertedWith("Amount exceeds large order threshold");
        });
    });

    describe("Order Book Trade Creation", function () {
        it("Should create an order book sell trade", async function () {
            const amount = ethers.parseUnits("1500", 6); // 1500 USDT
            const price = ethers.parseUnits("50000", 6); // 50k USDT per BTC
            const tx = await factory.createOrderBookTrade(amount, price, false, true);
            const receipt = await tx.wait();
            
            const event = receipt.events.find(e => e.event === 'TradeCreated');
            const tradeId = event.args.tradeId;
            const trade = await factory.trades(tradeId);
            
            expect(trade.creator).to.equal(owner.address);
            expect(trade.amount).to.equal(amount);
            expect(trade.price).to.equal(price);
            expect(trade.isBuyOrder).to.be.false;
            expect(trade.isMarketPrice).to.be.false;
        });
    });

    describe("Trade Execution", function () {
        it("Should execute a market trade", async function () {
            // Setup
            const amount = ethers.parseUnits("500", 6);
            await usdt.transfer(buyer.address, amount.mul(2));
            await usdt.connect(buyer).approve(factory.address, amount.mul(2));
            
            // Create trade
            const tx = await factory.createMarketTrade(amount, true, true);
            const receipt = await tx.wait();
            const tradeId = receipt.events.find(e => e.event === 'TradeCreated').args.tradeId;
            
            // Execute trade
            const price = ethers.parseUnits("50000", 6);
            await expect(factory.connect(buyer).executeTrade(tradeId, price))
                .to.emit(factory, 'TradeExecuted');
        });
    });

    describe("Circuit Breaker", function () {
        it("Should pause and resume trading", async function () {
            await factory.pauseTrading();
            expect(await factory.tradingPaused()).to.be.true;

            const amount = ethers.parseUnits("500", 6);
            await expect(
                factory.createMarketTrade(amount, true, true)
            ).to.be.revertedWith("Trading is paused");

            // Wait for cooldown
            await ethers.provider.send("evm_increaseTime", [24 * 60 * 60]);
            await factory.resumeTrading();
            expect(await factory.tradingPaused()).to.be.false;
        });
    });
});
