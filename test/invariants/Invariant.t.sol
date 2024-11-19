// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {LendingP2P} from "../../contracts/LendingP2P.sol";
import {Handler} from "./Handler.t.sol";
import {MockERC20} from "../../contracts/mocks/MockERC20.sol";
import {MockERC20Metadata} from "../../contracts/mocks/MockERC20Metadata.sol";
import {console} from "forge-std/console.sol";

contract InvariantTest is Test {
    LendingP2P public lendingP2P;
    Handler public handler;

    function setUp() public {
        // Deploy main contract
        lendingP2P = new LendingP2P();

        // Deploy handler
        handler = new Handler(lendingP2P);

        // Target handler for invariant testing
        targetContract(address(handler));

        // Add function selectors to be called during invariant testing
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.requestLoan.selector;
        selectors[1] = handler.fillRequest.selector;
        selectors[2] = handler.liquidateLoan.selector;
        selectors[3] = handler.repayLoan.selector;
        selectors[4] = handler.cancelLoan.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_ifLoanMeetsConditions_itCanBeLiquidated() public view {
        // For each loan that exists
        for (uint256 i = 0; i < lendingP2P.loanLength(); i++) {
            if (!handler.loanExists(i)) continue;

            // Only check loans that have attempted liquidation
            if (!handler.loanAttemptedLiquidation(i)) continue;

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
            ) = lendingP2P.loans(i);

            if (handler.loanLiquidationFailed(i)) {
                console.log("Loan liquidation failed loanId:", i);
                assertFalse(handler.loanLiquidationFailed(i), "Liquidatable loan couldn't be liquidated");
            }
        }
    }

    function invariant_contractBalanceMatchesActiveLoans() public view {
        uint256 totalExpectedCollateral = 0;

        // Iterate through all loans
        for (uint256 i = 0; i < lendingP2P.loanLength(); i++) {
            if (!handler.loanExists(i)) continue;

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
            ) = lendingP2P.loans(i);

            // Only sum collateral for active loans
            if (loan.status == LendingP2P.Status.Active) {
                totalExpectedCollateral += loan.collateralAmount;
            }
        }

        uint256 actualBalance = MockERC20Metadata(handler.mockCollateral()).balanceOf(address(lendingP2P));
        assertEq(
            actualBalance, totalExpectedCollateral, "Contract collateral balance does not match sum of active loans"
        );
    }

    function invariant_repaidLoanBalancesAreCorrect() public {
        uint256 totalFeeCollected = 0;
        uint256 totalLenderRepayment = 0;
        uint256 totalCollateralReturned = 0;

        // Iterate through all loans
        for (uint256 i = 0; i < lendingP2P.loanLength(); i++) {
            if (!handler.loanExists(i)) continue;
            if (!handler.loanRepaid(i)) continue; // Only check repaid loans

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
            ) = lendingP2P.loans(i);

            // Calculate fee for this loan
            uint256 loanFee = (loan.repaymentAmount - loan.assetAmount) * lendingP2P.PROTOCOL_FEE() / 10000;
            uint256 lenderAmount = loan.repaymentAmount - loanFee;

            totalFeeCollected += loanFee;
            totalLenderRepayment += lenderAmount;
            totalCollateralReturned += loan.collateralAmount;
        }

        // Check borrower collateral balance
        uint256 borrowerCollateralBalance = MockERC20Metadata(handler.mockCollateral()).balanceOf(makeAddr("borrower"));
        assertEq(
            borrowerCollateralBalance,
            totalCollateralReturned,
            "Borrower collateral balance does not match expected collateral returned"
        );

        // Check fee collector balance
        address feeCollector = lendingP2P.feeCollector();
        uint256 feeCollectorBalance = MockERC20(handler.mockAsset()).balanceOf(feeCollector);
        assertEq(
            feeCollectorBalance,
            totalFeeCollected,
            "Fee collector balance does not match expected fees from repaid loans"
        );

        // Check contract's asset balance (should only hold active loan repayments)
        uint256 lenderAssetBalance = MockERC20(handler.mockAsset()).balanceOf(makeAddr("lender"));
        assertEq(
            lenderAssetBalance, totalLenderRepayment, "Lender asset balance does not match expected lender repayments"
        );
    }

    function invariant_liquidatedLoanBalancesAreCorrect() public view {
        uint256 totalLiquidatorCollateral = 0;
        uint256 totalLiquidationFees = 0;
        uint256 totalLenderCollateral = 0;

        // Iterate through all loans
        for (uint256 i = 0; i < lendingP2P.loanLength(); i++) {
            if (!handler.loanExists(i)) continue;
            if (!handler.loanAttemptedLiquidation(i)) continue;

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
            ) = lendingP2P.loans(i);
            if (loan.status == LendingP2P.Status.Liquidated) {
                // Calculate liquidation distributions
                uint256 liquidatorBonus = loan.collateralAmount * lendingP2P.LIQUIDATOR_BONUS_BPS() / 10000;
                uint256 protocolFee = loan.collateralAmount * lendingP2P.PROTOCOL_LIQUIDATION_FEE() / 10000;
                uint256 lenderCollateral = loan.collateralAmount - liquidatorBonus - protocolFee;
                totalLiquidatorCollateral += liquidatorBonus;
                totalLiquidationFees += protocolFee;
                totalLenderCollateral += lenderCollateral; 
            }
        }

        // Check liquidator's collateral balance
        uint256 liquidatorBalance = MockERC20Metadata(handler.mockCollateral()).balanceOf(handler.liquidator());
        assertEq(
            liquidatorBalance, totalLiquidatorCollateral, "Liquidator collateral balance does not match expected amount"
        );

        // Check fee collector's collateral balance from liquidations
        address feeCollector = lendingP2P.feeCollector();
        uint256 feeCollectorBalance = MockERC20Metadata(handler.mockCollateral()).balanceOf(feeCollector);
        assertEq(
            feeCollectorBalance,
            totalLiquidationFees,
            "Fee collector collateral balance does not match expected liquidation fees"
        );

        // Check lender's collateral balance from liquidations
        uint256 lenderCollateralBalance = MockERC20Metadata(handler.mockCollateral()).balanceOf(handler.lender());
        assertEq(
            lenderCollateralBalance,
            totalLenderCollateral,
            "Lender collateral balance does not match expected amount from liquidations"
        );
    }
}
