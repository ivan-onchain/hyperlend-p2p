const { expect } = require("chai");
const { ethers } = require("hardhat");
const {
    time,
    loadFixture,
} = require("@nomicfoundation/hardhat-toolbox/network-helpers");

const { encodeLoan } = require("./utils")

describe("Accept", function () {
    let loanContract;

    let borrower;
    let lender;

    let loan;
    let mockAsset;
    let mockCollateral;

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
            }
        }
    }

    beforeEach(async function () {
        const LoanContract = await ethers.getContractFactory("LendingP2P"); 
        [borrower, lender] = await ethers.getSigners();

        loanContract = await LoanContract.deploy();

        const MockToken = await ethers.getContractFactory("MockERC20"); 
        mockAsset = await MockToken.deploy()
        mockCollateral = await MockToken.deploy()

        loan = {
            borrower: borrower.address,
            lender: "0x0000000000000000000000000000000000000000",
            asset: mockAsset.target,
            collateral: mockCollateral.target,
    
            assetAmount: ethers.parseEther("10"),
            repaymentAmount: ethers.parseEther("11"),
            collateralAmount: ethers.parseEther("1"),
    
            duration: 30 * 24 * 60 * 60, 
    
            liquidation: {
                isLiquidatable: false,
                liquidationThreshold: 0,
                assetOracle: '0x0000000000000000000000000000000000000003',
                collateralOracle: '0x0000000000000000000000000000000000000004'
            },
            status: 0 //Pending
        };
    });

    it("should accept a valid loan request", async function () {
        const encodedLoan = encodeLoan(loan)
        await loanContract.requestLoan(encodedLoan);

        await mockAsset.transfer(lender.address, loan.assetAmount)

        let balancesBefore = await recordBalances()
        
        expect(balancesBefore.borrower.asset).to.equal("999999990000000000000000000");
        expect(balancesBefore.borrower.collateral).to.equal("1000000000000000000000000000");

        expect(balancesBefore.lender.asset).to.equal(loan.assetAmount);
        expect(balancesBefore.lender.collateral).to.equal("0");

        //approve tokens & fill request
        await mockCollateral.connect(borrower).approve(loanContract.target, loan.collateralAmount)
        await mockAsset.connect(lender).approve(loanContract.target, loan.assetAmount)

        await expect(loanContract.connect(lender).fillRequest(0))
            .to.emit(loanContract, "LoanFilled")
            .withArgs(0, loan.borrower, lender.address)

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

        expect(storedLoan.status).to.equal(2); //active status
    });

    it("should accept an liquidatable loan", async function () {
        const MockOracle = await ethers.getContractFactory("Aggregator"); 
        const mockAssetOracle = await MockOracle.deploy()
        const mockCollateralOracle = await MockOracle.deploy()

        loan.liquidation.isLiquidatable = true;
        loan.liquidation.liquidationThreshold = 8000;
        loan.liquidation.assetOracle = mockAssetOracle.target;
        loan.liquidation.collateralOracle = mockCollateralOracle.target;

        await mockAssetOracle.setAnswer(100000000) //1 USD, with 10 asset tokens = 10 USD
        await mockCollateralOracle.setAnswer(2000000000) //20 USD, with 1 collateral token = 20 USD

        await mockAsset.transfer(lender.address, loan.assetAmount)
        await mockCollateral.connect(borrower).approve(loanContract.target, loan.collateralAmount)
        await mockAsset.connect(lender).approve(loanContract.target, loan.assetAmount)

        const encodedLoan = encodeLoan(loan)
        await loanContract.requestLoan(encodedLoan);

        await expect(loanContract.connect(lender).fillRequest(0))
            .to.emit(loanContract, "LoanFilled")
            .withArgs(0, loan.borrower, lender.address)
    });

    it("should revert: accept an alredy accepted loan request", async function () {
        const encodedLoan = encodeLoan(loan)
        await loanContract.requestLoan(encodedLoan);

        await mockAsset.transfer(lender.address, loan.assetAmount)
        await mockCollateral.connect(borrower).approve(loanContract.target, loan.collateralAmount)
        await mockAsset.connect(lender).approve(loanContract.target, loan.assetAmount)

        await loanContract.connect(lender).fillRequest(0);
        expect((await loanContract.loans(0)).startTimestamp).to.not.equal(0);

        await expect(loanContract.connect(lender).fillRequest(0)).to.revertedWith("invalid status")
    });

    it("should revert: accept an expired loan request", async function () {
        const encodedLoan = encodeLoan(loan)
        await loanContract.requestLoan(encodedLoan);

        await mockAsset.transfer(lender.address, loan.assetAmount)
        await mockCollateral.connect(borrower).approve(loanContract.target, loan.collateralAmount)
        await mockAsset.connect(lender).approve(loanContract.target, loan.assetAmount)

        let expirationDuration = await loanContract.REQUEST_EXPIRATION_DURATION()
        let nextTimestamp = Number(await time.latest()) + Number(expirationDuration) + 100

        await time.setNextBlockTimestamp(nextTimestamp)

        await expect(loanContract.fillRequest(0)).to.revertedWith("already expired")
    });

    it("should revert: accept an instantly liquidatable loan", async function () {
        const MockOracle = await ethers.getContractFactory("Aggregator"); 
        const mockAssetOracle = await MockOracle.deploy()
        const mockCollateralOracle = await MockOracle.deploy()

        loan.liquidation.isLiquidatable = true;
        loan.liquidation.liquidationThreshold = 8000;
        loan.liquidation.assetOracle = mockAssetOracle.target;
        loan.liquidation.collateralOracle = mockCollateralOracle.target;

        await mockAssetOracle.setAnswer(100000000) //1 USD, with 10 asset tokens = 10 USD
        await mockCollateralOracle.setAnswer(100000000) //1 USD, with 1 collateral token = 1 USD

        const encodedLoan = encodeLoan(loan)
        await loanContract.requestLoan(encodedLoan);

        await expect(loanContract.fillRequest(0)).to.revertedWith("instantly liquidatable")
    });

    it("should revert: invalid collateral balance for lender", async function () {
        await mockCollateral.connect(borrower).approve(loanContract.target, loan.collateralAmount)
        await mockAsset.connect(lender).approve(loanContract.target, loan.assetAmount)

        const encodedLoan = encodeLoan(loan)
        await loanContract.requestLoan(encodedLoan);

        await expect(loanContract.connect(lender).fillRequest(0)).to.revertedWithCustomError(mockCollateral, "ERC20InsufficientBalance")
    });

    it("should revert: invalid asset balance for lender", async function () {
        await mockCollateral.connect(borrower).approve(loanContract.target, loan.collateralAmount)
        await mockAsset.connect(lender).approve(loanContract.target, loan.assetAmount)

        const encodedLoan = encodeLoan(loan)
        await loanContract.requestLoan(encodedLoan);

        await expect(loanContract.connect(lender).fillRequest(0)).to.revertedWithCustomError(mockAsset, "ERC20InsufficientBalance")
    });

    it("should revert: invalid collateral allowance by borrower", async function () {
        await mockAsset.connect(lender).approve(loanContract.target, loan.assetAmount)

        const encodedLoan = encodeLoan(loan)
        await loanContract.requestLoan(encodedLoan);

        await expect(loanContract.connect(borrower).fillRequest(0)).to.revertedWithCustomError(mockCollateral, "ERC20InsufficientAllowance")
    });

    it("should revert: invalid asset allowance by lender", async function () {
        await mockCollateral.connect(borrower).approve(loanContract.target, loan.collateralAmount)

        const encodedLoan = encodeLoan(loan)
        await loanContract.requestLoan(encodedLoan);

        await expect(loanContract.connect(lender).fillRequest(0)).to.revertedWithCustomError(mockAsset, "ERC20InsufficientAllowance")
    });
});
