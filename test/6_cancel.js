const { expect } = require("chai");
const { ethers } = require("hardhat");
const {
    time,
    loadFixture,
} = require("@nomicfoundation/hardhat-toolbox/network-helpers");

const { encodeLoan } = require("./utils")

describe("Cancel", function () {
    let loanContract;
    let owner;
    let addr1;
    let loan;

    beforeEach(async function () {
        const LoanContract = await ethers.getContractFactory("LendingP2P"); 
        [owner, addr1] = await ethers.getSigners();

        loanContract = await LoanContract.deploy();

        const MockToken = await ethers.getContractFactory("MockERC20Metadata"); 
        mockAsset = await MockToken.deploy("Asset", "ASSET", 18)
        mockCollateral = await MockToken.deploy("Collateral", "COLLAT", 18)

        loan = {
            borrower: owner.address,
            lender: "0x0000000000000000000000000000000000000000",
            asset: mockAsset.target,
            collateral: mockCollateral.target,
    
            assetAmount: ethers.parseEther("10"),
            repaymentAmount: ethers.parseEther("12"),
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

    it("should request and cancel a new valid loan", async function () {
        const encodedLoan = encodeLoan(loan)

        await expect(loanContract.requestLoan(encodedLoan))
            .to.emit(loanContract, "LoanRequested")
            .withArgs(0, loan.borrower);
        
        expect((await loanContract.loans(0)).status).to.equal(0);

        await expect(loanContract.cancelLoan(0))
            .to.emit(loanContract, "LoanCanceled")
            .withArgs(0, loan.borrower)

        expect((await loanContract.loans(0)).status).to.equal(1)
    });

    it("should cancel a loan request as owner", async function () {
        const encodedLoan = encodeLoan(loan)
        await loanContract.requestLoan(encodedLoan)

        await expect(loanContract.cancelLoan(0))
            .to.emit(loanContract, "LoanCanceled")
            .withArgs(0, loan.borrower);
    });
    
    it("should revert: cancel a loan request as non-owner", async function () {
        const encodedLoan = encodeLoan(loan)
        await loanContract.requestLoan(encodedLoan)

        await expect(loanContract.connect(addr1).cancelLoan(0)).to.revertedWith("sender != borrower")
    });

    it("should revert: cancel a loan request using invalid id", async function () {
        const encodedLoan = encodeLoan(loan)
        await loanContract.requestLoan(encodedLoan)

        await expect(loanContract.cancelLoan(1)).to.revertedWith("already expired") //since createdTimestamp = 0
    });

    it("should revert: cancel already expired loan", async function () {
        const encodedLoan = encodeLoan(loan)
        await loanContract.requestLoan(encodedLoan)

        let loanCreation = (await loanContract.loans(0)).createdTimestamp;
        let expirationDuration = await loanContract.REQUEST_EXPIRATION_DURATION()
        let nextTimestamp = Number(parseFloat(loanCreation).toFixed(0)) + Number(expirationDuration) + 1000
        await time.setNextBlockTimestamp(nextTimestamp)

        await expect(loanContract.cancelLoan(0)).to.revertedWith("already expired")
    });

    it("should revert: loan was already canceled", async function () {
        const encodedLoan = encodeLoan(loan)
        await loanContract.requestLoan(encodedLoan)

        await loanContract.cancelLoan(0);

        await expect(loanContract.cancelLoan(0)).to.revertedWith("invalid status")
    });
});
