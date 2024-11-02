const { expect } = require("chai");
const { ethers } = require("hardhat");
const {
    time,
    loadFixture,
} = require("@nomicfoundation/hardhat-toolbox/network-helpers");

const { encodeLoan } = require("./utils")

describe("Liquidate", function () {
    let loanContract;

    let borrower;
    let lender;
    let deployer;
    let liquidator;

    let loan;
    let mockAsset;
    let mockCollateral;

    let aggregatorAsset;
    let aggregatorCollateral;

    async function recordBalances(){
        return {
            borrower: {
                asset: await mockAsset.balanceOf(borrower.address),
                collateral: await mockCollateral.balanceOf(borrower.address),
            },
            lender: {
                asset: await mockAsset.balanceOf(lender.address),
                collateral: await mockCollateral.balanceOf(lender.address),
            },
            contract: {
                asset: await mockAsset.balanceOf(loanContract.target),
                collateral: await mockCollateral.balanceOf(loanContract.target),
            },
            deployer: {
                asset: await mockAsset.balanceOf(deployer.address),
                collateral: await mockCollateral.balanceOf(deployer.address),
            },
            liquidator: {
                collateral: await mockCollateral.balanceOf(liquidator.address),
            }
        }
    }

    beforeEach(async function () {
        const LoanContract = await ethers.getContractFactory("LendingP2P"); 
        [borrower, lender, deployer, liquidator] = await ethers.getSigners();

        loanContract = await LoanContract.connect(deployer).deploy();

        const MockToken = await ethers.getContractFactory("MockERC20"); 
        mockAsset = await MockToken.connect(borrower).deploy()
        mockCollateral = await MockToken.connect(borrower).deploy()

        const MockAggregator = await ethers.getContractFactory("Aggregator"); 
        aggregatorAsset = await MockAggregator.connect(deployer).deploy();
        aggregatorCollateral = await MockAggregator.connect(deployer).deploy();

        await aggregatorAsset.connect(deployer).setAnswer(200000000000); //2k usd
        await aggregatorCollateral.connect(deployer).setAnswer(5000000000000); //50k usd

        loan = {
            borrower: borrower.address,
            lender: "0x0000000000000000000000000000000000000000",
            asset: mockAsset.target,
            collateral: mockCollateral.target,
    
            assetAmount: ethers.parseEther("10"), //20k usd
            repaymentAmount: ethers.parseEther("11"),
            collateralAmount: ethers.parseEther("0.6"), //30k usd => 24k max borrow @ 80% lltv
    
            duration: 30 * 24 * 60 * 60, 
    
            liquidation: {
                isLiquidatable: true,
                liquidationThreshold: 8000,
                assetOracle: aggregatorAsset.target, 
                collateralOracle: aggregatorCollateral.target
            },
            status: 0 //Pending
        };
    });

    it("should liquidate a valid liquidatable loan", async function () {
        const encodedLoan = encodeLoan(loan)
        await loanContract.connect(borrower).requestLoan(encodedLoan);

        await mockAsset.connect(borrower).transfer(lender.address, loan.assetAmount)

        let balancesBefore = await recordBalances()

        expect(balancesBefore.borrower.asset).to.equal("999999990000000000000000000");
        expect(balancesBefore.borrower.collateral).to.equal("1000000000000000000000000000");
        expect(balancesBefore.lender.asset).to.equal(loan.assetAmount);
        expect(balancesBefore.lender.collateral).to.equal("0");

        await mockCollateral.connect(borrower).approve(loanContract.target, loan.collateralAmount)
        await mockAsset.connect(lender).approve(loanContract.target, loan.assetAmount)

        await loanContract.connect(lender).fillRequest(0);

        let balancesAfter = await recordBalances()

        expect(balancesAfter.borrower.asset).to.equal(balancesBefore.borrower.asset + loan.assetAmount);
        expect(balancesAfter.borrower.collateral).to.equal(balancesBefore.borrower.collateral - loan.collateralAmount);

        expect(balancesAfter.lender.asset).to.equal(balancesBefore.lender.asset - loan.assetAmount);
        expect(balancesAfter.lender.collateral).to.equal("0");

        expect(balancesAfter.contract.asset).to.equal("0");
        expect(balancesAfter.contract.collateral).to.equal(loan.collateralAmount);

        const storedLoan = await loanContract.loans(0);

        expect(storedLoan.borrower).to.equal(loan.borrower);
        expect(storedLoan.lender).to.equal(lender.address);
        expect(storedLoan.asset).to.equal(loan.asset);
        expect(storedLoan.collateral).to.equal(loan.collateral);

        expect(storedLoan.assetAmount).to.equal(loan.assetAmount);
        expect(storedLoan.repaymentAmount).to.equal(loan.repaymentAmount);
        expect(storedLoan.collateralAmount).to.equal(loan.collateralAmount);

        expect(storedLoan.startTimestamp).to.not.equal(0);
        expect(storedLoan.duration).to.equal(loan.duration);

        expect(storedLoan.liquidation.isLiquidatable).to.equal(loan.liquidation.isLiquidatable);
        expect(storedLoan.liquidation.liquidationThreshold).to.equal(loan.liquidation.liquidationThreshold);
        expect(storedLoan.liquidation.assetOracle).to.equal(loan.liquidation.assetOracle);
        expect(storedLoan.liquidation.collateralOracle).to.equal(loan.liquidation.collateralOracle);

        expect(storedLoan.status).to.equal(2);

        //make loan liquidatable
        await aggregatorAsset.connect(deployer).setAnswer(250000000000);
        
        //liquidate loan
        await expect(loanContract.connect(liquidator).liquidateLoan(0))
            .to.emit(loanContract, "LoanLiquidated")
            .withArgs(0)

        let balancesAfterLiquidate = await recordBalances()

        let liquidatorBonus = loan.collateralAmount * ethers.toBigInt(100) / ethers.toBigInt(10000);
        let protocolFee = loan.collateralAmount * ethers.toBigInt(20) / ethers.toBigInt(10000);
        let lenderAmount = loan.collateralAmount - liquidatorBonus - protocolFee;

        expect(balancesAfterLiquidate.borrower.collateral).to.equal(balancesBefore.borrower.collateral - loan.collateralAmount);
        expect(balancesAfterLiquidate.contract.collateral).to.equal("0");
        expect(balancesAfterLiquidate.liquidator.collateral).to.equal(liquidatorBonus);
        expect(balancesAfterLiquidate.deployer.collateral).to.equal(balancesBefore.deployer.collateral + protocolFee);
        expect(balancesAfterLiquidate.lender.collateral).to.equal(balancesBefore.lender.collateral + lenderAmount);

        const storedLoanAfterLiquidate = await loanContract.loans(0);
        expect(storedLoanAfterLiquidate.status).to.equal(4);
    });

    it("should liquidate a valid defaulted loan", async function () {
        const encodedLoan = encodeLoan(loan)
        await loanContract.connect(borrower).requestLoan(encodedLoan);

        await mockAsset.connect(borrower).transfer(lender.address, loan.assetAmount)

        let balancesBefore = await recordBalances()

        expect(balancesBefore.borrower.asset).to.equal("999999990000000000000000000");
        expect(balancesBefore.borrower.collateral).to.equal("1000000000000000000000000000");
        expect(balancesBefore.lender.asset).to.equal(loan.assetAmount);
        expect(balancesBefore.lender.collateral).to.equal("0");

        await mockCollateral.connect(borrower).approve(loanContract.target, loan.collateralAmount)
        await mockAsset.connect(lender).approve(loanContract.target, loan.assetAmount)

        await loanContract.connect(lender).fillRequest(0);

        let balancesAfter = await recordBalances()

        expect(balancesAfter.borrower.asset).to.equal(balancesBefore.borrower.asset + loan.assetAmount);
        expect(balancesAfter.borrower.collateral).to.equal(balancesBefore.borrower.collateral - loan.collateralAmount);

        expect(balancesAfter.lender.asset).to.equal(balancesBefore.lender.asset - loan.assetAmount);
        expect(balancesAfter.lender.collateral).to.equal("0");

        expect(balancesAfter.contract.asset).to.equal("0");
        expect(balancesAfter.contract.collateral).to.equal(loan.collateralAmount);

        const storedLoan = await loanContract.loans(0);

        expect(storedLoan.borrower).to.equal(loan.borrower);
        expect(storedLoan.lender).to.equal(lender.address);
        expect(storedLoan.asset).to.equal(loan.asset);
        expect(storedLoan.collateral).to.equal(loan.collateral);

        expect(storedLoan.assetAmount).to.equal(loan.assetAmount);
        expect(storedLoan.repaymentAmount).to.equal(loan.repaymentAmount);
        expect(storedLoan.collateralAmount).to.equal(loan.collateralAmount);

        expect(storedLoan.startTimestamp).to.not.equal(0);
        expect(storedLoan.duration).to.equal(loan.duration);

        expect(storedLoan.liquidation.isLiquidatable).to.equal(loan.liquidation.isLiquidatable);
        expect(storedLoan.liquidation.liquidationThreshold).to.equal(loan.liquidation.liquidationThreshold);
        expect(storedLoan.liquidation.assetOracle).to.equal(loan.liquidation.assetOracle);
        expect(storedLoan.liquidation.collateralOracle).to.equal(loan.liquidation.collateralOracle);

        expect(storedLoan.status).to.equal(2);

        //make loan liquidatable
        let defaultTimestamp = Number(storedLoan.startTimestamp) + Number(storedLoan.duration) + 1000;
        await time.setNextBlockTimestamp(defaultTimestamp)
        
        //liquidate loan
        await expect(loanContract.connect(liquidator).liquidateLoan(0))
            .to.emit(loanContract, "LoanLiquidated")
            .withArgs(0)

        let balancesAfterLiquidate = await recordBalances()

        let liquidatorBonus = loan.collateralAmount * ethers.toBigInt(100) / ethers.toBigInt(10000);
        let protocolFee = loan.collateralAmount * ethers.toBigInt(20) / ethers.toBigInt(10000);
        let lenderAmount = loan.collateralAmount - liquidatorBonus - protocolFee;

        expect(balancesAfterLiquidate.borrower.collateral).to.equal(balancesBefore.borrower.collateral - loan.collateralAmount);
        expect(balancesAfterLiquidate.contract.collateral).to.equal("0");
        expect(balancesAfterLiquidate.liquidator.collateral).to.equal(liquidatorBonus);
        expect(balancesAfterLiquidate.deployer.collateral).to.equal(balancesBefore.deployer.collateral + protocolFee);
        expect(balancesAfterLiquidate.lender.collateral).to.equal(balancesBefore.lender.collateral + lenderAmount);

        const storedLoanAfterLiquidate = await loanContract.loans(0);
        expect(storedLoanAfterLiquidate.status).to.equal(4);
    });

    it("should liquidate a not-liquidatable loan, status shouldn't change", async function () {
        loan.assetAmount = "1000"
        const encodedLoan = encodeLoan(loan)
        await loanContract.connect(borrower).requestLoan(encodedLoan);

        await mockAsset.connect(borrower).transfer(lender.address, loan.assetAmount)
        await mockCollateral.connect(borrower).approve(loanContract.target, loan.collateralAmount)
        await mockAsset.connect(lender).approve(loanContract.target, loan.assetAmount)
        await loanContract.connect(lender).fillRequest(0);
        
        let statusBefore = (await loanContract.loans(0)).status
        //liquidate loan, but loan is not liquidatable so nothing happens
        loanContract.connect(liquidator).liquidateLoan(0)
        //status shouldn't change
        expect((await loanContract.loans(0)).status).to.equal(statusBefore);
    });

    it("should liquidate a not-defaulted loan, status shouldn't change", async function () {
        loan.liquidation.isLiquidatable = false
        const encodedLoan = encodeLoan(loan)
        await loanContract.connect(borrower).requestLoan(encodedLoan);

        await mockAsset.connect(borrower).transfer(lender.address, loan.assetAmount)
        await mockCollateral.connect(borrower).approve(loanContract.target, loan.collateralAmount)
        await mockAsset.connect(lender).approve(loanContract.target, loan.assetAmount)
        await loanContract.connect(lender).fillRequest(0);
        
        let statusBefore = (await loanContract.loans(0)).status
        //liquidate loan, but loan is not liquidatable so nothing happens
        loanContract.connect(liquidator).liquidateLoan(0)
        //status shouldn't change
        expect((await loanContract.loans(0)).status).to.equal(statusBefore);
    });

    it("should revert: loan is not active", async function () {
        const encodedLoan = encodeLoan(loan)
        await loanContract.connect(borrower).requestLoan(encodedLoan);

        await expect(loanContract.connect(liquidator).liquidateLoan(0)).to.revertedWith("invalid status");
    });

    it("should revert: invalid collateral price", async function () {
        loan.liquidation.isLiquidatable = true
        const encodedLoan = encodeLoan(loan)
        await loanContract.connect(borrower).requestLoan(encodedLoan);

        await mockAsset.connect(borrower).transfer(lender.address, loan.assetAmount)
        await mockCollateral.connect(borrower).approve(loanContract.target, loan.collateralAmount)
        await mockAsset.connect(lender).approve(loanContract.target, loan.assetAmount)
        await loanContract.connect(lender).fillRequest(0);

        await aggregatorCollateral.connect(deployer).setAnswer(0);

        await expect(loanContract.connect(liquidator).liquidateLoan(0)).to.revertedWith("invalid oracle price");
    });
});