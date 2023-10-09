import { ethers } from "hardhat";
import { LedgerSigner } from "@anders-t/ethers-ledger";

async function main() {
    const provider = ethers.getDefaultProvider("");
    const ledger = await new LedgerSigner(provider, "");
    let VaultLib = await ethers.getContractFactory("VaultLib");
    VaultLib = await VaultLib.connect(ledger);
    const vaultLib = await VaultLib.deploy();
    console.log("Factory: ", vaultLib.address);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
