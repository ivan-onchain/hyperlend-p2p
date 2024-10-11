const {
  time,
  loadFixture,
} = require("@nomicfoundation/hardhat-toolbox/network-helpers");
const { anyValue } = require("@nomicfoundation/hardhat-chai-matchers/withArgs");
const { expect } = require("chai");

describe("Basics", function () {
    async function depoyContracts() {
        const [owner, otherAccount] = await ethers.getSigners();

        const LendingP2P = await ethers.getContractFactory("LendingP2P");
        const p2p = await LendingP2P.deploy();

        return { p2p, owner, otherAccount };
    }

    it("should set the right owner", async function () {
        const { p2p, owner } = await loadFixture(depoyContracts);

        expect(await p2p.owner()).to.equal(owner);
        expect(await p2p.loanLength()).to.equal(0);
    });
});
