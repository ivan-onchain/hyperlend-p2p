# Test Cases for LendingP2P Contract

## Initial State
1. Contract deploys successfully with correct initial values
   - [x] Owner set correctly
   - [x] FeeCollector set to owner
   - [x] Default protocol parameters set correctly
   - [x] Initial loanLength is 0

## Loan Request Tests
1. Successful loan request
   - [x] Correct loan data stored
   - [x] LoanRequested event emitted with correct parameters
   - [x] LoanLength incremented
   - [x] Status set to Pending

2. Failed loan requests
   - [x] Revert when borrower !== msg.sender
   - [x] Revert when repaymentAmount <= assetAmount
   - [x] Revert when asset === collateral
   - [x] Revert when liquidationThreshold > 10000
   - [x] Revert on invalid loan struct encoding
   - [x] Revert on invalid token decimals
   - [x] Revert on invalid token address (not contract)

## Loan Fill Tests
1. Successful loan fill
   - [x] Status changes to Active
   - [x] Correct lender address recorded
   - [x] Start timestamp set correctly
   - [x] Collateral transferred from borrower to contract
   - [x] Asset transferred from lender to borrower
   - [x] LoanFilled event emitted

2. Failed fill attempts
   - [x] Revert when loan is not Pending
   - [x] Revert when loan has expired
   - [x] Revert when loan would be instantly liquidatable
   - [x] Revert when insufficient collateral approval
   - [x] Revert when insufficient asset approval
   - [x] Revert when insufficient asset balance for lender
   - [x] Revert when insufficient collateral balance for borrower

## Loan Repayment Tests
1. Successful repayment
   - [x] Status changes to Repaid
   - [x] Correct protocol fee calculation
   - [x] Asset transferred to lender (minus fee)
   - [x] Protocol fee transferred to feeCollector
   - [x] Collateral returned to borrower
   - [x] LoanRepaid and ProtocolRevenue events emitted

2. Failed repayments
   - [x] Revert when loan is not Active
   - [x] Revert when insufficient repayment approval
   - [x] Revert when insufficient balance for borrower

## Liquidation Tests
1. Successful price-based liquidation
   - [x] Verify oracle price calculations
   - [x] Check liquidation threshold logic
   - [x] Proper distribution of collateral
   - [x] Status changes to Liquidated
   - [x] Events emitted correctly

2. Successful time-based liquidation
   - [x] Verify expiration calculation
   - [x] Proper distribution of collateral
   - [x] Status changes to Liquidated
   - [x] Events emitted correctly

3. Failed liquidation attempts
   - [x] Revert when loan is not Active
   - [x] Revert when loan is not liquidatable (price)
   - [x] Revert when loan is not expired (time)
   - [x] Revert when oracle returns invalid prices

## Loan Cancellation Tests
1. Successful loan cancellation
   - [x] Status changes to Canceled
   - [x] LoanCanceled event emitted
   - [x] Only borrower can cancel
   - [x] Only works before expiration

2. Failed cancellations
   - [x] Revert when caller is not borrower
   - [x] Revert when loan has expired
   - [x] Revert when loan is already cancelled

## Oracle Integration Tests
1. Price calculations
   - [x] Correct handling of different token decimals
   - [x] Proper price normalization
   - [x] Handling of zero prices
   - [x] Handling of price updates

2. Failed oracle scenarios
   - [x] Revert on oracle reversion
   - [x] Revert on zero prices
   - [x] Revert on different asset and oracle decimals

## Admin Function Tests
1. setFeeCollector
   - [x] Only owner can call
   - [x] Revert on zero address
   - [x] Event emitted

2. setRequestExpirationDuration
   - [x] Only owner can call
   - [x] Revert if < 1 day
   - [x] Event emitted

3. setProtocolFee
   - [x] Only owner can call
   - [x] Revert if > 2000 bps
   - [x] Event emitted

4. setLiquidationConfig
   - [x] Only owner can call
   - [x] Revert if liquidator bonus > 1000 bps
   - [x] Revert if protocol fee > 500 bps
   - [x] Events emitted

## Integration Tests
1. Full loan lifecycle
   - [x] Request → Fill → Repay
   - [x] Request → Fill → Liquidate (price)
   - [x] Request → Fill → Liquidate (time)
   - [x] Request → Cancel
