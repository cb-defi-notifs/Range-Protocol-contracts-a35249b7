import { ethers } from "hardhat";
import { LedgerSigner } from "@anders-t/ethers-ledger";
import { getInitializeData } from "../test/common";

async function main() {
  const provider = ethers.getDefaultProvider(""); // To be updated.
  const ledger = await new LedgerSigner(provider, ""); // To be updated.
  const managerAddress = "0x84b43ce5fB1FAF013181FEA96ffA4af6179e396a"; // To be updated.
  const rangeProtocolFactoryAddress = ""; // To be updated.
  const vaultImplAddress = ""; // to be updated.
  const token0 = "0x09bc4e0d864854c6afb6eb9a9cdf58ac190d0df9";
  const token1 = "0xdeaddeaddeaddeaddeaddeaddeaddeaddead1111";
  const fee = 500;
  const name = "Range Agni USDC/USDT 0.05% Passive LP"; // To be updated.
  const symbol = "R-UNI"; // To be updated.

  let factory = await ethers.getContractAt(
    "RangeProtocolFactory",
    rangeProtocolFactoryAddress
  );
  factory = await factory.connect(ledger);
  const data = getInitializeData({
    managerAddress,
    name,
    symbol,
  });

  const tx = await factory.createVault(
    token0,
    token1,
    fee,
    vaultImplAddress,
    data
  );
  const txReceipt = await tx.wait();
  const [
    {
      args: { vault },
    },
  ] = txReceipt.events.filter(
    (event: { event: any }) => event.event === "VaultCreated"
  );
  console.log("Vault: ", vault);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
