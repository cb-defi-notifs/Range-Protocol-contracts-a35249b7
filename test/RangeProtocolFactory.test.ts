import { ethers } from "hardhat";
import { expect } from "chai";
import { anyValue } from "@nomicfoundation/hardhat-chai-matchers/withArgs";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/dist/src/signer-with-address";
import {
  IERC20,
  IiZiSwapFactory,
  IiZiSwapPool,
  RangeProtocolVault,
  RangeProtocolFactory,
  VaultLib,
} from "../typechain";
import { bn, getInitializeData, ZERO_ADDRESS } from "./common";

let factory: RangeProtocolFactory;
let vaultImpl: RangeProtocolVault;
let iZiSwapFactory: IiZiSwapFactory;
let iZiSwapPool: IiZiSwapPool;
let vaultLib: VaultLib;
let token0: IERC20;
let token1: IERC20;
let owner: SignerWithAddress;
let nonOwner: SignerWithAddress;
let newOwner: SignerWithAddress;
const poolFee = 10000;
const name = "Test Token";
const symbol = "TT";
let initializeData: any;

describe("RangeProtocolFactory", () => {
  before(async function () {
    [owner, nonOwner, newOwner] = await ethers.getSigners();
    iZiSwapFactory = await ethers.getContractAt(
      "IiZiSwapFactory",
      "0x45e5F26451CDB01B0fA1f8582E0aAD9A6F27C218"
    );

    const RangeProtocolFactory = await ethers.getContractFactory(
      "RangeProtocolFactory"
    );
    factory = (await RangeProtocolFactory.deploy(
      iZiSwapFactory.address
    )) as RangeProtocolFactory;

    // eslint-disable-next-line @typescript-eslint/naming-convention
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    token0 = (await MockERC20.deploy()) as IERC20;
    token1 = (await MockERC20.deploy()) as IERC20;

    if (bn(token0.address).gt(token1.address)) {
      const tmp = token0;
      token0 = token1;
      token1 = tmp;
    }

    await iZiSwapFactory.newPool(token0.address, token1.address, poolFee, 1);
    iZiSwapPool = (await ethers.getContractAt(
      "IiZiSwapPool",
      await iZiSwapFactory.pool(token0.address, token1.address, poolFee)
    )) as IiZiSwapPool;

    const VaultLib = await ethers.getContractFactory("VaultLib");
    vaultLib = await VaultLib.deploy();
    const RangeProtocolVault = await ethers.getContractFactory(
      "RangeProtocolVault",
      {
        libraries: {
          VaultLib: vaultLib.address,
        },
      }
    );
    vaultImpl = (await RangeProtocolVault.deploy()) as RangeProtocolVault;

    initializeData = getInitializeData({
      managerAddress: owner.address,
      name,
      symbol,
    });
  });

  it("should deploy RangeProtocolFactory", async function () {
    expect(await factory.factory()).to.be.equal(iZiSwapFactory.address);
    expect(await factory.owner()).to.be.equal(owner.address);
  });

  it("should not deploy a vault with one of the tokens being zero", async function () {
    await expect(
      factory.createVault(
        ZERO_ADDRESS,
        token1.address,
        poolFee,
        vaultImpl.address,
        initializeData
      )
    ).to.be.revertedWith("ZeroPoolAddress()");
  });

  it("should not deploy a vault with both tokens being the same", async function () {
    await expect(
      factory.createVault(
        token0.address,
        token0.address,
        poolFee,
        vaultImpl.address,
        initializeData
      )
    ).to.be.revertedWith("ZeroPoolAddress()");
  });

  it("should not deploy vault with zero manager address", async function () {
    await expect(
      factory.createVault(
        token0.address,
        token1.address,
        poolFee,
        vaultImpl.address,
        getInitializeData({
          managerAddress: ZERO_ADDRESS,
          name,
          symbol,
        })
      )
    ).to.be.revertedWith("ZeroManagerAddress()");
  });

  it("non-owner should not be able to deploy vault", async function () {
    await expect(
      factory
        .connect(nonOwner)
        .createVault(
          token0.address,
          token1.address,
          poolFee,
          vaultImpl.address,
          initializeData
        )
    ).to.be.revertedWith("Ownable: caller is not the owner");
  });

  it("owner should be able to deploy vault", async function () {
    await expect(
      factory.createVault(
        token0.address,
        token1.address,
        poolFee,
        vaultImpl.address,
        initializeData
      )
    )
      .to.emit(factory, "VaultCreated")
      .withArgs((iZiSwapPool as Contract).address, anyValue);

    expect(await factory.vaultCount()).to.be.equal(1);
    expect((await factory.getVaultAddresses(0, 0))[0]).to.not.be.equal(
      ethers.constants.AddressZero
    );
  });

  it("should allow deploying vault with duplicate pairs", async function () {
    await expect(
      factory.createVault(
        token0.address,
        token1.address,
        poolFee,
        vaultImpl.address,
        initializeData
      )
    )
      .to.emit(factory, "VaultCreated")
      .withArgs((iZiSwapPool as Contract).address, anyValue);

    expect(await factory.vaultCount()).to.be.equal(2);
    const vault0Address = (await factory.getVaultAddresses(0, 0))[0];
    const vault1Address = (await factory.getVaultAddresses(1, 1))[0];

    expect(vault0Address).to.not.be.equal(ethers.constants.AddressZero);
    expect(vault1Address).to.not.be.equal(ethers.constants.AddressZero);

    const dataABI = new ethers.utils.Interface([
      "function token0() returns (address)",
      "function token1() returns (address)",
    ]);

    expect(vault0Address).to.be.not.equal(vault1Address);
    expect(
      await ethers.provider.call({
        to: vault0Address,
        data: dataABI.encodeFunctionData("token0"),
      })
    ).to.be.equal(
      await ethers.provider.call({
        to: vault1Address,
        data: dataABI.encodeFunctionData("token0"),
      })
    );

    expect(
      await ethers.provider.call({
        to: vault0Address,
        data: dataABI.encodeFunctionData("token1"),
      })
    ).to.be.equal(
      await ethers.provider.call({
        to: vault1Address,
        data: dataABI.encodeFunctionData("token1"),
      })
    );
  });

  describe("transferOwnership", () => {
    it("should not be able to transferOwnership by non owner", async () => {
      await expect(
        factory.connect(nonOwner).transferOwnership(newOwner.address)
      ).to.be.revertedWith("Ownable: caller is not the owner");
    });

    it("should be able to transferOwnership by owner", async () => {
      await expect(factory.transferOwnership(newOwner.address))
        .to.emit(factory, "OwnershipTransferred")
        .withArgs(owner.address, newOwner.address);
      expect(await factory.owner()).to.be.equal(newOwner.address);

      await factory.connect(newOwner).transferOwnership(owner.address);
      expect(await factory.owner()).to.be.equal(owner.address);
    });
  });
});
