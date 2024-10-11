// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { AggregatorInterface } from './dependencies/AggregatorInterface.sol';

/**
 * @title  LendingP2P
 * @author HyperLend (@fbsloXBT)
 * @notice Main contract of the HyperLend P2P lending market.
 */
contract LendingP2P is ReentrancyGuard, Ownable {
    enum Status {
        Pending,
        Canceled,
        Active,
        Repaid,
        Liquidated
    }

    /// @notice details about loan liquidation
    struct Liquidation {
        bool isLiquidatable;          // can the loan be liquidated before it's defaulted
        uint256 liquidationThreshold; // threshold where loan can be liquidated in bps, e.g. 8000 = liquidated when loan value > 80% of the collateral value
        address assetOracle;          // chainlink oracle for the borrowed asset
        address collateralOracle;     // chainlink oracle for the collateral asset, must be in same currency as assetOracle
    }

    /// @notice details about the individual loan
    struct Loan {
        address borrower;         // address of the borrower
        address lender;           // address of the lender
        address asset;            // address of the asset being borrowed
        address collateral;       // address of the asset used as a collateral

        uint256 assetAmount;      // amount of the asset being paid to borrower by lender
        uint256 repaymentAmount;  // amount of the asset being repaid by the lender
        uint256 collateralAmount; // amount of the collateral being pledged by the borrower

        uint256 createdTimestamp; // timestamp when loan request was created
        uint256 startTimestamp;   // timestamp when loan was accepted
        uint256 duration;         // duration of the loan in seconds

        Liquidation liquidation; // details about the loan liquidation
        Status status;           // current status of the loan
    }

    /// @notice emitted when a new loan is requested
    event LoanRequested(uint256 indexed loanId);
    /// @notice emitted when a loan is canceled
    event LoanCanceled(uint256 indexed loanId);
    /// @notice emitted when a loan request is filled
    event LoanFilled(uint256 indexed loanId);
    /// @notice emitted when a loan is repaid
    event LoanRepaid(uint256 indexed loanId);
    /// @notice emitted when a loan is liquidated
    event LoanLiquidated(uint256 indexed loanId);
    /// @notice emitted when protocol earns some revenue
    event ProtocolRevenue(uint256 indexed loanId, address indexed asset, uint256 amount);

    /// @notice maximum duration that the loan request can be active
    uint256 public constant REQUEST_EXPIRATION_DURATION = 7 days;
    /// @notice protocol fee, charged on interest, in bps
    uint256 public constant PROTOCOL_FEE = 2000;

    /// @notice length of all loans
    uint256 public loanLength = 0;
    /// @notice mapping of all loans
    mapping(uint256 => Loan) public loans;

    constructor() Ownable(msg.sender) {}

    /// @notice function used to request a new loan
    function requestLoan(bytes memory _encodedLoan) external nonReentrant {
        Loan memory loan = abi.decode(_encodedLoan, (Loan));

        require(loan.repaymentAmount > loan.assetAmount, "amount > repayment");
        require(loan.asset != loan.collateral, "asset == collateral");

        loan.createdTimestamp = block.timestamp;
        loan.startTimestamp = 0;
        loan.status = Status.Pending;

        loans[loanLength] = loan;
        loanLength += 1;

        emit LoanRequested(loanLength - 1);
    }

    /// @notice function used to cancel a unfilled loan
    function cancelLoan(uint256 loanId) external nonReentrant {
        require(loans[loanId].status == Status.Pending, "invalid status");
        require(loans[loanId].createdTimestamp + REQUEST_EXPIRATION_DURATION > block.timestamp, "request already expired");
        require(loans[loanId].borrower == msg.sender, "sender is not borrower");

        loans[loanId].status = Status.Canceled;

        emit LoanCanceled(loanId);
    }

    /// @notice function used to fill a loan request
    function fillRequest(uint256 loanId) external nonReentrant {
        require(loans[loanId].status == Status.Pending, "invalid status");
        require(loans[loanId].createdTimestamp + REQUEST_EXPIRATION_DURATION > block.timestamp, "request already expired");

        loans[loanId].lender = msg.sender;
        loans[loanId].startTimestamp = block.timestamp;

        IERC20(loans[loanId].collateral).transferFrom(loans[loanId].borrower, address(this), loans[loanId].collateralAmount);
        IERC20(loans[loanId].asset).transferFrom(loans[loanId].lender, loans[loanId].borrower, loans[loanId].assetAmount);

        emit LoanFilled(loanId);
    }

    /// @notice function used to repay a loan
    function repayLoan(uint256 loanId) external nonReentrant {
        require(loans[loanId].status == Status.Active, "invalid status");
        require(loans[loanId].startTimestamp + loans[loanId].duration > block.timestamp, "loan already expired");

        // fee is charged on interest only
        uint256 protocolFee = (loans[loanId].repaymentAmount - loans[loanId].assetAmount) * PROTOCOL_FEE / 10000;
        uint256 amountToLender = loans[loanId].repaymentAmount - protocolFee;

        IERC20(loans[loanId].asset).transferFrom(address(this), owner(), protocolFee);
        IERC20(loans[loanId].asset).transferFrom(loans[loanId].borrower, loans[loanId].lender, amountToLender);
        IERC20(loans[loanId].collateral).transferFrom(address(this), loans[loanId].borrower, loans[loanId].collateralAmount);

        loans[loanId].status = Status.Repaid;

        emit LoanRepaid(loanId);
        emit ProtocolRevenue(loanId, loans[loanId].asset, protocolFee);
    }   

    /// @notice function used to liquidate a loan
    /// @dev loan can be liquiated either if it's overdue, or if it's insolvent (only for liquidatable loans)
    function liquidateLoan(uint256 loanId) external nonReentrant {
        require(loans[loanId].status == Status.Active, "invalid status");

        if (isLoanLiquidatable(loanId)){
            //liquidate by price
            IERC20(loans[loanId].collateral).transferFrom(address(this), loans[loanId].lender, loans[loanId].collateralAmount);
            loans[loanId].status = Status.Liquidated;
            emit LoanLiquidated(loanId);
        } else if (loans[loanId].status == Status.Active && block.timestamp > loans[loanId].startTimestamp + loans[loanId].duration) {
            //liquidate by time
            IERC20(loans[loanId].collateral).transferFrom(address(this), loans[loanId].lender, loans[loanId].collateralAmount);
            loans[loanId].status = Status.Liquidated;
            emit LoanLiquidated(loanId);
        }
    }

    function isLoanLiquidatable(uint256 loanId) public view returns (bool) {
        if (loans[loanId].liquidation.isLiquidatable){
            uint256 assetPrice = uint256(AggregatorInterface(loans[loanId].liquidation.assetOracle).latestAnswer());
            uint256 collateralPrice = uint256(AggregatorInterface(loans[loanId].liquidation.collateralOracle).latestAnswer());

            uint256 loanValue = assetPrice * loans[loanId].assetAmount;
            uint256 collateralValue = collateralPrice * loans[loanId].collateralAmount;

            return (loanValue > (collateralValue * loans[loanId].liquidation.liquidationThreshold / 10000));
        } 

        return false;
    }
}
