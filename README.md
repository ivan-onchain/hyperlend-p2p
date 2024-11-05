# HyperLend P2P lending

Isolated loans between 2 users.

#### Features:

- users can request a loan:
    - select:
        - asset (to be borrowed) token 
        - collateral token 
        - amount of the asset to be borrowed, 
        - amount of the assetto be repaid
        - the amount of collateral 
        - loan duration, 
        - can the loan be liquidated when it becomes insolvent:
            - asset oracle 
            - collateral oracle
            - liquidation threshold
- users can fill a loan requests
- users can cancel unfilled requests
- users can repay loans
- unfilled requests expire after `REQUEST_EXPIRATION_DURATION` time
- loans can be liquidated:
    - if the duration was exceeded and the loan wasn't repaid in time
    - if the loan is liquidatable, and value of the asset is higher than the value of the collateral * liquidation threshold
- protocol fee is charged on interest-only (repayment amount - borrowed amount)
- liquidators & protocol receive a portion of the collateral (set to 1% for the liquidator and 0.2% for protocol) during liquidations

---

Tests:

`npx hardhat test`