const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture } = require("@nomicfoundation/hardhat-network-helpers");

const { encodeLoan } = require("./utils")

describe("Oracle", function () {
    async function deployContractFixture() {
        const [owner, borrower, lender] = await ethers.getSigners();

        const MockToken = await ethers.getContractFactory("MockERC20Metadata");
        const assetToken = await MockToken.deploy("Asset", "AST", 6); // 6 decimals
        const collateralToken = await MockToken.deploy("Collateral", "COL", 18); // 18 decimals

        const MockOracle = await ethers.getContractFactory("Aggregator");
        const assetOracle = await MockOracle.deploy();
        const collateralOracle = await MockOracle.deploy();

        const LendingP2P = await ethers.getContractFactory("LendingP2P");
        const lending = await LendingP2P.deploy();

        const ASSET_PRICE = ethers.parseUnits("1", 8); // $1.00
        const COLLATERAL_PRICE = ethers.parseUnits("1500", 8); // $1500.00
        await assetOracle.setAnswer(ASSET_PRICE);
        await collateralOracle.setAnswer(COLLATERAL_PRICE);

        async function createLoanRequest(
            assetAmount,
            repaymentAmount,
            collateralAmount,
            liquidationThreshold = 8000 // 80% by default
        ) {
            await assetToken.connect(owner).mint(lender.address, assetAmount)
            await collateralToken.connect(owner).mint(borrower.address, collateralAmount)

            const loan = {
                borrower: borrower.address,
                lender: ethers.ZeroAddress,
                asset: assetToken.target,
                collateral: collateralToken.target,
                assetAmount: assetAmount,
                repaymentAmount: repaymentAmount,
                collateralAmount: collateralAmount,
                createdTimestamp: 0,
                startTimestamp: 0,
                duration: 7 * 24 * 3600, // 7 days
                status: 0, // Pending
                liquidation: {
                    isLiquidatable: true,
                    liquidationThreshold: liquidationThreshold,
                    assetOracle: assetOracle.target,
                    collateralOracle: collateralOracle.target,
                },
            };
            let encodedLoan = encodeLoan(loan)
            return await lending.connect(borrower).requestLoan(encodedLoan);
        }

        return {
            lending,
            assetToken,
            collateralToken,
            assetOracle,
            collateralOracle,
            owner,
            borrower,
            lender,
            createLoanRequest,
        };
    }

    it("should correctly handle different token decimals", async function () {
        const { lending, createLoanRequest, assetOracle, collateralOracle } = await loadFixture(deployContractFixture);

        // 1000 USDC (6 decimals) vs 1 ETH (18 decimals)
        const assetAmount = ethers.parseUnits("1000", 6); // 1000 worth of asset
        const collateralAmount = ethers.parseUnits("1", 18); // 1500 worth of collateral

        await createLoanRequest(
            assetAmount,
            assetAmount + ethers.parseUnits("100", 6), 
            collateralAmount
        );

        expect(await lending._isLoanLiquidatable(0)).to.be.false;
    });

    it("should properly normalize prices", async function () {
        const { lending, createLoanRequest, assetOracle, collateralOracle } = await loadFixture(deployContractFixture);

        //set prices with different decimals but same effective price
        await assetOracle.setAnswer(ethers.parseUnits("100", 8));
        await collateralOracle.setAnswer(ethers.parseUnits("100", 8));

        const assetAmount = ethers.parseUnits("1", 6);
        const collateralAmount = ethers.parseUnits("1.25", 18); //1.25 * 0.8 = 1

        await createLoanRequest(
            assetAmount,
            assetAmount + ethers.parseUnits("0.1", 6),
            collateralAmount,
            8000
        );

        expect(await lending._isLoanLiquidatable(0)).to.be.false;
    });

    it("should handle price updates correctly", async function () {
        const { 
            lending, assetToken, collateralToken, 
            createLoanRequest, collateralOracle,
            borrower, lender
         } = await loadFixture(deployContractFixture);

        const assetAmount = ethers.parseUnits("1000", 6);
        const collateralAmount = ethers.parseUnits("1", 18);

        await createLoanRequest(
            assetAmount,
            assetAmount + ethers.parseUnits("100", 6),
            collateralAmount
        );

        await assetToken.connect(lender).approve(lending.target, "99999999999999999999999999999999");
        await collateralToken.connect(borrower).approve(lending.target, "99999999999999999999999999999999");
        await lending.connect(lender).fillRequest(0)

        expect(await lending._isLoanLiquidatable(0)).to.be.false;
        await collateralOracle.setAnswer(ethers.parseUnits("1", 8));
        expect(await lending._isLoanLiquidatable(0)).to.be.true;
    });

    it("should revert: on oracle reversion", async function () {
        const { lending, createLoanRequest, assetOracle, assetToken, collateralToken, lender, borrower } = await loadFixture(deployContractFixture);

        const assetAmount = ethers.parseUnits("1000", 6);
        const collateralAmount = ethers.parseUnits("1", 18);

        await createLoanRequest(
            assetAmount,
            assetAmount + ethers.parseUnits("100", 6),
            collateralAmount
        );

        await assetToken.connect(lender).approve(lending.target, "99999999999999999999999999999999");
        await collateralToken.connect(borrower).approve(lending.target, "99999999999999999999999999999999");
        await lending.connect(lender).fillRequest(0)

        await assetOracle.setRevert(true);

        await expect(lending._isLoanLiquidatable(0)).to.be.reverted;
    });

    it("should revert: on zero prices", async function () {
        const { lending, createLoanRequest, assetOracle, assetToken, collateralToken, lender, borrower } = await loadFixture(deployContractFixture);

        const assetAmount = ethers.parseUnits("1000", 6);
        const collateralAmount = ethers.parseUnits("1", 18);

        await createLoanRequest(
            assetAmount,
            assetAmount + ethers.parseUnits("100", 6),
            collateralAmount
        );

        await assetToken.connect(lender).approve(lending.target, "99999999999999999999999999999999");
        await collateralToken.connect(borrower).approve(lending.target, "99999999999999999999999999999999");
        await lending.connect(lender).fillRequest(0)

        await assetOracle.setAnswer(0);

        await expect(lending._isLoanLiquidatable(0)).to.be.revertedWith("invalid oracle price");
    });
});