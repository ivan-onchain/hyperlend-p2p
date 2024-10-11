function encodeLoan(loan){
    const abiEncoder = new ethers.AbiCoder()
    return abiEncoder.encode(
        [
            "address", "address", "address", "address", 
            "uint256", "uint256", "uint256", 
            "uint256", "uint256", "uint256",
            "tuple(bool, uint256, address, address)",
            "uint8"
        ],
        [
            loan.borrower, loan.lender, loan.asset, loan.collateral,
            loan.assetAmount, loan.repaymentAmount, loan.collateralAmount,
            0, 0, loan.duration,
            [loan.liq.isLiquidatable, loan.liq.liquidationThreshold, loan.liq.assetOracle, loan.liq.collateralOracle],
            loan.status
        ]
    );
}

module.exports = {
    encodeLoan: encodeLoan
}