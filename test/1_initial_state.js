const { loadFixture } = require("@nomicfoundation/hardhat-toolbox/network-helpers");
const { expect } = require("chai");

describe("Basics", function () {
    async function depoyContracts() {
        const [owner, otherAccount] = await ethers.getSigners();

        const LendingP2P = await ethers.getContractFactory("LendingP2P");
        const p2p = await LendingP2P.deploy();

        return { p2p, owner, otherAccount };
    }

    it("should set the owner", async function () {
        const { p2p, owner } = await loadFixture(depoyContracts);

        expect(await p2p.owner()).to.equal(owner);
        expect(await p2p.loanLength()).to.equal(0);
    });

    it("should set the fee collector", async function () {
        const { p2p, owner } = await loadFixture(depoyContracts);

        expect(await p2p.feeCollector()).to.equal(owner);
        expect(await p2p.loanLength()).to.equal(0);
    });

    it("should set the default protocol config", async function () {
        const { p2p } = await loadFixture(depoyContracts);

        const sevenDays = 60 * 60 * 24 * 7
        const protocolFee = "2000"
        const liquidatorBonus = "100"
        const protocolLiquidationFee = "20"

        expect(await p2p.REQUEST_EXPIRATION_DURATION()).to.equal(sevenDays);
        expect(await p2p.PROTOCOL_FEE()).to.equal(protocolFee);
        expect(await p2p.LIQUIDATOR_BONUS_BPS()).to.equal(liquidatorBonus);
        expect(await p2p.PROTOCOL_LIQUIDATION_FEE()).to.equal(protocolLiquidationFee);
        expect(await p2p.loanLength()).to.equal(0);
    });
});
