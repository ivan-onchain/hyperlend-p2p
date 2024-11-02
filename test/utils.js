function encodeLoan(loan){
    const abiEncoder = new ethers.AbiCoder()
    return abiEncoder.encode(
        [
            "address", "address", "address", "address", 
            "uint256", "uint256", "uint256", 
            "uint256", "uint256", "uint256",
            "uint8",
            "tuple(bool, uint256, address, address)"
        ],
        [
            loan.borrower, loan.lender, loan.asset, loan.collateral,
            loan.assetAmount, loan.repaymentAmount, loan.collateralAmount,
            0, 0, loan.duration,
            loan.status,
            [loan.liquidation.isLiquidatable, loan.liquidation.liquidationThreshold, loan.liquidation.assetOracle, loan.liquidation.collateralOracle]
        ]
    );
}

module.exports = {
    encodeLoan: encodeLoan
}