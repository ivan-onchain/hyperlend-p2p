// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

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
        address collateralOracle;     // chainlink oracle for the collateral asset, must be in the same quote currency as assetOracle
    }

    /// @notice details about the individual loan
    struct Loan {
        address borrower;         // address of the borrower
        address lender;           // address of the lender
        address asset;            // address of the asset being borrowed
        address collateral;       // address of the asset used as a collateral

        uint256 assetAmount;      // amount of the asset being paid to the borrower by the lender
        uint256 repaymentAmount;  // amount of the asset being repaid by the lender
        uint256 collateralAmount; // amount of the collateral being pledged by the borrower

        uint64 createdTimestamp;  // timestamp when the loan request was created
        uint64 startTimestamp;    // timestamp when the loan was accepted
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
    /// @notice emitted when max allowed oracle price age changes
    event MaxOraclePriceAgeUpdated(uint256 oldMaxOraclePriceAge, uint256 newMaxOraclePriceAge);

    /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/
    /*                     Protocol config                      */
    /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/

    /// @notice maximum acceptable age of the oracle price in seconds, afterwards liquidations will revert
    uint256 public MAX_ORACLE_PRICE_AGE = 1 hours;
    /// @notice precision factor, used when calculating asset values, to avoid precision loss
    uint256 public PRECISION_FACTOR = 1e8;
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
    uint256 public loanLength;
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

        //since users can use any address (even non-standard contracts), verify that the decimals function exists
        require(IERC20Metadata(loan.asset).decimals() >= 0, "invalid decimals");
        require(IERC20Metadata(loan.collateral).decimals() >= 0, "invalid decimals");

        if (loan.liquidation.isLiquidatable){
            uint8 assetOracleDecimals = AggregatorInterface(loan.liquidation.assetOracle).decimals();
            uint8 collateralOracleDecimals = AggregatorInterface(loan.liquidation.collateralOracle).decimals();
            require(assetOracleDecimals == collateralOracleDecimals, "oracle decimals mismatch");
        }

        loan.createdTimestamp = uint64(block.timestamp);
        loan.startTimestamp = 0;
        loan.status = Status.Pending;

        loans[loanLength] = loan;
        loanLength += 1;

        emit LoanRequested(loanLength - 1, msg.sender);
    }

    /// @notice function used to cancel an unfilled loan
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

        loans[loanId].lender = msg.sender;
        loans[loanId].startTimestamp = uint64(block.timestamp);
        loans[loanId].status = Status.Active;

        if (_loan.liquidation.isLiquidatable){
            require(!_isLoanLiquidatable(loanId), "instantly liquidatable"); //make sure it can't be instantly liquidated
        }

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

        //since the token could be ERC777 and the lender could be a contract, there is a possible DoS attack vector during repayment/liquidation
        //this is acceptable, since borrowers are expected to be aware of the risk when using non-standard tokens
        IERC20(_loan.asset).safeTransferFrom(_loan.borrower, _loan.lender, amountToLender); //return asset
        IERC20(_loan.collateral).safeTransfer(_loan.borrower, _loan.collateralAmount); //return collateral

        IERC20(_loan.asset).safeTransferFrom(_loan.borrower, feeCollector, protocolFee);

        emit LoanRepaid(loanId, _loan.borrower, _loan.lender);
        emit ProtocolRevenue(loanId, _loan.asset, protocolFee);
    }   

    /// @notice function used to liquidate a loan
    /// @dev loan can be liquidated either if it's overdue, or if it's insolvent (only for liquidatable loans)
    /// @dev doesn't revert if the loan is not liquidatable, only if the price from the oracle is invalid
    function liquidateLoan(uint256 loanId) external nonReentrant returns (bool) {
        if (_isLoanLiquidatable(loanId)){
            _liquidate(loanId);
            return true;
        }

        return false;
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

        //loan is not active
        if (_loan.status != Status.Active){
            return false;
        }

        //defaulted loan
        if (block.timestamp > _loan.startTimestamp + _loan.duration){
            return true;
        }

        if (_loan.liquidation.isLiquidatable){
            //users are expected to verify that assetOracle and collateralOracle are not malicious contracts before filling loan request
            (, int256 assetPrice, , uint256 assetPriceUpdatedAt,) = AggregatorInterface(_loan.liquidation.assetOracle).latestRoundData();
            (, int256 collateralPrice, , uint256 collateralPriceUpdatedAt,) = AggregatorInterface(_loan.liquidation.collateralOracle).latestRoundData();

            require(assetPrice > 0, "invalid oracle price");
            require(collateralPrice > 0, "invalid oracle price");

            require(MAX_ORACLE_PRICE_AGE > block.timestamp - assetPriceUpdatedAt, "stale asset oracle");
            require(MAX_ORACLE_PRICE_AGE > block.timestamp - collateralPriceUpdatedAt, "stale collateral oracle");

            //users are expected to use only standard ERC20Metadata tokens that include decimals()
            uint8 assetDecimals = IERC20Metadata(_loan.asset).decimals();
            uint8 collateralDecimals = IERC20Metadata(_loan.collateral).decimals();

            //uint256.max is 1.15e77 and chainlink price is expected to be under 1e12, 
            //so overflow would only happen if amount > 1e53, with 0 decimals
            //this is an acceptable risk, and users are expected to not use amounts that high
            uint256 loanValueUsd = PRECISION_FACTOR * _loan.assetAmount * uint256(assetPrice) / (10 ** assetDecimals);
            uint256 collateralValueUsd = PRECISION_FACTOR * _loan.collateralAmount * uint256(collateralPrice) / (10 ** collateralDecimals);

            return (loanValueUsd > (collateralValueUsd * _loan.liquidation.liquidationThreshold / 10000));
        } 

        return false;
    }

    /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/
    /*                     Admin Functions                      */
    /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/

    /// @notice used to change fee collector
    /// @param _newFeeCollector address that will receive the fees
    /// @dev since some tokens don't allow transfers to address(0), it can't be set to it
    function setFeeCollector(address _newFeeCollector) external onlyOwner() {
        require(_newFeeCollector != address(0), "feeCollector == address(0)");
        emit FeeCollectorUpdated(feeCollector, _newFeeCollector);
        feeCollector = _newFeeCollector;
    }

    /// @notice used to change loan request expiration
    /// @param _newExpirationDuration loan expiration in seconds
    function setRequestExpirationDuration(uint256 _newExpirationDuration) external onlyOwner() {
        require(_newExpirationDuration > 1 days, "newExpirationDuration < 1 day");
        emit ExpirationDurationUpdated(REQUEST_EXPIRATION_DURATION, _newExpirationDuration);
        REQUEST_EXPIRATION_DURATION = _newExpirationDuration;
    }

    /// @notice used to change the maximum allowed oracle price age
    /// @param _newMaxPriceAge maximum allowed oracle price age in seconds
    function setMaximumOraclePriceAge(uint256 _newMaxPriceAge) external onlyOwner() {
        emit MaxOraclePriceAgeUpdated(MAX_ORACLE_PRICE_AGE, _newMaxPriceAge);
        MAX_ORACLE_PRICE_AGE = _newMaxPriceAge;
    }

    /// @notice used to change the protocol fee percentage
    /// @param _newProtocolFee new fee in basis points
    function setProtocolFee(uint256 _newProtocolFee) external onlyOwner() {
        require(_newProtocolFee < 2000, "protocolFee > 2000 bps");
        emit ProtocolFeeUpdated(PROTOCOL_FEE, _newProtocolFee);
        PROTOCOL_FEE = _newProtocolFee;
    }

    /// @notice used to change protocol liquidation config
    /// @param _newLiquidatorBonus new bonus paid to the liquidator, in basis points
    /// @param _newProtocolLiquidationFee new fee paid to the protocol, in basis points
    function setLiquidationConfig(uint256 _newLiquidatorBonus, uint256 _newProtocolLiquidationFee) external onlyOwner() {
        require(_newLiquidatorBonus < 1000, "liquidatorBonus > 1000 bps");
        require(_newProtocolLiquidationFee < 500, "protocolLiquidationFee > 500 bps");

        emit LiquidatorBonusUpdated(LIQUIDATOR_BONUS_BPS, _newLiquidatorBonus);
        emit ProtocolLiquidationFeeUpdated(PROTOCOL_LIQUIDATION_FEE, _newProtocolLiquidationFee);

        LIQUIDATOR_BONUS_BPS = _newLiquidatorBonus;
        PROTOCOL_LIQUIDATION_FEE = _newProtocolLiquidationFee;
    }
}
