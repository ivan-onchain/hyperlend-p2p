const { expect } = require("chai");
const { ethers } = require("hardhat");

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

        const abiEncoder = new ethers.AbiCoder()
        const encodedLoan = abiEncoder.encode(
            [
                "address", "address", "address", "address", 
                "uint256", "uint256", "uint256", 
                "uint256", "uint256", "uint256",
                "tuple(bool, uint256, address, address)",
                "uint8"
            ],
            [
                loan.borrower, loan.lender, loan.asset, loan.collateral,
                loan.assetAmount, loan.repaymentAmount, loan.collateralAmount,
                0, 0, loan.duration,
                [loan.liq.isLiquidatable, loan.liq.liquidationThreshold, loan.liq.assetOracle, loan.liq.collateralOracle],
                loan.status
            ]
        );

        await loanContract.requestLoan(encodedLoan)
    });

    it("should accept a valid loan request", async function () {
        
    });
});
