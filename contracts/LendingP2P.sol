// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { AggregatorInterface } from './dependencies/AggregatorInterface.sol';

/**
 * @title  LendingP2P
 * @author HyperLend developers
 * @notice Main contract of the HyperLend P2P lending market.
 */
contract LendingP2P is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    enum Status {
        Pending,
        Canceled,
        Active,
        Repaid,
        Liquidated
    }

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

        Status status;            // current status of the loan
        Liquidation liquidation;  // details about the loan liquidation
    }

    /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/
    /*                         Events                           */
    /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/

    /// @notice emitted when a new loan is requested
    event LoanRequested(uint256 indexed loanId, address indexed borrower);
    /// @notice emitted when a loan is canceled
    event LoanCanceled(uint256 indexed loanId, address indexed borrower);
    /// @notice emitted when a loan request is filled
    event LoanFilled(uint256 indexed loanId, address indexed borrower, address indexed lender);
    /// @notice emitted when a loan is repaid
    event LoanRepaid(uint256 indexed loanId, address indexed borrower, address indexed lender);
    /// @notice emitted when a loan is liquidated
    event LoanLiquidated(uint256 indexed loanId);
    /// @notice emitted when protocol earns some revenue
    event ProtocolRevenue(uint256 indexed loanId, address indexed asset, uint256 amount);
    /// @notice emitted when fee collector changes
    event FeeCollectorUpdated(address oldFeeCollector, address newFeeCollector);
    /// @notice emitted when expiration duration changes
    event ExpirationDurationUpdated(uint256 oldExpirationDuration, uint256 newExpirationDuration);
    /// @notice emitted when protocol fee changes
    event ProtocolFeeUpdated(uint256 oldProtocolFee, uint256 newProtocolFee);
    /// @notice emitted when liquidator bonus changes
    event LiquidatorBonusUpdated(uint256 oldLiquidatorBonus, uint256 newLiquidatorBonus);
    /// @notice emitted when protocol liquidation fee changes
    event ProtocolLiquidationFeeUpdated(uint256 oldProtocolLiquidationFee, uint256 newProtocolLiquidationFee);

    /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/
    /*                     Protocol config                      */
    /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/

    /// @notice maximum duration that the loan request can be active
    uint256 public REQUEST_EXPIRATION_DURATION;
    /// @notice protocol fee, charged on interest, in bps
    uint256 public PROTOCOL_FEE;
    /// @notice fee paid to the liquidator, in bps
    uint256 public LIQUIDATOR_BONUS_BPS;
    /// @notice fee paid to the protocol, in bps
    uint256 public PROTOCOL_LIQUIDATION_FEE;

    /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/
    /*                        Variables                         */
    /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/

    /// @notice length of all loans
    uint256 public loanLength = 0;
    /// @notice mapping of all loans
    mapping(uint256 => Loan) public loans;
    /// @notice address that receives the fees
    address public feeCollector;

    /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/
    /*                    Public Functions                      */
    /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/

    constructor() Ownable(msg.sender) {
        feeCollector = msg.sender;

        REQUEST_EXPIRATION_DURATION = 7 days;
        PROTOCOL_FEE = 2000;
        LIQUIDATOR_BONUS_BPS = 100;
        PROTOCOL_LIQUIDATION_FEE = 20;
    }

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

        emit LoanRequested(loanLength - 1, msg.sender);
    }

    /// @notice function used to cancel a unfilled loan
    function cancelLoan(uint256 loanId) external nonReentrant {
        require(loans[loanId].status == Status.Pending, "invalid status");
        require(loans[loanId].createdTimestamp + REQUEST_EXPIRATION_DURATION > block.timestamp, "already expired");
        require(loans[loanId].borrower == msg.sender, "sender != borrower");

        loans[loanId].status = Status.Canceled;

        emit LoanCanceled(loanId, msg.sender);
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

        IERC20(_loan.collateral).safeTransferFrom(_loan.borrower, address(this), _loan.collateralAmount);
        IERC20(_loan.asset).safeTransferFrom(msg.sender, _loan.borrower, _loan.assetAmount);

        emit LoanFilled(loanId, _loan.borrower, msg.sender);
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

        //since token could be ERC777 and lender could be a contract, there is a possible DoS attack vector during repayment/liquidtion
        //this is acceptable, since borrowers are expected to be aware of the risk when using non-standard tokens + lender would also lose their assets
        IERC20(_loan.asset).safeTransferFrom(_loan.borrower, _loan.lender, amountToLender); //return asset
        IERC20(_loan.collateral).safeTransfer(_loan.borrower, _loan.collateralAmount); //return collateral

        IERC20(_loan.asset).safeTransferFrom(_loan.borrower, feeCollector, protocolFee);

        emit LoanRepaid(loanId, _loan.borrower, _loan.lender);
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
        
        IERC20(_loan.collateral).safeTransfer(_loan.lender, lenderAmount);
        IERC20(_loan.collateral).safeTransfer(msg.sender, liquidatorBonus);
        IERC20(_loan.collateral).safeTransfer(feeCollector, protocolFee);

        emit LoanLiquidated(loanId);
        emit ProtocolRevenue(loanId, _loan.collateral, protocolFee);
    }

    function _isLoanLiquidatable(uint256 loanId) public view returns (bool) {
        Loan memory _loan = loans[loanId];

        if (_loan.liquidation.isLiquidatable){
            uint256 assetPrice = uint256(AggregatorInterface(_loan.liquidation.assetOracle).latestAnswer());
            uint256 collateralPrice = uint256(AggregatorInterface(_loan.liquidation.collateralOracle).latestAnswer());

            require(assetPrice > 0, "invalid oracle asset price");
            require(collateralPrice > 0, "invalid oracle collateral price");

            uint8 assetDecimals = IERC20Metadata(_loan.asset).decimals();
            uint8 collateralDecimals = IERC20Metadata(_loan.collateral).decimals();

            uint256 loanValueUsd = _loan.assetAmount * assetPrice / (10 ** assetDecimals);
            uint256 collateralValueUsd = _loan.collateralAmount * collateralPrice / (10 ** collateralDecimals);

            return (loanValueUsd > (collateralValueUsd * _loan.liquidation.liquidationThreshold / 10000));
        } 

        return false;
    }

    /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/
    /*                     Admin Functions                      */
    /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/

    /// @notice used to change fee collector
    /// @param _newFeeCollector address that will receive the fees
    /// @dev since some tokens don't allow transfers to addres(0), it can't be set to it
    function setFeeCollector(address _newFeeCollector) external onlyOwner() {
        require(_newFeeCollector != address(0), "feeCollector == address(0)");
        emit FeeCollectorUpdated(feeCollector, _newFeeCollector);
        feeCollector = _newFeeCollector;
    }

    /// @notice used to change loan request expiration
    /// @param _newExpirationDuration loan expiration in seconds
    function setRequestExpirationDuration(uint256 _newExpirationDuration) external onlyOwner() {
        require(_newExpirationDuration > 1 days, "_newExpirationDuration < 1 day");
        emit ExpirationDurationUpdated(REQUEST_EXPIRATION_DURATION, _newExpirationDuration);
        REQUEST_EXPIRATION_DURATION = _newExpirationDuration;
    }

    /// @notice used to change the protocol fee percentage
    /// @param _newProtocolFee new fee in basis points
    function setProtocolFee(uint256 _newProtocolFee) external onlyOwner() {
        require(_newProtocolFee < 2000, "protocolFee > 2000 bps");
        emit ProtocolFeeUpdated(PROTOCOL_FEE, _newProtocolFee);
        PROTOCOL_FEE = _newProtocolFee;
    }

    /// @notice used to chnage protocol liquidation config
    /// @param _newLiquidatorBonus new bonus paid to the liquidator, in basis points
    /// @param _newProtocolLiquidationFee new fee paid to the protocol, in basis points
    function setLiquidationConfig(uint256 _newLiquidatorBonus, uint256 _newProtocolLiquidationFee) external onlyOwner() {
        require(_newLiquidatorBonus < 1000, "_newLiquidatorBonus > 1000 bps");
        require(_newProtocolLiquidationFee < 500, "_newProtocolLiquidationFee > 500 bps");

        emit LiquidatorBonusUpdated(LIQUIDATOR_BONUS_BPS, _newLiquidatorBonus);
        emit ProtocolLiquidationFeeUpdated(PROTOCOL_LIQUIDATION_FEE, _newProtocolLiquidationFee);

        LIQUIDATOR_BONUS_BPS = _newLiquidatorBonus;
        PROTOCOL_LIQUIDATION_FEE = _newProtocolLiquidationFee;
    }
}
