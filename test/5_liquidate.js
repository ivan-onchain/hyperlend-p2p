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

    let loan;
    let mockAsset;
    let mockCollateral;

    let aggregatorAsset;
    let aggregatorColateral;

    beforeEach(async function () {
        const LoanContract = await ethers.getContractFactory("LendingP2P"); 
        [borrower, lender, deployer] = await ethers.getSigners();

        loanContract = await LoanContract.connect(deployer).deploy();

        const MockToken = await ethers.getContractFactory("MockERC20"); 
        mockAsset = await MockToken.connect(borrower).deploy()
        mockCollateral = await MockToken.connect(borrower).deploy()

        const MockAggregator = await ethers.getContractFactory("Aggregator"); 
        aggregatorAsset = await MockAggregator.connect(deployer).deploy();
        aggregatorColateral = await MockAggregator.connect(deployer).deploy();

        await aggregatorAsset.connect(deployer).setAnswer(200000000000); //2k usd
        await aggregatorColateral.connect(deployer).setAnswer(5000000000000); //50k usd

        loan = {
            borrower: borrower.address,
            lender: "0x0000000000000000000000000000000000000000",
            asset: mockAsset.target,
            collateral: mockCollateral.target,
    
            assetAmount: ethers.parseEther("10"), //20k usd
            repaymentAmount: ethers.parseEther("11"),
            collateralAmount: ethers.parseEther("0.6"), //30k usd => 24k max borrow @ 80% lltv
    
            duration: 30 * 24 * 60 * 60, 
    
            liq: {
                isLiquidatable: true,
                liquidationThreshold: 8000,
                assetOracle: aggregatorAsset.target, 
                collateralOracle: aggregatorColateral.target
            },
            status: 0 //Pending
        };
    });

    it("should succeed: liquidate a valid liquidatable loan", async function () {
        const encodedLoan = encodeLoan(loan)
        await loanContract.connect(borrower).requestLoan(encodedLoan);

        await mockAsset.connect(borrower).transfer(lender.address, loan.assetAmount)

        let balancesBefore = {
            borrower: {
                asset: await mockAsset.balanceOf(borrower.address),
                collateral: await mockCollateral.balanceOf(borrower.address),
            },
            lender: {
                asset: await mockAsset.balanceOf(lender.address),
                collateral: await mockCollateral.balanceOf(lender.address),
            }
        }

        expect(balancesBefore.borrower.asset).to.equal("999999990000000000000000000");
        expect(balancesBefore.borrower.collateral).to.equal("1000000000000000000000000000");
        expect(balancesBefore.lender.asset).to.equal(loan.assetAmount);
        expect(balancesBefore.lender.collateral).to.equal("0");

        await mockCollateral.connect(borrower).approve(loanContract.target, loan.collateralAmount)
        await mockAsset.connect(lender).approve(loanContract.target, loan.assetAmount)

        await loanContract.connect(lender).fillRequest(0);

        let balancesAfter = {
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

        expect(storedLoan.liquidation.isLiquidatable).to.equal(loan.liq.isLiquidatable);
        expect(storedLoan.liquidation.liquidationThreshold).to.equal(loan.liq.liquidationThreshold);
        expect(storedLoan.liquidation.assetOracle).to.equal(loan.liq.assetOracle);
        expect(storedLoan.liquidation.collateralOracle).to.equal(loan.liq.collateralOracle);

        expect(storedLoan.status).to.equal(2);

        //liquidate loan
        await mockAsset.connect(borrower).approve(loanContract.target, loan.repaymentAmount)
        await loanContract.connect(borrower).repayLoan(0);

        let balancesAfterLiquidate = {
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
                asset: await mockAsset.balanceOf(deployer.address)
            }
        }

        // expect(balancesAfterLiquidate.borrower.asset).to.equal(balancesBefore.borrower.asset + loan.assetAmount - loan.repaymentAmount);

        const storedLoanAfterLiquidate = await loanContract.loans(0);
        expect(storedLoanAfterLiquidate.status).to.equal(4);
    });
});
