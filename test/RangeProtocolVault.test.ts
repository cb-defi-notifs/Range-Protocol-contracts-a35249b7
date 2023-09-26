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
import { bn, getInitializeData, parseEther, position } from "./common";
import { beforeEach } from "mocha";
import { BigNumber } from "ethers";

let factory: RangeProtocolFactory;
let vaultImpl: RangeProtocolVault;
let vault: RangeProtocolVault;
let vaultLib: VaultLib;
let iZiSwapFactory: IiZiSwapFactory;
let iZiSwapPool: IiZiSwapPool;
let token0: IERC20;
let token1: IERC20;
let manager: SignerWithAddress;
let nonManager: SignerWithAddress;
let newManager: SignerWithAddress;
let user2: SignerWithAddress;
const poolFee = 10000;
const name = "Test Token";
const symbol = "TT";
const amountX: BigNumber = parseEther("2");
const amountY: BigNumber = parseEther("3");
let initializeData: any;
const lowerTick = -10000;
const upperTick = 20000;

describe("RangeProtocolVault", () => {
  before(async () => {
    [manager, nonManager, user2, newManager] = await ethers.getSigners();
    iZiSwapFactory = await ethers.getContractAt(
      "IiZiSwapFactory",
      "0x93BB94a0d5269cb437A1F71FF3a77AB753844422"
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

    // await iZiSwapPool.initialize(encodePriceSqrt("1", "1"));
    // await iZiSwapPool.increaseObservationCardinalityNext("15");

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
      managerAddress: manager.address,
      name,
      symbol,
    });

    await factory.createVault(
      token0.address,
      token1.address,
      poolFee,
      vaultImpl.address,
      initializeData
    );

    const vaultAddress = await factory.getVaultAddresses(0, 0);
    vault = (await ethers.getContractAt(
      "RangeProtocolVault",
      vaultAddress[0]
    )) as RangeProtocolVault;
  });

  beforeEach(async () => {
    await token0.approve(vault.address, amountX.mul(bn(2)));
    await token1.approve(vault.address, amountY.mul(bn(2)));
  });

  it("should not mint when vault is not initialized", async () => {
    await expect(vault.mint(1, [0, 0])).to.be.revertedWithCustomError(
      vaultLib,
      "MintNotStarted"
    );
  });

  it("non-manager should not be able to updatePoints", async () => {
    expect(await vault.mintStarted()).to.be.equal(false);
    await expect(
      vault.connect(nonManager).updatePoints(lowerTick, upperTick)
    ).to.be.revertedWith("Ownable: caller is not the manager");
  });

  it("should not updatePoints with out of range ticks", async () => {
    await expect(
      vault.connect(manager).updatePoints(-800001, 0)
    ).to.be.revertedWithCustomError(vaultLib, "PointsOutOfRange");

    await expect(
      vault.connect(manager).updatePoints(0, 800001)
    ).to.be.revertedWithCustomError(vaultLib, "PointsOutOfRange");
  });

  it("should not updatePoints with ticks not following tick spacing", async () => {
    await expect(
      vault.connect(manager).updatePoints(0, 1)
    ).to.be.revertedWithCustomError(vaultLib, "InvalidPointsDelta");

    await expect(
      vault.connect(manager).updatePoints(1, 0)
    ).to.be.revertedWithCustomError(vaultLib, "InvalidPointsDelta");
  });

  it("manager should be able to updatePoints", async () => {
    expect(await vault.mintStarted()).to.be.equal(false);
    await expect(vault.connect(manager).updatePoints(lowerTick, upperTick))
      .to.emit(vault, "MintStarted")
      .to.emit(vault, "PointsSet")
      .withArgs(lowerTick, upperTick);

    expect(await vault.mintStarted()).to.be.equal(true);
    expect(await vault.leftPoint()).to.be.equal(lowerTick);
    expect(await vault.rightPoint()).to.be.equal(upperTick);
  });

  it("should not allow minting with zero mint amount", async () => {
    await expect(vault.mint(0, [0, 0])).to.be.revertedWithCustomError(
      vaultLib,
      "InvalidMintAmount"
    );
  });

  it("should not mint when contract is paused", async () => {
    expect(await vault.paused()).to.be.equal(false);
    await expect(vault.pause())
      .to.emit(vault, "Paused")
      .withArgs(manager.address);
    expect(await vault.paused()).to.be.equal(true);

    const {
      amountX: amountXToAdd,
      amountY: amountYToAdd,
      mintAmount,
    } = await vault.getMintAmounts(amountX, amountY);
    await expect(
      vault.mint(mintAmount, [amountXToAdd, amountYToAdd])
    ).to.be.revertedWith("Pausable: paused");
    await expect(vault.unpause())
      .to.emit(vault, "Unpaused")
      .withArgs(manager.address);
  });

  it("should mint with zero totalSupply of vault shares", async () => {
    const {
      mintAmount,
      // eslint-disable-next-line @typescript-eslint/naming-convention
      amountX: _amountX,
      // eslint-disable-next-line @typescript-eslint/naming-convention
      amountY: _amountY,
    } = await vault.getMintAmounts(amountX, amountY);
    console.log(
      ethers.utils.formatEther(_amountX),
      ethers.utils.formatEther(_amountY),
      mintAmount.toString()
    );
    // 1.999999999999999999 1.999999999999999999

    expect(await vault.totalSupply()).to.be.equal(0);
    expect(await token0.balanceOf(iZiSwapPool.address)).to.be.equal(0);
    expect(await token1.balanceOf(iZiSwapPool.address)).to.be.equal(0);

    await expect(vault.mint(mintAmount, [_amountX, _amountY]))
      .to.emit(vault, "Minted")
      .withArgs(manager.address, mintAmount, _amountX, _amountY);

    expect(await vault.totalSupply()).to.be.equal(mintAmount);
    expect(await token0.balanceOf(iZiSwapPool.address)).to.be.equal(_amountX);
    expect(await token1.balanceOf(iZiSwapPool.address)).to.be.equal(_amountY);
    expect(await vault.users(0)).to.be.equal(manager.address);
    expect((await vault.userVaults(manager.address)).exists).to.be.true;
    expect((await vault.userVaults(manager.address)).tokenX).to.be.equal(
      _amountX
    );
    expect((await vault.userVaults(manager.address)).tokenY).to.be.equal(
      _amountY
    );

    const userVault = (await vault.getUserVaults(0, 0))[0];
    expect(userVault.user).to.be.equal(manager.address);
    expect(userVault.tokenX).to.be.equal(_amountX);
    expect(userVault.tokenY).to.be.equal(_amountY);
    expect(await vault.userCount()).to.be.equal(1);
  });

  it("should not mint when min amounts are not satisfied", async () => {
    const {
      mintAmount,
      // eslint-disable-next-line @typescript-eslint/naming-convention
      amountX: amountXToAdd,
      // eslint-disable-next-line @typescript-eslint/naming-convention
      amountY: amountYToAdd,
    } = await vault.getMintAmounts(amountX, amountY);

    await expect(
      vault.mint(mintAmount, [amountXToAdd.div(2), amountYToAdd.div(2)])
    ).to.be.revertedWithCustomError(vaultLib, "SlippageExceedThreshold");
  });

  it("should mint with non zero totalSupply", async () => {
    const {
      mintAmount,
      // eslint-disable-next-line @typescript-eslint/naming-convention
      amountX: _amountX,
      // eslint-disable-next-line @typescript-eslint/naming-convention
      amountY: _amountY,
    } = await vault.getMintAmounts(amountX, amountY);
    console.log(
      ethers.utils.formatEther(_amountX),
      ethers.utils.formatEther(_amountY),
      mintAmount.toString()
    );
    // 2.0 2.0

    const userVault0Before = (await vault.userVaults(manager.address)).tokenX;
    const userVault1Before = (await vault.userVaults(manager.address)).tokenY;

    expect(await vault.totalSupply()).to.not.be.equal(0);
    await expect(vault.mint(mintAmount, [_amountX, _amountY]))
      .to.emit(vault, "Minted")
      .withArgs(manager.address, mintAmount, _amountX, _amountY);

    expect(await vault.users(0)).to.be.equal(manager.address);
    expect((await vault.userVaults(manager.address)).exists).to.be.true;
    expect((await vault.userVaults(manager.address)).tokenX).to.be.equal(
      userVault0Before.add(_amountX)
    );
    expect((await vault.userVaults(manager.address)).tokenY).to.be.equal(
      userVault1Before.add(_amountY)
    );

    const userVault = (await vault.getUserVaults(0, 0))[0];
    expect(userVault.user).to.be.equal(manager.address);
    expect(userVault.tokenX).to.be.equal(userVault0Before.add(_amountX));
    expect(userVault.tokenY).to.be.equal(userVault1Before.add(_amountY));
    expect(await vault.userCount()).to.be.equal(1);

    const { amountXCurrent, amountYCurrent } =
      await vault.getUnderlyingBalances();
    const shares = await vault.balanceOf(manager.address);
    const totalShares = await vault.totalSupply();
    const expectedamountX = shares.mul(amountXCurrent).div(totalShares);
    const expectedamountY = shares.mul(amountYCurrent).div(totalShares);

    const { amountX: amountXGot, amountY: amountYGot } =
      await vault.getUnderlyingBalancesByShare(shares);

    expect(amountXGot).to.be.equal(expectedamountX);
    expect(amountYGot).to.be.equal(expectedamountY);
  });

  it("should transfer vault shares to user2", async () => {
    const userBalance = await vault.balanceOf(manager.address);
    const userVault0 = (await vault.userVaults(manager.address)).tokenX;
    const userVault1 = (await vault.userVaults(manager.address)).tokenY;

    const vault0Moved = userVault0.sub(
      userVault0.mul(userBalance.sub(userBalance)).div(userBalance)
    );
    const vault1Moved = userVault1.sub(
      userVault1.mul(userBalance.sub(userBalance)).div(userBalance)
    );
    await vault.transfer(user2.address, userBalance);

    let userVaults = await vault.getUserVaults(0, 2);
    expect(userVaults[0].user).to.be.equal(manager.address);
    expect(userVaults[0].tokenX).to.be.equal(userVault0.sub(vault0Moved));
    expect(userVaults[0].tokenY).to.be.equal(userVault1.sub(vault1Moved));
    expect(await vault.userCount()).to.be.equal(2);

    expect(userVaults[1].user).to.be.equal(user2.address);
    expect(userVaults[1].tokenX).to.be.equal(vault0Moved);
    expect(userVaults[1].tokenY).to.be.equal(vault1Moved);

    const user2Balance = await vault.balanceOf(user2.address);
    const user2Vault0 = (await vault.userVaults(user2.address)).tokenX;
    const user2Vault1 = (await vault.userVaults(user2.address)).tokenY;
    await vault.connect(user2).transfer(manager.address, user2Balance);

    userVaults = await vault.getUserVaults(0, 2);
    expect(userVaults[0].tokenX).to.be.equal(userVault0);
    expect(userVaults[0].tokenY).to.be.equal(userVault1);

    expect(userVaults[1].tokenX).to.be.equal(bn(0));
    expect(userVaults[1].tokenY).to.be.equal(bn(0));
  });

  it("should not burn non existing vault shares", async () => {
    const burnAmount = parseEther("1");
    await expect(
      vault.connect(user2).burn(burnAmount, [0, 0])
    ).to.be.revertedWith("ERC20: burn amount exceeds balance");
  });

  it("should not burn when min amounts are not satisfied", async () => {
    const burnAmount = await vault.balanceOf(manager.address);
    const { amountX: minAmountX, amountY: minAmountY } =
      await vault.getUnderlyingBalancesByShare(burnAmount);
    await expect(
      vault.burn(burnAmount, [minAmountX.mul(2), minAmountY.mul(2)])
    ).to.be.revertedWithCustomError(vaultLib, "SlippageExceedThreshold");
  });

  it("should burn vault shares", async () => {
    const burnAmount = await vault.balanceOf(manager.address);
    const totalSupplyBefore = await vault.totalSupply();
    const [amountXCurrent, amountYCurrent] =
      await vault.getUnderlyingBalances();
    const userBalance0Before = await token0.balanceOf(manager.address);
    const userBalance1Before = await token1.balanceOf(manager.address);

    const userVault0Before = (await vault.userVaults(manager.address)).tokenX;
    const userVault1Before = (await vault.userVaults(manager.address)).tokenY;
    await vault.updateFees(50, 250);

    const managingFee = await vault.managingFee();
    const totalSupply = await vault.totalSupply();
    const vaultShares = await vault.balanceOf(manager.address);
    const userBalance0 = amountXCurrent.mul(vaultShares).div(totalSupply);
    const managingFee0 = userBalance0.mul(managingFee).div(10_000);

    const userBalance1 = amountYCurrent.mul(vaultShares).div(totalSupply);
    const managingFee1 = userBalance1.mul(managingFee).div(10_000);
    const { fee0, fee1 } = await vault.getCurrentFees();

    const { amountX: minAmountX, amountY: minAmountY } =
      await vault.getUnderlyingBalancesByShare(vaultShares);
    await expect(vault.burn(burnAmount, [minAmountX, minAmountY]))
      .to.emit(vault, "FeesEarned")
      .withArgs(fee0, fee1);
    expect(await vault.totalSupply()).to.be.equal(
      totalSupplyBefore.sub(burnAmount)
    );

    const amountXGot = amountXCurrent.mul(burnAmount).div(totalSupplyBefore);
    const amountYGot = amountYCurrent.mul(burnAmount).div(totalSupplyBefore);

    // expect(await token0.balanceOf(manager.address)).to.be.equal(
    //   userBalance0Before.add(amountXGot).sub(managingFee0)
    // );
    // expect(await token1.balanceOf(manager.address)).to.be.equal(
    //   userBalance1Before.add(amountYGot).sub(managingFee1)
    // );
    expect((await vault.userVaults(manager.address)).tokenX).to.be.equal(
      userVault0Before.mul(vaultShares.sub(burnAmount)).div(vaultShares)
    );
    expect((await vault.userVaults(manager.address)).tokenY).to.be.equal(
      userVault1Before.mul(vaultShares.sub(burnAmount)).div(vaultShares)
    );

    expect(await vault.managerBalanceX()).to.be.equal(managingFee0);
    expect(await vault.managerBalanceY()).to.be.equal(managingFee1);
    // console.log(ethers.utils.formatEther(managingFee0), ethers.utils.formatEther(managingFee1))
    // 0.019999999999999999 0.019999999999999999
  });

  it("should not add liquidity when total supply is zero and vault is out of the pool", async () => {
    const {
      amountX: amountXToAdd,
      amountY: amountYToAdd,
      mintAmount,
    } = await vault.getMintAmounts(amountX, amountY);
    await vault.mint(mintAmount, [amountXToAdd, amountYToAdd]);
    await vault.removeLiquidity([0, 0]);
    const shares = await vault.balanceOf(manager.address);
    const { amountX: minAmountX, amountY: minAmountY } =
      await vault.getUnderlyingBalancesByShare(shares);
    await vault.burn(shares, [minAmountX, minAmountY]);

    await expect(
      vault.mint(mintAmount, [amountXToAdd, amountYToAdd])
    ).to.be.revertedWithCustomError(vaultLib, "MintNotAllowed");
  });

  describe("Manager Fee", () => {
    it("should not update managing and performance fee by non manager", async () => {
      await expect(
        vault.connect(nonManager).updateFees(100, 1000)
      ).to.be.revertedWith("Ownable: caller is not the manager");
    });

    it("should not update managing fee above BPS", async () => {
      await expect(vault.updateFees(101, 100)).to.be.revertedWithCustomError(
        vaultLib,
        "InvalidManagingFee"
      );
    });

    it("should not update performance fee above BPS", async () => {
      await expect(vault.updateFees(100, 10001)).to.be.revertedWithCustomError(
        vaultLib,
        "InvalidPerformanceFee"
      );
    });

    it("should update manager and performance fee by manager", async () => {
      await expect(vault.updateFees(100, 300))
        .to.emit(vault, "FeesUpdated")
        .withArgs(100, 300);
    });
  });

  describe("Remove Liquidity", () => {
    before(async () => {
      await vault.updatePoints(lowerTick, upperTick);
    });

    beforeEach(async () => {
      await token0.approve(vault.address, amountX.mul(bn(2)));
      await token1.approve(vault.address, amountY.mul(bn(2)));
      const {
        amountX: amountXToAdd,
        amountY: amountYToAdd,
        mintAmount,
      } = await vault.getMintAmounts(amountX, amountY);
      await vault.mint(mintAmount, [amountXToAdd, amountYToAdd]);
    });

    it("should not remove liquidity by non-manager", async () => {
      await expect(
        vault.connect(nonManager).removeLiquidity([0, 0])
      ).to.be.revertedWith("Ownable: caller is not the manager");
    });

    it("should remove liquidity by manager", async () => {
      expect(await vault.leftPoint()).to.not.be.equal(await vault.rightPoint());
      expect(await vault.inThePosition()).to.be.equal(true);
      const { liquidity: liquidityBefore } = await iZiSwapPool.liquidity(
        position(vault.address, lowerTick, upperTick)
      );
      expect(liquidityBefore).not.to.be.equal(0);

      const { fee0, fee1 } = await vault.getCurrentFees();
      await expect(vault.removeLiquidity([0, 0]))
        .to.emit(vault, "InThePositionStatusSet")
        .withArgs(false)
        .to.emit(vault, "FeesEarned")
        .withArgs(fee0, fee1);

      expect(await vault.leftPoint()).to.be.equal(await vault.rightPoint());
      expect(await vault.inThePosition()).to.be.equal(false);
      const { liquidity: liquidityAfter } = await iZiSwapPool.liquidity(
        position(vault.address, lowerTick, upperTick)
      );
      expect(liquidityAfter).to.be.equal(0);
    });

    it("should burn vault shares when liquidity is removed", async () => {
      const { liquidity: liquidity } = await iZiSwapPool.liquidity(
        position(vault.address, lowerTick, upperTick)
      );

      expect(liquidity).to.be.equal(0);
      await expect(vault.removeLiquidity([0, 0]))
        .to.be.emit(vault, "InThePositionStatusSet")
        .withArgs(false)
        .not.to.emit(vault, "FeesEarned");

      const userBalance0Before = await token0.balanceOf(manager.address);
      const userBalance1Before = await token1.balanceOf(manager.address);
      const [amountXCurrent, amountYCurrent] =
        await vault.getUnderlyingBalances();
      const totalSupply = await vault.totalSupply();
      const vaultShares = await vault.balanceOf(manager.address);
      const managerBalanceXBefore = await vault.managerBalanceX();
      const managerBalanceYBefore = await vault.managerBalanceY();

      const managingFee = await vault.managingFee();
      const userBalance0 = amountXCurrent.mul(vaultShares).div(totalSupply);
      const managingFee0 = userBalance0.mul(managingFee).div(10_000);

      const userBalance1 = amountYCurrent.mul(vaultShares).div(totalSupply);
      const managingFee1 = userBalance1.mul(managingFee).div(10_000);
      const { amountX: minAmountX, amountY: minAmountY } =
        await vault.getUnderlyingBalancesByShare(vaultShares);
      await expect(
        vault.burn(vaultShares, [minAmountX, minAmountY])
      ).not.to.emit(vault, "FeesEarned");
      expect(await token0.balanceOf(manager.address)).to.be.equal(
        userBalance0Before.add(userBalance0).sub(managingFee0)
      );
      expect(await token1.balanceOf(manager.address)).to.be.equal(
        userBalance1Before.add(userBalance1).sub(managingFee1)
      );
      expect(await vault.managerBalanceX()).to.be.equal(
        managerBalanceXBefore.add(managingFee0)
      );
      expect(await vault.managerBalanceY()).to.be.equal(
        managerBalanceYBefore.add(managingFee1)
      );

      // console.log(ethers.utils.formatEther(await vault.managerBalanceX()), ethers.utils.formatEther(await vault.managerBalanceY()))
      // 0.089999999999999997 0.089999999999999997
    });
  });

  describe("Add Liquidity", () => {
    before(async () => {
      await vault.updatePoints(lowerTick, upperTick);
    });

    beforeEach(async () => {
      await token0.approve(vault.address, amountX.mul(bn(2)));
      await token1.approve(vault.address, amountY.mul(bn(2)));
      const {
        amountX: amountXToAdd,
        amountY: amountYToAdd,
        mintAmount,
      } = await vault.getMintAmounts(amountX, amountY);
      await vault.mint(mintAmount, [amountXToAdd, amountYToAdd]);
      await vault.removeLiquidity([0, 0]);
    });

    it("should not add liquidity by non-manager", async () => {
      const amountX = await token0.balanceOf(vault.address);
      const amountY = await token1.balanceOf(vault.address);

      await expect(
        vault
          .connect(nonManager)
          .addLiquidity(lowerTick, upperTick, amountX, amountY, [0, 0])
      ).to.be.revertedWith("Ownable: caller is not the manager");
    });

    it("should not add liquidity when min amounts are not satisfied", async () => {
      const { amountXCurrent, amountYCurrent } =
        await vault.getUnderlyingBalances();

      await expect(
        vault.addLiquidity(
          lowerTick,
          upperTick,
          amountXCurrent,
          amountYCurrent,
          [amountXCurrent, amountYCurrent.mul(2)]
        )
      ).to.be.revertedWithCustomError(vaultLib, "SlippageExceedThreshold");
    });

    it("should add liquidity by manager", async () => {
      const { amountXCurrent, amountYCurrent } =
        await vault.getUnderlyingBalances();

      // eslint-disable-next-line @typescript-eslint/naming-convention
      const MockMintMath = await ethers.getContractFactory("MockMintMath");
      const mockMintMath = await MockMintMath.deploy();

      const { sqrtPrice_96, currentPoint } = await iZiSwapPool.state();
      const sqrtRate_96 = await iZiSwapPool.sqrtRate_96();
      const liquidity = await mockMintMath.getLiquidityForAmounts(
        lowerTick,
        upperTick,
        amountXCurrent,
        amountYCurrent,
        currentPoint,
        sqrtPrice_96,
        sqrtRate_96
      );
      const { x, y } = await mockMintMath.getAmountsForLiquidity(
        sqrtPrice_96,
        sqrtRate_96,
        currentPoint,
        liquidity,
        lowerTick,
        upperTick
      );
      await expect(
        vault.addLiquidity(lowerTick, upperTick, x, y, [
          x.mul(9900).div(10000),
          y.mul(9900).div(10000),
        ])
      )
        .to.emit(vault, "LiquidityAdded")
        .withArgs(liquidity, lowerTick, upperTick, anyValue, anyValue)
        .to.emit(vault, "InThePositionStatusSet")
        .withArgs(true);
    });

    it("should not add liquidity when in the position", async () => {
      const { amountXCurrent, amountYCurrent } =
        await vault.getUnderlyingBalances();

      await vault.addLiquidity(
        lowerTick,
        upperTick,
        amountXCurrent,
        amountYCurrent,
        [
          amountXCurrent.mul(9900).div(10000),
          amountYCurrent.mul(9900).div(10000),
        ]
      );

      await expect(
        vault.addLiquidity(
          lowerTick,
          upperTick,
          amountXCurrent,
          amountYCurrent,
          [0, 0]
        )
      ).to.be.revertedWithCustomError(vaultLib, "LiquidityAlreadyAdded");
    });
  });

  describe("Swap", () => {
    it("should fail when minAmountIn is not satisfied", async () => {
      const { currentPoint } = await iZiSwapPool.state();
      await token1.transfer(vault.address, amountY);
      const { amountX: amountXIn } = await vault.callStatic.swap(
        false,
        amountY,
        currentPoint + 200,
        0
      );
      await expect(
        vault.swap(false, amountY, currentPoint + 200, amountXIn.mul(2))
      ).to.be.revertedWithCustomError(vaultLib, "SlippageExceedThreshold");
    });
  });

  describe("Fee collection", () => {
    it("non-manager should not collect fee", async () => {
      const { currentPoint } = await iZiSwapPool.state();
      await token1.transfer(vault.address, amountY);
      await vault.swap(false, amountY, currentPoint + upperTick, 0);
      const { fee0, fee1 } = await vault.getCurrentFees();
      await expect(vault.pullFeeFromPool())
        .to.emit(vault, "FeesEarned")
        .withArgs(fee0, fee1);

      await expect(
        vault.connect(nonManager).collectManager()
      ).to.be.revertedWith("Ownable: caller is not the manager");
    });

    it("should swap from X2Y", async () => {
      const { currentPoint } = await iZiSwapPool.state();
      await token0.transfer(vault.address, amountX);
      const { amountX: amountXOut, amountY: amountYIn } =
        await vault.callStatic.swap(true, amountX, currentPoint - 200, 0);
      const tokenXBefore = await token0.balanceOf(vault.address);
      const tokenYBefore = await token1.balanceOf(vault.address);
      await vault.swap(true, amountX, currentPoint - 200, amountYIn);
      expect(await token0.balanceOf(vault.address)).to.be.equal(
        tokenXBefore.sub(amountXOut)
      );
      expect(await token1.balanceOf(vault.address)).to.be.equal(
        tokenYBefore.add(amountYIn)
      );
    });

    it("should swap from Y2X", async () => {
      const { currentPoint } = await iZiSwapPool.state();
      await token1.transfer(vault.address, amountY);
      const { amountX: amountXIn, amountY: amountYOut } =
        await vault.callStatic.swap(false, amountY, currentPoint + 200, 0);

      const tokenXBefore = await token0.balanceOf(vault.address);
      const tokenYBefore = await token1.balanceOf(vault.address);
      await vault.swap(false, amountY, currentPoint + 200, amountXIn);
      expect(await token0.balanceOf(vault.address)).to.be.equal(
        tokenXBefore.add(amountXIn)
      );
      expect(await token1.balanceOf(vault.address)).to.be.equal(
        tokenYBefore.sub(amountYOut)
      );
    });

    it("should manager collect fee", async () => {
      const { currentPoint } = await iZiSwapPool.state();
      await token1.transfer(vault.address, amountY);
      const { amountX: amountXIn } = await vault.callStatic.swap(
        false,
        amountY,
        currentPoint + 200,
        0
      );
      await vault.swap(false, amountY, currentPoint + 200, amountXIn);
      const managerBalanceXBefore = await token0.balanceOf(manager.address);
      const managerBalanceYBefore = await token1.balanceOf(manager.address);

      const { fee0, fee1 } = await vault.getCurrentFees();
      await expect(vault.pullFeeFromPool())
        .to.emit(vault, "FeesEarned")
        .withArgs(fee0, fee1);

      const managerBalanceX = await vault.managerBalanceX();
      const managerBalanceY = await vault.managerBalanceY();

      await vault.connect(manager).collectManager();

      expect(await token0.balanceOf(manager.address)).to.be.equal(
        managerBalanceXBefore.add(managerBalanceX)
      );
      expect(await token1.balanceOf(manager.address)).to.be.equal(
        managerBalanceYBefore.add(managerBalanceY)
      );

      expect(await vault.managerBalanceX()).to.be.equal(0);
      expect(await vault.managerBalanceY()).to.be.equal(0);
    });

    it("pull fee using updateFee function", async () => {
      const { currentPoint } = await iZiSwapPool.state();
      await token1.transfer(vault.address, amountY);
      await vault.swap(false, amountY, currentPoint + upperTick, 0);
      const { fee0, fee1 } = await vault.getCurrentFees();
      await expect(vault.updateFees(0, 0))
        .to.emit(vault, "FeesEarned")
        .withArgs(fee0, fee1);

      const managerBalanceX = await vault.managerBalanceX();
      const managerBalanceY = await vault.managerBalanceY();
      const managerBalanceXBefore = await token0.balanceOf(manager.address);
      const managerBalanceYBefore = await token1.balanceOf(manager.address);
      await vault.connect(manager).collectManager();

      expect(await token0.balanceOf(manager.address)).to.be.equal(
        managerBalanceXBefore.add(managerBalanceX)
      );
      expect(await token1.balanceOf(manager.address)).to.be.equal(
        managerBalanceYBefore.add(managerBalanceY)
      );

      expect(await vault.managerBalanceX()).to.be.equal(0);
      expect(await vault.managerBalanceY()).to.be.equal(0);
    });
  });

  describe("Test Upgradeability", () => {
    it("should not upgrade range vault implementation by non-manager of factory", async () => {
      // eslint-disable-next-line @typescript-eslint/naming-convention
      const RangeProtocolVault = await ethers.getContractFactory(
        "RangeProtocolVault",
        {
          libraries: {
            VaultLib: vaultLib.address,
          },
        }
      );
      const newVaultImpl =
        (await RangeProtocolVault.deploy()) as RangeProtocolVault;

      await expect(
        factory
          .connect(nonManager)
          .upgradeVault(vault.address, newVaultImpl.address)
      ).to.be.revertedWith("Ownable: caller is not the owner");

      await expect(
        factory
          .connect(nonManager)
          .upgradeVaults([vault.address], [newVaultImpl.address])
      ).to.be.revertedWith("Ownable: caller is not the owner");
    });

    it("an EOA address provided as implementation should not upgrade the contract", async () => {
      const newVaultImpl = manager.address;
      await expect(
        factory.upgradeVault(vault.address, newVaultImpl)
      ).to.be.revertedWithCustomError(factory, "ImplIsNotAContract");
    });

    it("should upgrade range vault implementation by factory manager", async () => {
      // eslint-disable-next-line @typescript-eslint/naming-convention
      const RangeProtocolVault = await ethers.getContractFactory(
        "RangeProtocolVault",
        {
          libraries: {
            VaultLib: vaultLib.address,
          },
        }
      );
      const newVaultImpl =
        (await RangeProtocolVault.deploy()) as RangeProtocolVault;

      const implSlot = await vaultImpl.proxiableUUID();
      expect(
        await ethers.provider.getStorageAt(vault.address, implSlot)
      ).to.be.equal(
        ethers.utils.hexZeroPad(vaultImpl.address.toLowerCase(), 32)
      );
      await expect(factory.upgradeVault(vault.address, newVaultImpl.address))
        .to.emit(factory, "VaultImplUpgraded")
        .withArgs(vault.address, newVaultImpl.address);

      expect(
        await ethers.provider.getStorageAt(vault.address, implSlot)
      ).to.be.equal(
        ethers.utils.hexZeroPad(newVaultImpl.address.toLowerCase(), 32)
      );

      const newVaultImpl1 =
        (await RangeProtocolVault.deploy()) as RangeProtocolVault;

      expect(
        await ethers.provider.getStorageAt(vault.address, implSlot)
      ).to.be.equal(
        ethers.utils.hexZeroPad(newVaultImpl.address.toLowerCase(), 32)
      );
      await expect(
        factory.upgradeVaults([vault.address], [newVaultImpl1.address])
      )
        .to.emit(factory, "VaultImplUpgraded")
        .withArgs(vault.address, newVaultImpl1.address);

      expect(
        await ethers.provider.getStorageAt(vault.address, implSlot)
      ).to.be.equal(
        ethers.utils.hexZeroPad(newVaultImpl1.address.toLowerCase(), 32)
      );

      vaultImpl = newVaultImpl1;
    });
  });

  describe("transferOwnership", () => {
    it("should not be able to transferOwnership by non manager", async () => {
      await expect(
        vault.connect(nonManager).transferOwnership(newManager.address)
      ).to.be.revertedWith("Ownable: caller is not the manager");
    });

    it("should be able to transferOwnership by manager", async () => {
      await expect(vault.transferOwnership(newManager.address))
        .to.emit(vault, "OwnershipTransferred")
        .withArgs(manager.address, newManager.address);
      expect(await vault.manager()).to.be.equal(newManager.address);

      await vault.connect(newManager).transferOwnership(manager.address);
      expect(await vault.manager()).to.be.equal(manager.address);
    });
  });
});
