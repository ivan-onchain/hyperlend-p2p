# HyperLend P2P lending

Isolated loans between 2 users.

Features:

```
    - users can request a loan  
        - select asset, collateral, asset amount, repayment amount, collateral amount, loan duration, can the loan be liquidated when it becomes insolvent
        - if loan is liquidatable (before expiration), user also choses chainlink price oracles and liquidation threshold
    - users can fill loan requests
    - users can cancel unfilled requests
    - users can repay loans
    - unfilled requests expire after X time
    - unpaid loans can be liqudated
    - protocol fee is charged on interest only (repayment amount - borrowed amount)
```

---

Tests:

`npx hardhat test`