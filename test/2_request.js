const { expect } = require("chai");
const { ethers } = require("hardhat");

const { encodeLoan } = require("./utils")

describe("Request", function () {
    let loanContract;
    let owner;
    let loan;

    beforeEach(async function () {
        const LoanContract = await ethers.getContractFactory("LendingP2P"); 
        [owner] = await ethers.getSigners();

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
    
            liquidation: {
                isLiquidatable: false,
                liquidationThreshold: 0,
                assetOracle: '0x0000000000000000000000000000000000000003',
                collateralOracle: '0x0000000000000000000000000000000000000004'
            },
            status: 0 //Pending
        };
    });

    it("should request a new valid loan", async function () {
        const encodedLoan = encodeLoan(loan)

        await expect(loanContract.requestLoan(encodedLoan))
            .to.emit(loanContract, "LoanRequested")
            .withArgs(0, loan.borrower);

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

        expect(storedLoan.liquidation.isLiquidatable).to.equal(loan.liquidation.isLiquidatable);
        expect(storedLoan.liquidation.liquidationThreshold).to.equal(loan.liquidation.liquidationThreshold);
        expect(storedLoan.liquidation.assetOracle).to.equal(loan.liquidation.assetOracle);
        expect(storedLoan.liquidation.collateralOracle).to.equal(loan.liquidation.collateralOracle);

        expect(storedLoan.status).to.equal(0);
        expect(await loanContract.loanLength()).to.equal(1);
    });

    it("should revert: request a new loan with invalid repayment amount", async function () {
        loan.repaymentAmount = 99
        loan.assetAmount = 100
        const encodedLoan = encodeLoan(loan)

        await expect(loanContract.requestLoan(encodedLoan)).to.revertedWith("amount <= repayment")
    });

    it("should revert: request a new loan with invalid borrower", async function () {
        loan.borrower = "0x0000000000000000000000000000000000000003"
        const encodedLoan = encodeLoan(loan)

        await expect(loanContract.requestLoan(encodedLoan)).to.revertedWith("borrower != msg.sender")
    });

    it("should revert: request a new loan with invalid liquidationThreshold", async function () {
        loan.liquidation.liquidationThreshold = "10001"
        const encodedLoan = encodeLoan(loan)

        await expect(loanContract.requestLoan(encodedLoan)).to.revertedWith("liq threshold > max bps")
    });

    it("should revert: request a new invalid loan: collateral == asset", async function () {
        loan.asset = loan.collateral
        const encodedLoan = encodeLoan(loan)

        await expect(loanContract.requestLoan(encodedLoan)).to.revertedWith("asset == collateral")
    });

    it("should revert: invalid loan encoding", async function () {
        const invalidEncodedLoan = invalidEncoding(loan)
        await expect(loanContract.requestLoan(invalidEncodedLoan)).to.revertedWithoutReason()
    });
});

function invalidEncoding(loan){
    const abiEncoder = new ethers.AbiCoder()
    return abiEncoder.encode(
        [
            "address", "address", "address", "address", 
            "uint256", "uint256", "uint256", 
            "uint256", "uint256", "uint256",
            "uint8",
        ],
        [
            loan.borrower, loan.lender, loan.asset, loan.collateral,
            loan.assetAmount, loan.repaymentAmount, loan.collateralAmount,
            0, 0, loan.duration,
            loan.status,
        ]
    );
}