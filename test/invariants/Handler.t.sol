// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {LendingP2P} from "../../contracts/LendingP2P.sol";
import {MockERC20} from "../../contracts/mocks/MockERC20.sol";
import {MockERC20Metadata} from "../../contracts/mocks/MockERC20Metadata.sol";
import {Aggregator} from "../../contracts/mocks/Aggregator.sol";
import {console} from "forge-std/console.sol";

contract Handler is Test {
    LendingP2P public lendingP2P;
    MockERC20 public mockAsset;
    MockERC20Metadata public mockCollateral;
    Aggregator public assetOracle;
    Aggregator public collateralOracle;

    address public borrower;
    address public lender;
    address public liquidator;

    // Ghost variables for invariant testing
    bool public lastLiquidationSuccess;
    mapping(uint256 => bool) public loanAttemptedLiquidation;
    mapping(uint256 => bool) public loanLiquidationFailed;
    mapping(uint256 => bool) public loanExists;
    mapping(uint256 => bool) public loanRepaid;
    mapping(uint256 => bool) public loanCanceled;

    // Constants for price calculations
    uint256 constant INITIAL_ASSET_PRICE = 2000e8; // $2000
    uint256 constant INITIAL_COLLATERAL_PRICE = 50000e8; // $50000
    uint256 constant MAX_LOAN_AMOUNT = type(uint128).max; //340282366920938463463374607431768211455
    uint256 constant MIN_LOAN_AMOUNT = 1000;

    constructor(LendingP2P _lendingP2P) {
        lendingP2P = _lendingP2P;

        // Create accounts
        borrower = makeAddr("borrower");
        lender = makeAddr("lender");
        vm.label(borrower, "Borrower");
        vm.label(lender, "Lender");

        liquidator = makeAddr("liquidator");
    vm.label(liquidator, "Liquidator");

        // Deploy mock tokens
        mockAsset = new MockERC20();
        mockCollateral = new MockERC20Metadata("Mock Collateral", "MCOL", 18);
        vm.label(address(mockAsset), "Asset Token");
        vm.label(address(mockCollateral), "Collateral Token");

        // Deploy mock oracles
        assetOracle = new Aggregator();
        collateralOracle = new Aggregator();
        vm.label(address(assetOracle), "Asset Oracle");
        vm.label(address(collateralOracle), "Collateral Oracle");

        // Set initial oracle prices
        setDefaultPrices();
    }

    function requestLoan(uint256 assetAmount, uint256 repaymentAmount, uint64 duration, uint16 liquidationThreshold)
        public
    {
        // Bound inputs to reasonable values
        assetAmount = bound(assetAmount, MIN_LOAN_AMOUNT, MAX_LOAN_AMOUNT);
        repaymentAmount = bound(repaymentAmount, assetAmount + 1, assetAmount * 5);
        duration = uint64(bound(duration, 1 days, 365 days));
        liquidationThreshold = uint16(bound(liquidationThreshold, 1000, 10000)); // 10% to 100%
        setDefaultPrices();
        // Calculate required collateral based on liquidationThreshold
        uint256 collateralAmount =
            (assetAmount * INITIAL_ASSET_PRICE * 10000) / (INITIAL_COLLATERAL_PRICE * liquidationThreshold);
        // Add 10% buffer to ensure it's not instantly liquidatable
        collateralAmount = (collateralAmount * 110) / 100;
        // Prepare tokens
        vm.startPrank(borrower);
        // Create loan struct
        bytes memory encodedLoan = abi.encode(
            LendingP2P.Loan({
                borrower: borrower,
                lender: lender,
                asset: address(mockAsset),
                collateral: address(mockCollateral),
                assetAmount: assetAmount,
                repaymentAmount: repaymentAmount,
                collateralAmount: collateralAmount,
                createdTimestamp: 0, // Will be set by contract
                startTimestamp: 0,
                duration: duration,
                status: LendingP2P.Status.Pending,
                liquidation: LendingP2P.Liquidation({
                    isLiquidatable: true,
                    liquidationThreshold: liquidationThreshold,
                    assetOracle: address(assetOracle),
                    collateralOracle: address(collateralOracle)
                })
            })
        );

        try lendingP2P.requestLoan(encodedLoan) {
            uint256 loanId = lendingP2P.loanLength() - 1;
            loanExists[loanId] = true;
        } catch {
            // Failed request
        }
        vm.stopPrank();
    }

    function fillRequest(uint256 loanId) public {
        // Bound loanId to existing loans
        if (lendingP2P.loanLength() == 0) return;
        loanId = bound(loanId, 0, lendingP2P.loanLength() - 1);
        if (!loanExists[loanId]) return;

        setDefaultPrices();

        LendingP2P.Loan memory loan;
        (
            loan.borrower,
            loan.lender,
            loan.asset,
            loan.collateral,
            loan.assetAmount,
            loan.repaymentAmount,
            loan.collateralAmount,
            loan.createdTimestamp,
            loan.startTimestamp,
            loan.duration,
            loan.status,
            loan.liquidation
        ) = lendingP2P.loans(loanId);

        // Only fill if loan is pending
        if (loan.status != LendingP2P.Status.Pending) return;

        // Ensure we're within the expiration window
        if (loan.createdTimestamp + lendingP2P.REQUEST_EXPIRATION_DURATION() <= block.timestamp) {
            // Instead of going backwards in time, set the time to just before expiration
            uint256 validTime = loan.createdTimestamp + lendingP2P.REQUEST_EXPIRATION_DURATION() - 1 hours;
            vm.warp(validTime);
        }

        // Prepare borrower
        vm.startPrank(borrower);
        mockCollateral.mint(borrower, loan.collateralAmount);
        mockCollateral.approve(address(lendingP2P), loan.collateralAmount);
        vm.stopPrank();

        // Prepare lender
        vm.startPrank(lender);
        mockAsset.mint(lender, loan.assetAmount);
        mockAsset.approve(address(lendingP2P), loan.assetAmount);

        lendingP2P.fillRequest(loanId);

        vm.stopPrank();
    }

    function liquidateLoan(uint256 loanId, bool timeBased) public {
        // Bound loanId to existing loans
        if (lendingP2P.loanLength() == 0) return;

        loanId = bound(loanId, 0, lendingP2P.loanLength() - 1);
        if (!loanExists[loanId]) return;

        LendingP2P.Loan memory loan;
        (
            loan.borrower,
            loan.lender,
            loan.asset,
            loan.collateral,
            loan.assetAmount,
            loan.repaymentAmount,
            loan.collateralAmount,
            loan.createdTimestamp,
            loan.startTimestamp,
            loan.duration,
            loan.status,
            loan.liquidation
        ) = lendingP2P.loans(loanId);

        // Only proceed if loan is Active
        if (loan.status != LendingP2P.Status.Active) return;

        // First try to liquidate by price (if loan is liquidatable)
        if (!timeBased) {
            // Calculate prices that will make loan value exceed the liquidation threshold
            uint256 targetRatio = loan.liquidation.liquidationThreshold + 100; // Add 1% buffer
            uint256 loanValue = loan.assetAmount * INITIAL_ASSET_PRICE;
            uint256 requiredCollateralValue = (loanValue * targetRatio) / 10000;
            uint256 newCollateralPrice = (requiredCollateralValue) / loan.collateralAmount;
            // Set new prices to trigger liquidation
            setOraclePrices(int256(INITIAL_ASSET_PRICE), int256(newCollateralPrice));
        } else {
            vm.warp(loan.startTimestamp + loan.duration + 1);
            // If price-based liquidation no new prices are required.
            setDefaultPrices();
        }   
        vm.startPrank(liquidator);
        try lendingP2P.liquidateLoan(loanId) returns (bool success) {
            lastLiquidationSuccess = success;
            loanAttemptedLiquidation[loanId] = true;
        } catch {
            lastLiquidationSuccess = false;
            loanLiquidationFailed[loanId] = true;
            loanAttemptedLiquidation[loanId] = true;
        }
        vm.stopPrank();
    }

    function repayLoan(uint256 loanId) public {
        // Bound loanId to existing loans
        if (lendingP2P.loanLength() == 0) return;
        loanId = bound(loanId, 0, lendingP2P.loanLength() - 1);
        if (!loanExists[loanId]) return;

        LendingP2P.Loan memory loan;
        (
            loan.borrower,
            loan.lender,
            loan.asset,
            loan.collateral,
            loan.assetAmount,
            loan.repaymentAmount,
            loan.collateralAmount,
            loan.createdTimestamp,
            loan.startTimestamp,
            loan.duration,
            loan.status,
            loan.liquidation
        ) = lendingP2P.loans(loanId);

        // Only proceed if loan is Active
        if (loan.status != LendingP2P.Status.Active) return;

        // Prepare borrower with repayment amount
        vm.startPrank(borrower);
        mockAsset.mint(borrower, loan.repaymentAmount);
        mockAsset.approve(address(lendingP2P), loan.repaymentAmount);

        try lendingP2P.repayLoan(loanId) {
            // Repayment successful
            loanRepaid[loanId] = true;
        } catch {
            revert("Repayment failed");
        }

        vm.stopPrank();
    }

    function cancelLoan(uint256 loanId) public {
        // Bound loanId to existing loans
        if (lendingP2P.loanLength() == 0) return;
        loanId = bound(loanId, 0, lendingP2P.loanLength() - 1);
        if (!loanExists[loanId]) return;

        LendingP2P.Loan memory loan;
        (
            loan.borrower,
            loan.lender,
            loan.asset,
            loan.collateral,
            loan.assetAmount,
            loan.repaymentAmount,
            loan.collateralAmount,
            loan.createdTimestamp,
            loan.startTimestamp,
            loan.duration,
            loan.status,
            loan.liquidation
        ) = lendingP2P.loans(loanId);

        // Only proceed if loan is Pending
        if (loan.status != LendingP2P.Status.Pending) return;

        // Ensure we're within the expiration window
        if (loan.createdTimestamp + lendingP2P.REQUEST_EXPIRATION_DURATION() <= block.timestamp) {
            // Instead of going backwards in time, set the time to just before expiration
            uint256 validTime = loan.createdTimestamp + lendingP2P.REQUEST_EXPIRATION_DURATION() - 1 hours;
            vm.warp(validTime);
        }

        vm.startPrank(borrower);
        try lendingP2P.cancelLoan(loanId) {
            // Cancellation successful
            loanCanceled[loanId] = true;
        } catch {
            revert("Cancellation failed");
        }
        vm.stopPrank();
    }

    function setDefaultPrices() public {
        assetOracle.setAnswer(int256(INITIAL_ASSET_PRICE));
        collateralOracle.setAnswer(int256(INITIAL_COLLATERAL_PRICE));
    }

    function setOraclePrices(int256 assetPrice, int256 collateralPrice) public {
        assetOracle.setAnswer(assetPrice);
        collateralOracle.setAnswer(collateralPrice);
    }

    function warpTime(uint256 timeToAdd) public {
        vm.warp(block.timestamp + timeToAdd);
    }
}
