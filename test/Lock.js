const {
  time,
  loadFixture,
} = require("@nomicfoundation/hardhat-toolbox/network-helpers");
const { expect } = require("chai");

describe("Hawala Token Ecosystem", function () {
  let HawalaFactory, factory, usdt, HawalaToken, HawalaVesting, HawalaPresale;
  let owner, seller, buyer, token, vesting, presale, addr1, addr2, addr3;
  const TOTAL_SUPPLY = ethers.parseEther("1000000000");
  const CLIFF = 90 * 24 * 60 * 60; // 90 days in seconds
  const MONTH = 30 * 24 * 60 * 60;
  const btcAddress = 'bc1qxy2kgdygjrsqtzq2n0yrf2493p83kkfjhx0wlh'


  beforeEach(async function () {
      const USDTToken = await ethers.getContractFactory("MockUSDT");
      usdt = await USDTToken.deploy();

      HawalaToken = await ethers.getContractFactory("HawalaToken");
      token = await HawalaToken.deploy();

      HawalaVesting = await ethers.getContractFactory("HawalaVesting");
      vesting = await HawalaVesting.deploy(token.target);

      HawalaPresale = await ethers.getContractFactory("HawalaPresale");
      presale = await HawalaPresale.deploy(token.target, vesting.target);


      [owner, seller, buyer, addr1, addr2, addr3] = await ethers.getSigners();
      
      HawalaFactory = await ethers.getContractFactory("HawalaFactory");
      factory = await HawalaFactory.deploy(usdt.target, owner.address);
      
      await token.setVestingContract(vesting.target);
      await vesting.setPresaleContract(presale.target);
      await token.transfer(vesting.target, ethers.parseEther("50000000"));
      await factory.setMinimumTradeSizes(
          ethers.parseUnits("100", 18),  // 100 USDT min for market
          ethers.parseUnits("1000", 18)  // 1000 USDT min for orderbook
      );
      await factory.setLargeOrderThreshold(ethers.parseUnits("10000", 18)); // 10k USDT
  });

  describe("HawalaToken", function () {
    it("Should have correct name and symbol", async function () {
      expect(await token.name()).to.equal("HawalaDex token");
      expect(await token.symbol()).to.equal("HAWALA");
    });

    it("Should have correct total supply", async function () {
      const TokenFactory = await ethers.getContractFactory("HawalaToken");
      const newToken = await TokenFactory.deploy();
      expect(await newToken.totalSupply()).to.equal(TOTAL_SUPPLY);
    });

    it("Should prevent transfers during cliff period", async function () {
      await vesting.createVestingSchedule(addr1.address, ethers.parseEther("1000"), 0);
      await expect(token.connect(addr1).transfer(addr2.address, ethers.parseEther("1"))).to.be.revertedWith("Amount exceeds available tokens");
    });

    it("Should handle multiple vesting schedules for same user", async function () {
      await vesting.createVestingSchedule(addr1.address, ethers.parseEther("1000"), 0); // Private Sale
      await vesting.createVestingSchedule(addr1.address, ethers.parseEther("2000"), 1); // Public Sale 1

      const rounds = await token.getUserRounds(addr1.address);
      expect(rounds.length).to.equal(1);
    });

    it("Should allow transfers of non-vested tokens", async function () {
      const transferAmount = ethers.parseEther("1000");
      await token.connect(owner).transfer(addr1.address, transferAmount);
      
      expect(await token.balanceOf(addr1.address)).to.equal(transferAmount);
      
      await token.connect(addr1).transfer(addr2.address, ethers.parseEther("500"));
      expect(await token.balanceOf(addr2.address)).to.equal(ethers.parseEther("500"));
    });

    it("Should correctly calculate available tokens after partial vesting", async function () {
      const amount = ethers.parseEther("1200");
      await vesting.createVestingSchedule(addr1.address, amount, 0); // Private Sale
      
      const timestamp = await time.latest();
      await time.increaseTo(timestamp + CLIFF + MONTH);
      
      const available = await token.calculateAvailableTokens(addr1.address, 0);
      const expectedMonthly = amount * BigInt(MONTH) / BigInt(540 * 24 * 60 * 60); // 18 months
      expect(available).to.equal(expectedMonthly);
    });
  });

  describe("HawalaVesting", function () {
    it("Should create vesting schedule correctly", async function () {
      await vesting.createVestingSchedule(addr1.address, ethers.parseEther("1000"), 0);
      const schedule = await vesting.vestingSchedules(addr1.address);
      expect(schedule.totalAmount).to.equal(ethers.parseEther("1000"));
      expect(schedule.isActive).to.be.true;
    });

    it("Should not allow claiming before cliff period", async function () {
      await vesting.createVestingSchedule(addr1.address, ethers.parseEther("1000"), 0);
      await expect(vesting.connect(addr1).claim()).to.be.revertedWith("Cliff period active");
    });

    it("Should allow claiming after cliff period", async function () {
      const amount = ethers.parseEther("1000");
      await token.transfer(vesting.target, amount);
      await vesting.createVestingSchedule(addr1.address, amount, 0);
    
      const timestamp = await time.latest();
      await time.increaseTo(timestamp + CLIFF + MONTH);
      
      await vesting.connect(addr1).claim();
      const expectedMinimum = amount * BigInt(556) / BigInt(10000);
      expect(await token.balanceOf(addr1.address)).to.be.gte(expectedMinimum);
    });

    it("Should handle different vesting schedules correctly", async function () {
      const schedules = [
          { type: 0, duration: 540 * 24 * 60 * 60 }, // Private Sale: 18 months
          { type: 1, duration: 360 * 24 * 60 * 60 }, // Public Sale 1: 12 months
          { type: 2, duration: 300 * 24 * 60 * 60 }, // Public Sale 2: 10 months
          { type: 3, duration: 240 * 24 * 60 * 60 }  // Public Sale 3: 8 months
      ];

      for (let schedule of schedules) {
          await vesting.createVestingSchedule(addr1.address, ethers.parseEther("1000"), schedule.type);
          const vestingSchedule = await vesting.vestingSchedules(addr1.address);
          expect(vestingSchedule.vestingEnd - vestingSchedule.cliffEnd).to.equal(schedule.duration);
      }
    });

    it("Should handle immediate unlocks correctly", async function () {
        const timestamp = await time.latest();
        await vesting.createVestingSchedule(addr1.address, ethers.parseEther("1000"), 4); // DEX
        const schedule = await vesting.vestingSchedules(addr1.address);
        expect(schedule.cliffEnd).to.be.closeTo(BigInt(timestamp), BigInt(1));
    });

    it("Should handle trading airdrop lock correctly", async function () {
        await vesting.createVestingSchedule(addr1.address, ethers.parseEther("1000"), 6); // Trading Airdrop
        const schedule = await vesting.vestingSchedules(addr1.address);
        expect(schedule.cliffEnd - schedule.lastClaim).to.equal(0);
    });
  });

  describe("HawalaPresale", function () {
    beforeEach(async function () {
      await usdt.transfer(addr1.address, ethers.parseUnits("10000", 18));
      await usdt.connect(addr1).approve(presale.target, ethers.parseUnits("10000", 18));
    });

    it("Should start private sale correctly", async function () {
      await presale.startPrivateSale();
      const round = await presale.currentRound();
      expect(round.price).to.equal(800);
      expect(round.isActive).to.be.true;
    });

    it("Should accept investment and create vesting schedule", async function () {
      await presale.startPrivateSale();
      await presale.connect(addr1).invest(false, ethers.parseUnits("5000", 18), ethers.parseUnits("2500", 18), usdt.target);
      const round = await presale.currentRound();
      expect(round.sold).to.be.gt(0);
      const schedule = await vesting.vestingSchedules(addr1.address);
      expect(schedule.isActive).to.be.true;
    });

    it("Should progress to next round when allocation filled", async function () {
      await presale.startPrivateSale();
      const allocation = ethers.parseEther("50000000");
      await presale.connect(addr1).invest(
          false,
          ethers.parseUnits("50000", 6),
          allocation,
          usdt.target
      );
      
      const round = await presale.currentRound();
      expect(round.price).to.equal(1000); // Public Sale 1 price
      expect(round.allocation).to.equal(allocation);
    });

    it("Should pause and resume sale", async function () {
      await presale.startPrivateSale();
      await presale.togglePause();
      await expect(presale.connect(addr1).invest(false, ethers.parseUnits("5000", 18), ethers.parseUnits("2500", 18), usdt.target)).to.be.revertedWith("Sale is paused");
      await presale.togglePause();
      await presale.connect(addr1).invest(false, ethers.parseUnits("5000", 18), ethers.parseUnits("2500", 18), usdt.target);
      const round = await presale.currentRound();
      expect(round.sold).to.be.gt(0);
    });

    it("Should handle BTC and non-BTC investments correctly", async function () {
      await presale.startPrivateSale();
      await token.transfer(vesting.target, ethers.parseEther("2000000")); // Ensure vesting has tokens
      
      // Non-BTC investment with USDT
      await presale.connect(addr1).invest(
          false,
          ethers.parseUnits("0.01", 18),
          ethers.parseEther("1000000"),
          ethers.ZeroAddress,
          {value: ethers.parseUnits("0.01", 18)}
      );
      
      // BTC investment
      await presale.connect(addr2).invest(
          true,
          0,
          ethers.parseEther("1000000"),
          ethers.ZeroAddress
      );
      
      const addr1Schedule = await vesting.vestingSchedules(addr1.address);
      const addr2Schedule = await vesting.vestingSchedules(addr2.address);
      
      expect(addr1Schedule.totalAmount).to.equal(ethers.parseEther("1000000"));
      expect(addr2Schedule.totalAmount).to.equal(ethers.parseEther("1000000"));
    });

    it("Should handle round progression correctly", async function () {
        await presale.startPrivateSale();
        
        // Fill private sale
        await presale.connect(addr1).invest(
            false,
            ethers.parseUnits("50000", 6),
            ethers.parseEther("50000000"),
            usdt.target
        );

        const round = await presale.currentRound();
        expect(round.price).to.equal(1000); // Public Sale 1 price
    });

    it("Should handle emergency withdrawal correctly", async function () {
        await presale.startPrivateSale();
        await presale.connect(addr1).invest(
            false,
            ethers.parseUnits("5000", 6),
            ethers.parseEther("1000000"),
            usdt.target
        );

        const initialBalance = await usdt.balanceOf(owner.address);
        await presale.emergencyWithdraw(usdt.target);
        expect(await usdt.balanceOf(owner.address)).to.be.gt(initialBalance);
    });
  });

  describe("Initialization", function () {
      it("Should set the correct USDT token address", async function () {
          expect(await factory.usdtToken()).to.equal(usdt.target);
      });

      it("Should not be paused initially", async function () {
          expect(await factory.tradingPaused()).to.equal(false);
      });
  });

  describe("Market Price Trading", function () {
  it("Should create and execute market swap BTC to USDT", async function () {
      const usdtAmount = ethers.parseUnits("1000", 18); // 1000 USDT
      const price = ethers.parseUnits("50000", 18); // $50k per BTC
      const totalAmount = usdtAmount + (usdtAmount * BigInt(25) / BigInt(10000)); // Amount + 0.25% fee

        // Setup buyer with sufficient USDT and approval
        await usdt.connect(owner).approve(factory.target, totalAmount);

        // Create swap (BTC to USDT)
        await factory.createTrade(
          usdtAmount,
          price,
          true,
          true,
          btcAddress
        );
        const tradeId = (await factory.allTradeIds(0));
        
        // Execute trade
        await factory.connect(owner).executeTrade(tradeId);
    });

    it("Should create and execute market swap USDT to BTC", async function () {
        const usdtAmount = ethers.parseUnits("1000", 18); // 1000 USDT
        const price = ethers.parseUnits("50000", 18);
        const totalAmount = usdtAmount + (usdtAmount * BigInt(25) / BigInt(10000)); // Amount + 0.25% fee
        
        // Setup seller with USDT and approval
        await usdt.transfer(addr1.address, totalAmount);
        await usdt.connect(addr1).approve(factory.target, totalAmount);

        // Create swap (USDT to BTC)
        await factory.connect(addr1).createTrade(
          usdtAmount,
          price,
          false,
          true,
          btcAddress
        );
        const tradeId = (await factory.allTradeIds(0));
        
        // Execute trade
        await factory.executeTrade(tradeId);
    });
  });


  describe("Order Book Trading", function () {
    beforeEach(async function () {
        await usdt.transfer(buyer.address, ethers.parseUnits("100000", 18));
        await usdt.connect(buyer).approve(factory.target, ethers.parseUnits("100000", 18));
    });

    it("Should create and list multiple orders", async function () {
        // Create multiple orders
        await factory.createTrade(
            ethers.parseUnits("1000", 18),
            ethers.parseUnits("45000", 18),
            true,
            true,
            btcAddress
        );
        
        await factory.createTrade(
            ethers.parseUnits("2000", 18),
            ethers.parseUnits("46000", 18),
            true,
            true,
            btcAddress
        );

        const orders = await factory.getOpenOrders();
        expect(orders.orderIds.length).to.equal(2);
    });

    it("Should handle order expiration correctly", async function () {
      const ORDERBOOK_TRADE_TIMEOUT = 24 * 60 * 60;
      const amount = ethers.parseUnits("1000", 18);
      const price = ethers.parseUnits("45000", 18);
      
      const tx = await factory.createTrade(
          amount,
          price,
          true,
          true,
          btcAddress
      );
      const tradeId = (await factory.allTradeIds(0));
      await time.increase(ORDERBOOK_TRADE_TIMEOUT + 1);
      await factory.cancelTrade(tradeId);
      
      const trade = await factory.trades(tradeId);
      expect(trade.status).to.equal(2);
    });
  });


  describe("Agent Commission System", function () {
    beforeEach(async function () {
        await usdt.transfer(buyer.address, ethers.parseUnits("100000", 18));
        await usdt.connect(buyer).approve(factory.target, ethers.parseUnits("100000",18));
    });

    it("Should handle agent commission distribution", async function () {
       // Register agent with 20% commission
       await factory.registerAgent(addr1.address, 2000);
       await factory.connect(buyer).setClientAgent(addr1.address);
       
       const amount = ethers.parseUnits("1000", 18);
       const price = ethers.parseUnits("50000", 18);
       const totalAmount = amount + (amount * BigInt(25) / BigInt(10000)); // Amount + 0.25% fee
       
       // Setup USDT balances and approvals
       await usdt.transfer(buyer.address, totalAmount);
       await usdt.approve(factory.target, totalAmount);
       
       // Transfer USDT to factory for commission payments
       await usdt.transfer(factory.target, ethers.parseUnits("100", 18));
       
       // Create and execute trade
       await factory.connect(buyer).createTrade(
           amount,
           price,
           true,
           true,
           btcAddress
       );
       
       const tradeId = (await factory.allTradeIds(0));
       await factory.executeTrade(tradeId);
       
       const agent = await factory.agents(addr1.address);
       expect(agent.totalCommission).to.be.gt(0);
   });

    it("Should respect maximum commission rate", async function () {
        await expect(
            factory.registerAgent(addr1.address, 6000)
        ).to.be.revertedWith("Max 50% commission");
    });
  });

  describe("Wallet Blocking System", function () {
    it("Should prevent blocked wallets from trading", async function () {
        await factory.blockWallet(buyer.address);
        
        expect(
            await factory.connect(buyer).createTrade(
                ethers.parseUnits("1000", 18),
                ethers.parseUnits("45000", 18),
                true,
                true,
                btcAddress
            )
        ).to.be.revertedWith("Wallet is blocked");
    });

    it("Should allow trading after unblocking", async function () {
        await factory.blockWallet(buyer.address);
        await factory.unblockWallet(buyer.address);
        
        const tx = await factory.connect(buyer).createTrade(
            ethers.parseUnits("1000", 18),
            ethers.parseUnits("45000", 18),
            true,
            true,
            btcAddress
        );
        
        expect(tx).to.not.be.reverted;
    });
  });


  describe("Circuit Breaker", function () {
      // it("Should pause and resume trading", async function () {
      //     await factory.pauseTrading();
      //     expect(await factory.tradingPaused()).to.be.true;

      //     const amount = ethers.parseUnits("500", 6);
      //     await expect(
      //         factory.createTrade(amount,amount, true, true, btcAddress)
      //     ).to.be.revertedWith("Trading is paused");

      //     // Wait for cooldown
      //     await ethers.provider.send("evm_increaseTime", [24 * 60 * 60]);
      //     await factory.resumeTrading();
      //     expect(await factory.tradingPaused()).to.be.false;
      // });
  });
});
