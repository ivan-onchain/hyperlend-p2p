const { expect } = require("chai");
const { ethers } = require("hardhat");

const { encodeLoan } = require("./utils")

describe("e2e", function () {
    let loanContract;
    let borrower, lender, liquidator;
    let loan;
    let mockAsset, mockCollateral;
    let mockAssetOracle, mockCollateralOracle;

    beforeEach(async function () {
        const LoanContract = await ethers.getContractFactory("LendingP2P"); 
        [borrower, lender, liquidator] = await ethers.getSigners();

        loanContract = await LoanContract.deploy();

        const MockToken = await ethers.getContractFactory("MockERC20"); 
        mockAsset = await MockToken.deploy();
        mockCollateral = await MockToken.deploy();

        const MockOracle = await ethers.getContractFactory("Aggregator"); 
        mockAssetOracle = await MockOracle.deploy();
        mockCollateralOracle = await MockOracle.deploy();

        loan = {
            borrower: borrower.address,
            lender: ethers.ZeroAddress,
            asset: mockAsset.target,
            collateral: mockCollateral.target,
    
            assetAmount: ethers.parseEther("10"),
            repaymentAmount: ethers.parseEther("11"),
            collateralAmount: ethers.parseEther("1"),
    
            duration: 30 * 24 * 60 * 60, 
    
            liquidation: {
                isLiquidatable: false,
                liquidationThreshold: 0,
                assetOracle: mockAssetOracle.target,
                collateralOracle: mockCollateralOracle.target
            },
            status: 0 //Pending
        };

        await mockAsset.transfer(borrower.address, ethers.parseEther("1000"));
        await mockAsset.transfer(lender.address, loan.assetAmount);
        await mockCollateral.transfer(borrower.address, ethers.parseEther("1000"));
    });

    it("should complete full loan lifecycle: Request -> Fill -> Repay", async function () {
        const encodedLoan = encodeLoan(loan);

        // Request loan
        await loanContract.connect(borrower).requestLoan(encodedLoan);

        // Approve tokens and fill request
        await mockCollateral.connect(borrower).approve(loanContract.target, loan.collateralAmount);
        await mockAsset.connect(lender).approve(loanContract.target, loan.assetAmount);
        await loanContract.connect(lender).fillRequest(0);

        // Repay loan
        await mockAsset.connect(borrower).approve(loanContract.target, loan.repaymentAmount);
        await loanContract.connect(borrower).repayLoan(0);

        const storedLoan = await loanContract.loans(0);
        expect(storedLoan.status).to.equal(3); // Repaid status
    });

    it("should complete full loan lifecycle: Request -> Fill -> Liquidate (price)", async function () {
        loan.liquidation.isLiquidatable = true;
        loan.liquidation.liquidationThreshold = 8000;

        await mockAssetOracle.setAnswer(100000000);
        await mockCollateralOracle.setAnswer(2000000000);

        const encodedLoan = encodeLoan(loan);
        await loanContract.connect(borrower).requestLoan(encodedLoan);

        await mockCollateral.connect(borrower).approve(loanContract.target, loan.collateralAmount);
        await mockAsset.connect(lender).approve(loanContract.target, loan.assetAmount);
        await loanContract.connect(lender).fillRequest(0);

        await mockAssetOracle.setAnswer(2000000000);
        await mockCollateralOracle.setAnswer(100000000);

        await loanContract.connect(liquidator).liquidateLoan(0);
        const storedLoan = await loanContract.loans(0);
        expect(storedLoan.status).to.equal(4); // Liquidated status
    });

    it("should complete full loan lifecycle: Request -> Fill -> Liquidate (time)", async function () {
        const encodedLoan = encodeLoan(loan);
        await loanContract.connect(borrower).requestLoan(encodedLoan);

        await mockCollateral.connect(borrower).approve(loanContract.target, loan.collateralAmount);
        await mockAsset.connect(lender).approve(loanContract.target, loan.assetAmount);
        await loanContract.connect(lender).fillRequest(0);

        // Advance time to make the loan overdue
        await ethers.provider.send("evm_increaseTime", [loan.duration + 1]);
        await ethers.provider.send("evm_mine", []);

        // Liquidate by time
        await loanContract.connect(liquidator).liquidateLoan(0);
        const storedLoan = await loanContract.loans(0);
        expect(storedLoan.status).to.equal(4); // Liquidated status
    });

    it("should complete full loan lifecycle: Request -> Cancel", async function () {
        const encodedLoan = encodeLoan(loan);
        await loanContract.connect(borrower).requestLoan(encodedLoan);

        // Cancel loan
        await loanContract.connect(borrower).cancelLoan(0);
        const storedLoan = await loanContract.loans(0);
        expect(storedLoan.status).to.equal(1); // Canceled status
    });
});
