const { loadFixture } = require("@nomicfoundation/hardhat-toolbox/network-helpers");
const { expect } = require("chai");

describe("AdminFunctions", function () {
    async function depoyContracts() {
        const [owner, otherAccount] = await ethers.getSigners();

        const LendingP2P = await ethers.getContractFactory("LendingP2P");
        const p2p = await LendingP2P.deploy();

        return { p2p, owner, otherAccount };
    }

    //fee collector

    it("should update fee colector", async function () {
        const { p2p, owner, otherAccount } = await loadFixture(depoyContracts);

        expect(await p2p.feeCollector()).to.equal(owner);

        await expect(p2p.setFeeCollector(otherAccount))
            .to.emit(p2p, "FeeCollectorUpdated")
            .withArgs(owner.address, otherAccount.address)

        expect(await p2p.feeCollector()).to.equal(otherAccount.address);
    });

    it("should revert: fee colector to 0x0", async function () {
        const { p2p, owner, otherAccount } = await loadFixture(depoyContracts);
        await expect(p2p.setFeeCollector("0x0000000000000000000000000000000000000000")).to.revertedWith("feeCollector == address(0)")
    });

    it("should revert: fee collector update - caller not owner", async function () {
        const { p2p, owner, otherAccount } = await loadFixture(depoyContracts);
        await expect(p2p.connect(otherAccount).setFeeCollector(otherAccount.address)).to.revertedWithCustomError(p2p, "OwnableUnauthorizedAccount")
    });

    //expiration duration

    it("should update request expiration duration", async function () {
        const { p2p, owner, otherAccount } = await loadFixture(depoyContracts);

        expect(await p2p.REQUEST_EXPIRATION_DURATION()).to.equal(60 * 60 * 24 * 7);
        await expect(p2p.setRequestExpirationDuration(60 * 60 * 24 * 2))
            .to.emit(p2p, "ExpirationDurationUpdated")
            .withArgs(60 * 60 * 24 * 7, 60 * 60 * 24 * 2)

        expect(await p2p.REQUEST_EXPIRATION_DURATION()).to.equal(60 * 60 * 24 * 2);
    });

    it("should revert: request expiration duration under 1 day", async function () {
        const { p2p, owner, otherAccount } = await loadFixture(depoyContracts);
        expect(await p2p.REQUEST_EXPIRATION_DURATION()).to.equal(60 * 60 * 24 * 7);
        await expect(p2p.setRequestExpirationDuration(60 * 60 * 0.9)).to.revertedWith("newExpirationDuration < 1 day")
    });

    it("should revert: request expiration duration - caller not owner", async function () {
        const { p2p, owner, otherAccount } = await loadFixture(depoyContracts);
        await expect(p2p.connect(otherAccount).setRequestExpirationDuration(60 * 60 * 24 * 2)).to.revertedWithCustomError(p2p, "OwnableUnauthorizedAccount")
    });

    //protocol fee

    it("should update protocol fee", async function () {
        const { p2p, owner, otherAccount } = await loadFixture(depoyContracts);

        expect(await p2p.PROTOCOL_FEE()).to.equal(2000);
        await expect(p2p.setProtocolFee(100))
            .to.emit(p2p, "ProtocolFeeUpdated")
            .withArgs(2000, 100)

        expect(await p2p.PROTOCOL_FEE()).to.equal(100);
    });

    it("should revert: protocol fee > 2000 bps", async function () {
        const { p2p, owner, otherAccount } = await loadFixture(depoyContracts);
        await expect(p2p.setProtocolFee(2001)).to.revertedWith("protocolFee > 2000 bps")
    });

    it("should revert: set protocol fee - caller not owner", async function () {
        const { p2p, owner, otherAccount } = await loadFixture(depoyContracts);
        await expect(p2p.connect(otherAccount).setProtocolFee(1000)).to.revertedWithCustomError(p2p, "OwnableUnauthorizedAccount")
    });

    //liquidation config
    it("should update liquidation config", async function () {
        const { p2p, owner, otherAccount } = await loadFixture(depoyContracts);

        expect(await p2p.LIQUIDATOR_BONUS_BPS()).to.equal(100);
        expect(await p2p.PROTOCOL_LIQUIDATION_FEE()).to.equal(20);

        await expect(p2p.setLiquidationConfig(50, 10))
            .to.emit(p2p, "LiquidatorBonusUpdated")
            .withArgs(100, 50)
            .to.emit(p2p, "ProtocolLiquidationFeeUpdated")
            .withArgs(20, 10)

        expect(await p2p.LIQUIDATOR_BONUS_BPS()).to.equal(50);
        expect(await p2p.PROTOCOL_LIQUIDATION_FEE()).to.equal(10);
    });

    it("should update max allowed oracle price age", async function () {
        const { p2p, owner, otherAccount } = await loadFixture(depoyContracts);

        expect(await p2p.MAX_ORACLE_PRICE_AGE()).to.equal(60 * 60);

        await expect(p2p.setMaximumOraclePriceAge(60 * 60 * 2))
            .to.emit(p2p, "MaxOraclePriceAgeUpdated")
            .withArgs(60 * 60, 60 * 60 * 2)

        expect(await p2p.MAX_ORACLE_PRICE_AGE()).to.equal(60 * 60 * 2);
    });

    it("should revert: liquidator bonus > 1000 bps", async function () {
        const { p2p, owner, otherAccount } = await loadFixture(depoyContracts);
        await expect(p2p.setLiquidationConfig(1001, 10)).to.revertedWith("liquidatorBonus > 1000 bps")
    });

    it("should revert: protocol liquidation fee > 500 bps", async function () {
        const { p2p, owner, otherAccount } = await loadFixture(depoyContracts);
        await expect(p2p.setLiquidationConfig(100, 501)).to.revertedWith("protocolLiquidationFee > 500 bps")
    });

    it("should revert: set liquidation config - caller not owner", async function () {
        const { p2p, owner, otherAccount } = await loadFixture(depoyContracts);
        await expect(p2p.connect(otherAccount).setLiquidationConfig(100, 100)).to.revertedWithCustomError(p2p, "OwnableUnauthorizedAccount")
    });
});
