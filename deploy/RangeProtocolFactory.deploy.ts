import { ethers } from "hardhat";
import { LedgerSigner } from "@anders-t/ethers-ledger";

async function main() {
  const provider = ethers.getDefaultProvider("");
  const ledger = await new LedgerSigner(provider, "");
  const IZUMI_FACTORY = "0x45e5F26451CDB01B0fA1f8582E0aAD9A6F27C218";
  let RangeProtocolFactory = await ethers.getContractFactory(
    "RangeProtocolFactory"
  );
  RangeProtocolFactory = await RangeProtocolFactory.connect(ledger);
  const factory = await RangeProtocolFactory.deploy(IZUMI_FACTORY);
  console.log("Factory: ", factory.address);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
