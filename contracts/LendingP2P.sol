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

    constructor() Ownable(msg.sender) {}

    /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/
    /*                          Structs                         */
    /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/

    /// @notice details about loan liquidation
    struct Liquidation {
        bool isLiquidatable;          // can the loan be liquidated before it's defaulted
        uint16 liquidationThreshold;  // threshold where loan can be liquidated in bps, e.g. 8000 = liquidated when loan value > 80% of the collateral value
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

        uint64 createdTimestamp;  // timestamp when loan request was created
        uint64 startTimestamp;    // timestamp when loan was accepted
        uint64 duration;          // duration of the loan in seconds

        Liquidation liquidation; // details about the loan liquidation
        Status status;           // current status of the loan
    }

    /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/
    /*                         Events                           */
    /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/

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

    /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/
    /*                        Constants                         */
    /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/

    /// @notice maximum duration that the loan request can be active
    uint256 public constant REQUEST_EXPIRATION_DURATION = 7 days;
    /// @notice protocol fee, charged on interest, in bps
    uint256 public constant PROTOCOL_FEE = 2000;
    /// @notice fee paid to the liquidator, in bps
    uint256 public constant LIQUIDATOR_BONUS_BPS = 100;
    /// @notice fee paid to the protocol, in bps
    uint256 public constant PROTOCOL_LIQUIDATION_FEE = 20;

    /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/
    /*                        Variables                         */
    /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/

    /// @notice length of all loans
    uint256 public loanLength = 0;
    /// @notice mapping of all loans
    mapping(uint256 => Loan) public loans;

    /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/
    /*                    Public Functions                      */
    /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/

    /// @notice function used to request a new loan
    function requestLoan(bytes memory _encodedLoan) external nonReentrant {
        Loan memory loan = abi.decode(_encodedLoan, (Loan));

        require(loan.borrower == msg.sender, "borrower != msg.sender");
        require(loan.repaymentAmount > loan.assetAmount, "amount <= repayment");
        require(loan.asset != loan.collateral, "asset == collateral");
        require(loan.liquidation.liquidationThreshold <= 10000, "liq threshold > max bps");

        loan.createdTimestamp = uint64(block.timestamp);
        loan.startTimestamp = 0;
        loan.status = Status.Pending;

        loans[loanLength] = loan;
        loanLength += 1;

        emit LoanRequested(loanLength - 1);
    }

    /// @notice function used to cancel a unfilled loan
    function cancelLoan(uint256 loanId) external nonReentrant {
        require(loans[loanId].status == Status.Pending, "invalid status");
        require(loans[loanId].createdTimestamp + REQUEST_EXPIRATION_DURATION > block.timestamp, "already expired");
        require(loans[loanId].borrower == msg.sender, "sender != borrower");

        loans[loanId].status = Status.Canceled;

        emit LoanCanceled(loanId);
    }

    /// @notice function used to fill a loan request
    function fillRequest(uint256 loanId) external nonReentrant {
        Loan memory _loan = loans[loanId];

        require(_loan.status == Status.Pending, "invalid status");
        require(_loan.createdTimestamp + REQUEST_EXPIRATION_DURATION > block.timestamp, "already expired");
        if (_loan.liquidation.isLiquidatable){
            require(!_isLoanLiquidatable(loanId), "instantly liqudatable"); //make sure it can't be instantly liquidated
        }

        loans[loanId].lender = msg.sender;
        loans[loanId].startTimestamp = uint64(block.timestamp);
        loans[loanId].status = Status.Active;

        IERC20(_loan.collateral).transferFrom(_loan.borrower, address(this), _loan.collateralAmount);
        IERC20(_loan.asset).transferFrom(msg.sender, _loan.borrower, _loan.assetAmount);

        emit LoanFilled(loanId);
    }

    /// @notice function used to repay a loan
    /// @dev loan can be repaid after expiration, as long it's not liquidated
    /// @dev fee is charged on interest only
    function repayLoan(uint256 loanId) external nonReentrant {
        Loan memory _loan = loans[loanId];

        require(_loan.status == Status.Active, "invalid status");

        uint256 protocolFee = (_loan.repaymentAmount - _loan.assetAmount) * PROTOCOL_FEE / 10000;
        uint256 amountToLender = _loan.repaymentAmount - protocolFee;

        loans[loanId].status = Status.Repaid;

        IERC20(_loan.collateral).transfer(_loan.borrower, _loan.collateralAmount);

        IERC20(_loan.asset).transferFrom(_loan.borrower, owner(), protocolFee);
        IERC20(_loan.asset).transferFrom(_loan.borrower, _loan.lender, amountToLender);

        emit LoanRepaid(loanId);
        emit ProtocolRevenue(loanId, _loan.asset, protocolFee);
    }   

    /// @notice function used to liquidate a loan
    /// @dev loan can be liquiated either if it's overdue, or if it's insolvent (only for liquidatable loans)
    function liquidateLoan(uint256 loanId) external nonReentrant {
        Loan memory _loan = loans[loanId];

        require(_loan.status == Status.Active, "invalid status");

        if (_isLoanLiquidatable(loanId)){
            _liquidate(loanId); //liquidate by price
        } else if (block.timestamp > _loan.startTimestamp + _loan.duration) {
            _liquidate(loanId); //liquidate by time
        }
    }

    /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/
    /*                    Helper Functions                      */
    /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/

    /// @notice internal helper function used to liquidate a loan
    function _liquidate(uint256 loanId) internal {
        Loan memory _loan = loans[loanId];

        uint256 liquidatorBonus = _loan.collateralAmount * LIQUIDATOR_BONUS_BPS / 10000;
        uint256 protocolFee = _loan.collateralAmount * PROTOCOL_LIQUIDATION_FEE / 10000;
        uint256 lenderAmount = _loan.collateralAmount - liquidatorBonus - protocolFee;

        loans[loanId].status = Status.Liquidated;
        
        IERC20(_loan.collateral).transferFrom(address(this), _loan.lender, lenderAmount);
        IERC20(_loan.collateral).transferFrom(address(this), msg.sender, liquidatorBonus);
        IERC20(_loan.collateral).transferFrom(address(this), owner(), protocolFee);

        emit LoanLiquidated(loanId);
        emit ProtocolRevenue(loanId, _loan.collateral, protocolFee);
    }

    function _isLoanLiquidatable(uint256 loanId) public view returns (bool) {
        Loan memory _loan = loans[loanId];

        if (_loan.liquidation.isLiquidatable){
            uint256 assetPrice = uint256(AggregatorInterface(_loan.liquidation.assetOracle).latestAnswer());
            uint256 collateralPrice = uint256(AggregatorInterface(_loan.liquidation.collateralOracle).latestAnswer());

            uint256 loanValue = assetPrice * _loan.assetAmount;
            uint256 collateralValue = collateralPrice * _loan.collateralAmount;

            return (loanValue > (collateralValue * _loan.liquidation.liquidationThreshold / 10000));
        } 

        return false;
    }
}
