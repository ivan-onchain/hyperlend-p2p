const { expect } = require("chai");

const { encodeLoan } = require("./utils")

describe("BaseTest", function () {
    let loanContract;

    let borrower;
    let lender;
    let deployer;

    let loan;
    let mockAsset;
    let mockCollateral;

    let aggregatorAsset;
    let aggregatorCollateral;

    beforeEach(async function () {
        const LoanContract = await ethers.getContractFactory("LendingP2P"); 
        [borrower, lender, deployer] = await ethers.getSigners();

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
    
            assetAmount: ethers.parseEther("10"),
            repaymentAmount: ethers.parseEther("11"),
            collateralAmount: ethers.parseEther("1"),
    
            duration: 30 * 24 * 60 * 60, 
    
            liquidation: {
                isLiquidatable: true,
                liquidationThreshold: 8000, //liquidated when loan value > 80% of the collateral value
                assetOracle: aggregatorAsset.target,
                collateralOracle: aggregatorCollateral.target
            },
            status: 0 //Pending
        };
    });

    it("should create a loan request", async function () {
        let encodedLoan = encodeLoan(loan);

        await loanContract.connect(borrower).requestLoan(encodedLoan);

        expect((await loanContract.loans(0)).borrower).to.equal(loan.borrower)
    });
});
