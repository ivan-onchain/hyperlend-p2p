const { expect } = require("chai");
const { ethers } = require("hardhat");
const {
    time,
    loadFixture,
} = require("@nomicfoundation/hardhat-toolbox/network-helpers");

const { encodeLoan } = require("./utils")

describe("Loan Contract", function () {
    let loanContract;
    let owner;
    let addr1;
    let loan;

    beforeEach(async function () {
        const LoanContract = await ethers.getContractFactory("LendingP2P"); 
        [owner, addr1] = await ethers.getSigners();

        loanContract = await LoanContract.deploy();

        loan = {
            borrower: owner.address,
            lender: "0x0000000000000000000000000000000000000000",
            asset: "0x0000000000000000000000000000000000000001",
            collateral: "0x0000000000000000000000000000000000000002",
    
            assetAmount: ethers.parseEther("10"),
            repaymentAmount: ethers.parseEther("12"),
            collateralAmount: ethers.parseEther("1"),
            
            duration: 30 * 24 * 60 * 60, 
    
            liq: {
                isLiquidatable: false,
                liquidationThreshold: 0,
                assetOracle: '0x0000000000000000000000000000000000000003',
                collateralOracle: '0x0000000000000000000000000000000000000004'
            },
            status: 0 //Pending
        };
    });

    it("should succeed: request a new valid loan", async function () {
        const encodedLoan = encodeLoan(loan)

        await expect(loanContract.requestLoan(encodedLoan))
            .to.emit(loanContract, "LoanRequested")
            .withArgs(0);

        const storedLoan = await loanContract.loans(0);

        expect(storedLoan.borrower).to.equal(loan.borrower);
        expect(storedLoan.lender).to.equal(loan.lender);
        expect(storedLoan.asset).to.equal(loan.asset);
        expect(storedLoan.collateral).to.equal(loan.collateral);

        expect(storedLoan.assetAmount).to.equal(loan.assetAmount);
        expect(storedLoan.repaymentAmount).to.equal(loan.repaymentAmount);
        expect(storedLoan.collateralAmount).to.equal(loan.collateralAmount);

        expect(storedLoan.startTimestamp).to.equal(0);
        expect(storedLoan.duration).to.equal(loan.duration);

        expect(storedLoan.liquidation.isLiquidatable).to.equal(loan.liq.isLiquidatable);
        expect(storedLoan.liquidation.liquidationThreshold).to.equal(loan.liq.liquidationThreshold);
        expect(storedLoan.liquidation.assetOracle).to.equal(loan.liq.assetOracle);
        expect(storedLoan.liquidation.collateralOracle).to.equal(loan.liq.collateralOracle);

        expect(storedLoan.status).to.equal(0);
    });

    it("should succeed: request a new invalid loan repayment amount", async function () {
        loan.repaymentAmount = 99
        loan.assetAmount = 100
        const encodedLoan = encodeLoan(loan)

        await expect(loanContract.requestLoan(encodedLoan)).to.revertedWith("amount <= repayment")
    });

    it("should fail: request a new invalid loan with invalid borrower", async function () {
        loan.borrower = "0x0000000000000000000000000000000000000003"
        const encodedLoan = encodeLoan(loan)

        await expect(loanContract.requestLoan(encodedLoan)).to.revertedWith("borrower != msg.sender")
    });

    it("should fail: request a new invalid loan collateral & asset", async function () {
        loan.asset = loan.collateral
        const encodedLoan = encodeLoan(loan)

        await expect(loanContract.requestLoan(encodedLoan)).to.revertedWith("asset == collateral")
    });

    it("should succeed: cancel a loan request as owner", async function () {
        const encodedLoan = encodeLoan(loan)
        await loanContract.requestLoan(encodedLoan)

        await expect(loanContract.cancelLoan(0))
            .to.emit(loanContract, "LoanCanceled")
            .withArgs(0);
    });
    
    it("should fail: cancel a loan request as non-owner", async function () {
        const encodedLoan = encodeLoan(loan)
        await loanContract.requestLoan(encodedLoan)

        await expect(loanContract.connect(addr1).cancelLoan(0)).to.revertedWith("sender != borrower")
    });

    it("should fail: cancel a loan request using invalid id", async function () {
        const encodedLoan = encodeLoan(loan)
        await loanContract.requestLoan(encodedLoan)

        await expect(loanContract.cancelLoan(1)).to.revertedWith("already expired") //since createdTimestamp = 0
    });

    it("should fail: cancel already expired loan", async function () {
        const encodedLoan = encodeLoan(loan)
        await loanContract.requestLoan(encodedLoan)

        let expirationDuration = await loanContract.REQUEST_EXPIRATION_DURATION()
        let nextTimestamp = Number(parseFloat((new Date().getTime() / 1000)).toFixed(0)) + Number(expirationDuration) + 100

        await time.setNextBlockTimestamp(nextTimestamp)

        await expect(loanContract.cancelLoan(0)).to.revertedWith("already expired")
    });
});