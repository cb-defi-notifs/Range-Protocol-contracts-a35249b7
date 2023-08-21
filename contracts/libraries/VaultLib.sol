//SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {SafeCastUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/math/SafeCastUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {SafeERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {IiZiSwapPool} from "./iZiSwap/interfaces/IiZiSwapPool.sol";

import {MintMath} from "./iZiSwap/libraries/MintMath.sol";
import {MulDivMath} from "./iZiSwap/libraries/MulDivMath.sol";
import {IRangeProtocolVault} from "./interfaces/IRangeProtocolVault.sol";
import {RangeProtocolVaultStorage} from "./RangeProtocolVaultStorage.sol";
import {OwnableUpgradeable} from "./access/OwnableUpgradeable.sol";
import {VaultErrors} from "./errors/VaultErrors.sol";

library VaultLib {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    int24 internal constant LEFT_MOST_PT = -800000;
    int24 internal constant RIGHT_MOST_PT = 800000;

    /// Performance fee cannot be set more than 10% of the fee earned from uniswap v3 pool.
    uint16 public constant MAX_PERFORMANCE_FEE_BPS = 1000;
    /// Managing fee cannot be set more than 1% of the total fee earned.
    uint16 public constant MAX_MANAGING_FEE_BPS = 100;

    function updatePoints(int24 _leftPoint, int24 _rightPoint) external override onlyManager {
        if (totalSupply() != 0 || inThePosition) revert VaultErrors.NotAllowedToUpdateTicks();
        _updatePoints(_leftPoint, _rightPoint);

        if (!mintStarted) {
            mintStarted = true;
            emit MintStarted();
        }
    }

    function pause() external onlyManager {
        _pause();
    }

    function unpause() external onlyManager {
        _unpause();
    }

    /// @notice uniswapV3MintCallback Uniswap V3 callback fn, called back on pool.mint
    function mintDepositCallback(uint256 x, uint256 y, bytes calldata) external override {
        if (msg.sender != address(pool)) revert VaultErrors.OnlyPoolAllowed();

        if (x > 0) {
            token0.safeTransfer(msg.sender, x);
        }

        if (y > 0) {
            token1.safeTransfer(msg.sender, y);
        }
    }

    function swapX2YCallback(uint256 x, uint256 y, bytes calldata data) external override {
        if (msg.sender != address(pool)) revert VaultErrors.OnlyPoolAllowed();
        if (x > 0) {
            token0.safeTransfer(msg.sender, x);
        }
    }

    function swapY2XCallback(uint256 x, uint256 y, bytes calldata data) external override {
        if (msg.sender != address(pool)) revert VaultErrors.OnlyPoolAllowed();
        if (y > 0) {
            token1.safeTransfer(msg.sender, y);
        }
    }

    function mint(
        uint256 mintAmount
    ) external override nonReentrant whenNotPaused returns (uint256 amount0, uint256 amount1) {
        if (!mintStarted) revert VaultErrors.MintNotStarted();
        if (mintAmount == 0) revert VaultErrors.InvalidMintAmount();
        uint256 totalSupply = totalSupply();
        bool _inThePosition = inThePosition;
        (uint160 sqrtPrice_96, int24 currentPoint, , , , , , ) = pool.state();
        if (totalSupply > 0) {
            (uint256 amount0Current, uint256 amount1Current) = getUnderlyingBalances();
            amount0 = MulDivMath.mulDivCeil(amount0Current, mintAmount, totalSupply);
            amount1 = MulDivMath.mulDivCeil(amount1Current, mintAmount, totalSupply);
        } else if (_inThePosition) {
            // If total supply is zero then inThePosition must be set to accept token0 and token1 based on currently set currentPoints.
            // This branch will be executed for the first mint and as well as each time total supply is to be changed from zero to non-zero.

            (amount0, amount1) = MintMath.getAmountsForLiquidity(
                sqrtPrice_96,
                pool.sqrtRate_96(),
                currentPoint,
                SafeCastUpgradeable.toUint128(mintAmount),
                leftPoint,
                rightPoint
            );
        } else {
            // If total supply is zero and the vault is not in the position then mint cannot be accepted based on the assumptions
            // that being out of the pool renders currently set currentPoints unusable and totalSupply being zero does not allow
            // calculating correct amounts of amount0 and amount1 to be accepted from the user.
            // This branch will be executed if all users remove their liquidity from the vault i.e. total supply is zero from non-zero and
            // the vault is out of the position i.e. no validcurrentPoint range to calculate the vault's mint shares.
            // Manager must call initialize function with validcurrentPoint ranges to enable the minting again.
            revert VaultErrors.MintNotAllowed();
        }

        if (!userVaults[msg.sender].exists) {
            userVaults[msg.sender].exists = true;
            users.push(msg.sender);
        }
        if (amount0 > 0) {
            userVaults[msg.sender].token0 += amount0;
            token0.safeTransferFrom(msg.sender, address(this), amount0);
        }
        if (amount1 > 0) {
            userVaults[msg.sender].token1 += amount1;
            token1.safeTransferFrom(msg.sender, address(this), amount1);
        }

        _mint(msg.sender, mintAmount);
        if (_inThePosition) {
            uint128 liquidityMinted = MintMath.getLiquidityForAmounts(
                leftPoint,
                rightPoint,
                uint128(amount0),
                uint128(amount1),
                currentPoint,
                sqrtPrice_96,
                pool.sqrtRate_96()
            );
            pool.mint(address(this), leftPoint, rightPoint, liquidityMinted, "");
        }

        emit Minted(msg.sender, mintAmount, amount0, amount1);
    }

    function burn(
        uint256 burnAmount
    ) external override nonReentrant whenNotPaused returns (uint256 amount0, uint256 amount1) {
        if (burnAmount == 0) revert VaultErrors.InvalidBurnAmount();
        uint256 totalSupply = totalSupply();
        uint256 balanceBefore = balanceOf(msg.sender);
        _burn(msg.sender, burnAmount);

        if (inThePosition) {
            IiZiSwapPool.LiquidityData memory liquidityData = pool.liquidity(getPositionID());
            uint256 liquidityBurned_ = MulDivMath.mulDivFloor(
                burnAmount,
                liquidityData.liquidity,
                totalSupply
            );
            uint128 liquidityBurned = SafeCastUpgradeable.toUint128(liquidityBurned_);
            (uint256 burn0, uint256 burn1, uint256 fee0, uint256 fee1) = _withdraw(liquidityBurned);

            _applyPerformanceFee(fee0, fee1);
            (fee0, fee1) = _netPerformanceFees(fee0, fee1);
            emit FeesEarned(fee0, fee1);

            uint256 passiveBalance0 = token0.balanceOf(address(this)) - burn0;
            uint256 passiveBalance1 = token1.balanceOf(address(this)) - burn1;
            if (passiveBalance0 > managerBalance0) passiveBalance0 -= managerBalance0;
            if (passiveBalance1 > managerBalance1) passiveBalance1 -= managerBalance1;

            amount0 = burn0 + MulDivMath.mulDivFloor(passiveBalance0, burnAmount, totalSupply);
            amount1 = burn1 + MulDivMath.mulDivFloor(passiveBalance1, burnAmount, totalSupply);
        } else {
            (uint256 amount0Current, uint256 amount1Current) = getUnderlyingBalances();
            amount0 = MulDivMath.mulDivFloor(amount0Current, burnAmount, totalSupply);
            amount1 = MulDivMath.mulDivFloor(amount1Current, burnAmount, totalSupply);
        }

        _applyManagingFee(amount0, amount1);
        (uint256 amount0AfterFee, uint256 amount1AfterFee) = _netManagingFees(amount0, amount1);
        if (amount0 > 0) {
            userVaults[msg.sender].token0 =
            (userVaults[msg.sender].token0 * (balanceBefore - burnAmount)) /
            balanceBefore;
            token0.safeTransfer(msg.sender, amount0AfterFee);
        }
        if (amount1 > 0) {
            userVaults[msg.sender].token1 =
            (userVaults[msg.sender].token1 * (balanceBefore - burnAmount)) /
            balanceBefore;
            token1.safeTransfer(msg.sender, amount1AfterFee);
        }

        emit Burned(msg.sender, burnAmount, amount0AfterFee, amount1AfterFee);
    }

    function removeLiquidity() external override onlyManager {
        IiZiSwapPool.LiquidityData memory liquidityData = pool.liquidity(getPositionID());

        if (liquidityData.liquidity > 0) {
            int24 _leftPoint = leftPoint;
            int24 _rightPoint = rightPoint;
            (uint256 amount0, uint256 amount1, uint256 fee0, uint256 fee1) = _withdraw(
                liquidityData.liquidity
            );

            emit LiquidityRemoved(
                liquidityData.liquidity,
                _leftPoint,
                _rightPoint,
                amount0,
                amount1
            );

            _applyPerformanceFee(fee0, fee1);
            (fee0, fee1) = _netPerformanceFees(fee0, fee1);
            emit FeesEarned(fee0, fee1);
        }

        // TicksSet event is not emitted here since the emitting would create a new position on subgraph but
        // the following statement is to only disallow any liquidity provision through the vault unless done
        // by manager (taking into account any features added in future).
        leftPoint = rightPoint;
        inThePosition = false;
        emit InThePositionStatusSet(false);
    }

    function swap(
        bool zeroForOne,
        uint128 swapAmount,
        int24 pointLimit
    ) external override onlyManager returns (uint256 amount0, uint256 amount1) {
        if (zeroForOne) {
            (amount0, amount1) = pool.swapX2Y(address(this), swapAmount, pointLimit, bytes(""));
        } else {
            (amount0, amount1) = pool.swapY2X(address(this), swapAmount, pointLimit, bytes(""));
        }

        emit Swapped(zeroForOne, amount0, amount1);
    }

    function addLiquidity(
        int24 newLeftPoint,
        int24 newRightPoint,
        uint128 amount0,
        uint128 amount1
    ) external override onlyManager returns (uint256 remainingAmount0, uint256 remainingAmount1) {
        _validateTicks(newLeftPoint, newRightPoint);
        if (inThePosition) revert VaultErrors.LiquidityAlreadyAdded();

        (uint160 sqrtPrice_96, int24 currentPoint, , , , , , ) = pool.state();
        uint128 baseLiquidity = MintMath.getLiquidityForAmounts(
            newLeftPoint,
            newRightPoint,
            amount0,
            amount1,
            currentPoint,
            sqrtPrice_96,
            pool.sqrtRate_96()
        );

        if (baseLiquidity > 0) {
            (uint256 amountDeposited0, uint256 amountDeposited1) = pool.mint(
                address(this),
                newLeftPoint,
                newRightPoint,
                baseLiquidity,
                ""
            );

            emit LiquidityAdded(
                baseLiquidity,
                newLeftPoint,
                newRightPoint,
                amountDeposited0,
                amountDeposited1
            );

            // Should return remaining token number for swap
            remainingAmount0 = amount0 - amountDeposited0;
            remainingAmount1 = amount1 - amountDeposited1;
            leftPoint = newLeftPoint;
            rightPoint = newRightPoint;
            emit TicksSet(newLeftPoint, newRightPoint);

            inThePosition = true;
            emit InThePositionStatusSet(true);
        }
    }

    function pullFeeFromPool() external onlyManager {
        (, , uint256 fee0, uint256 fee1) = _withdraw(0);
        _applyPerformanceFee(fee0, fee1);
        (fee0, fee1) = _netPerformanceFees(fee0, fee1);
        emit FeesEarned(fee0, fee1);
    }

    /// @notice collectManager collects manager fees accrued
    function collectManager() external override onlyManager {
        uint256 amount0 = managerBalance0;
        uint256 amount1 = managerBalance1;
        managerBalance0 = 0;
        managerBalance1 = 0;

        if (amount0 > 0) {
            token0.safeTransfer(manager(), amount0);
        }
        if (amount1 > 0) {
            token1.safeTransfer(manager(), amount1);
        }
    }

    function updateFees(
        uint16 newManagingFee,
        uint16 newPerformanceFee
    ) external override onlyManager {
        if (newManagingFee > MAX_MANAGING_FEE_BPS) revert VaultErrors.InvalidManagingFee();
        if (newPerformanceFee > MAX_PERFORMANCE_FEE_BPS) revert VaultErrors.InvalidPerformanceFee();

        managingFee = newManagingFee;
        performanceFee = newPerformanceFee;
        emit FeesUpdated(newManagingFee, newPerformanceFee);
    }

    function getMintAmounts(
        uint128 amount0Max,
        uint128 amount1Max
    ) external view override returns (uint256 amount0, uint256 amount1, uint256 mintAmount) {
        if (!mintStarted) revert VaultErrors.MintNotStarted();
        uint256 totalSupply = totalSupply();
        if (totalSupply > 0) {
            (amount0, amount1, mintAmount) = _calcMintAmounts(totalSupply, amount0Max, amount1Max);
        } else {
            (uint160 sqrtPrice_96, int24 currentPoint, , , , , , ) = pool.state();
            uint128 newLiquidity = MintMath.getLiquidityForAmounts(
                leftPoint,
                rightPoint,
                amount0Max,
                amount1Max,
                currentPoint,
                sqrtPrice_96,
                pool.sqrtRate_96()
            );
            mintAmount = uint256(newLiquidity);
            (amount0, amount1) = MintMath.getAmountsForLiquidity(
                sqrtPrice_96,
                pool.sqrtRate_96(),
                currentPoint,
                newLiquidity,
                leftPoint,
                rightPoint
            );
        }
    }

    function getUnderlyingBalancesAtPrice(
        uint160 sqrtPrice_96
    ) external view override returns (uint256 amount0Current, uint256 amount1Current) {
        (, int24 currentPoint, , , , , , ) = pool.state();
        return _getUnderlyingBalances(sqrtPrice_96, currentPoint);
    }

    function getCurrentFees() external view override returns (uint256 fee0, uint256 fee1) {
        (, int24 currentPoint, , , , , , ) = pool.state();
        IiZiSwapPool.LiquidityData memory liquidityData = pool.liquidity(getPositionID());

        fee0 =
        _feesEarned(
            true,
            liquidityData.lastFeeScaleX_128,
            currentPoint,
            liquidityData.liquidity
        ) +
        liquidityData.tokenOwedX;
        fee1 =
        _feesEarned(
            false,
            liquidityData.lastFeeScaleY_128,
            currentPoint,
            liquidityData.liquidity
        ) +
        liquidityData.tokenOwedY;
        (fee0, fee1) = _netPerformanceFees(fee0, fee1);
    }

    function getUserVaults(
        uint256 fromIdx,
        uint256 toIdx
    ) external view override returns (UserVaultInfo[] memory) {
        if (fromIdx == 0 && toIdx == 0) {
            toIdx = users.length;
        }
        UserVaultInfo[] memory usersVaultInfo = new UserVaultInfo[](toIdx - fromIdx);
        uint256 count;
        for (uint256 i = fromIdx; i < toIdx; i++) {
            UserVault memory userVault = userVaults[users[i]];
            usersVaultInfo[count++] = UserVaultInfo({
                user: users[i],
                token0: userVault.token0,
                token1: userVault.token1
            });
        }
        return usersVaultInfo;
    }

    function userCount() external view returns (uint256) {
        return users.length;
    }

    function getPositionID() public view override returns (bytes32 positionID) {
        return keccak256(abi.encodePacked(address(this), leftPoint, rightPoint));
    }

    function getUnderlyingBalances()
    public
    view
    override
    returns (uint256 amount0Current, uint256 amount1Current)
    {
        (uint160 sqrtPrice_96, int24 currentPoint, , , , , , ) = pool.state();
        return _getUnderlyingBalances(sqrtPrice_96, currentPoint);
    }

    function getUnderlyingBalancesByShare(
        uint256 shares
    ) external view returns (uint256 amount0, uint256 amount1) {
        uint256 _totalSupply = totalSupply();
        if (_totalSupply != 0) {
            // getUnderlyingBalances already applies performanceFee
            (uint256 amount0Current, uint256 amount1Current) = getUnderlyingBalances();
            amount0 = (shares * amount0Current) / _totalSupply;
            amount1 = (shares * amount1Current) / _totalSupply;
            // apply managing fee
            (amount0, amount1) = _netManagingFees(amount0, amount1);
        }
    }

    function _getUnderlyingBalances(
        uint160 sqrtPrice_96,
        int24 currentPoint
    ) internal view returns (uint256 amount0Current, uint256 amount1Current) {
        IiZiSwapPool.LiquidityData memory liquidityData = pool.liquidity(getPositionID());
        (uint160 sqrtPrice_96, int24 currentPoint, , , , , , ) = pool.state();

        uint256 fee0;
        uint256 fee1;
        if (liquidityData.liquidity != 0) {
            (amount0Current, amount1Current) = MintMath.getAmountsForLiquidity(
                sqrtPrice_96,
                pool.sqrtRate_96(),
                currentPoint,
                liquidityData.liquidity,
                leftPoint,
                rightPoint
            );
            fee0 =
            _feesEarned(
                true,
                liquidityData.lastFeeScaleX_128,
                currentPoint,
                liquidityData.liquidity
            ) +
            liquidityData.tokenOwedX;
            fee1 =
            _feesEarned(
                false,
                liquidityData.lastFeeScaleY_128,
                currentPoint,
                liquidityData.liquidity
            ) +
            liquidityData.tokenOwedY;
            (fee0, fee1) = _netPerformanceFees(fee0, fee1);
        }

        uint256 passiveBalance0 = fee0 + token0.balanceOf(address(this));
        uint256 passiveBalance1 = fee1 + token1.balanceOf(address(this));
        amount0Current += passiveBalance0 > managerBalance0
            ? passiveBalance0 - managerBalance0
            : passiveBalance0;
        amount1Current += passiveBalance1 > managerBalance1
            ? passiveBalance1 - managerBalance1
            : passiveBalance1;
    }

    function _authorizeUpgrade(address) internal override {
        if (msg.sender != factory) revert VaultErrors.OnlyFactoryAllowed();
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override {
        super._beforeTokenTransfer(from, to, amount);

        // for mint and burn the user vaults adjustment are handled in the respective functions
        if (from == address(0x0) || to == address(0x0)) return;
        if (!userVaults[to].exists) {
            userVaults[to].exists = true;
            users.push(to);
        }
        uint256 senderBalance = balanceOf(from);
        uint256 token0Amount = userVaults[from].token0 -
        (userVaults[from].token0 * (senderBalance - amount)) /
        senderBalance;

        uint256 token1Amount = userVaults[from].token1 -
        (userVaults[from].token1 * (senderBalance - amount)) /
        senderBalance;

        userVaults[from].token0 -= token0Amount;
        userVaults[from].token1 -= token1Amount;

        userVaults[to].token0 += token0Amount;
        userVaults[to].token1 += token1Amount;
    }

    function _withdraw(
        uint128 liquidity
    ) private returns (uint256 burn0, uint256 burn1, uint256 fee0, uint256 fee1) {
        int24 _leftPoint = leftPoint;
        int24 _rightPoint = rightPoint;
        uint256 preBalance0 = token0.balanceOf(address(this));
        uint256 preBalance1 = token1.balanceOf(address(this));
        (burn0, burn1) = pool.burn(_leftPoint, _rightPoint, liquidity);
        pool.collect(address(this), _leftPoint, _rightPoint, type(uint128).max, type(uint128).max);
        fee0 = token0.balanceOf(address(this)) - preBalance0 - burn0;
        fee1 = token1.balanceOf(address(this)) - preBalance1 - burn1;
    }

    function _calcMintAmounts(
        uint256 totalSupply,
        uint256 amount0Max,
        uint256 amount1Max
    ) private view returns (uint256 amount0, uint256 amount1, uint256 mintAmount) {
        (uint256 amount0Current, uint256 amount1Current) = getUnderlyingBalances();
        if (amount0Current == 0 && amount1Current > 0) {
            mintAmount = MulDivMath.mulDivFloor(amount1Max, totalSupply, amount1Current);
        } else if (amount1Current == 0 && amount0Current > 0) {
            mintAmount = MulDivMath.mulDivFloor(amount0Max, totalSupply, amount0Current);
        } else if (amount0Current == 0 && amount1Current == 0) {
            revert VaultErrors.ZeroUnderlyingBalance();
        } else {
            uint256 amount0Mint = MulDivMath.mulDivFloor(amount0Max, totalSupply, amount0Current);
            uint256 amount1Mint = MulDivMath.mulDivFloor(amount1Max, totalSupply, amount1Current);
            if (amount0Mint == 0 || amount1Mint == 0) revert VaultErrors.ZeroMintAmount();
            mintAmount = amount0Mint < amount1Mint ? amount0Mint : amount1Mint;
        }

        amount0 = MulDivMath.mulDivCeil(mintAmount, amount0Current, totalSupply);
        amount1 = MulDivMath.mulDivCeil(mintAmount, amount1Current, totalSupply);
    }

    function _feesEarned(
        bool isZero,
        uint256 feeGrowthInsideLast,
        int24 point,
        uint128 liquidity
    ) private view returns (uint256 fee) {
        uint256 feeGrowthOutsideLower;
        uint256 feeGrowthOutsideUpper;
        uint256 feeGrowthGlobal;
        if (isZero) {
            feeGrowthGlobal = pool.feeScaleX_128();
            IiZiSwapPool.PointData memory lowerPointData = pool.points(leftPoint);
            IiZiSwapPool.PointData memory upperPointData = pool.points(rightPoint);
            feeGrowthOutsideLower = lowerPointData.accFeeXOut_128;
            feeGrowthOutsideUpper = upperPointData.accFeeXOut_128;
        } else {
            feeGrowthGlobal = pool.feeScaleY_128();
            IiZiSwapPool.PointData memory lowerPointData = pool.points(leftPoint);
            IiZiSwapPool.PointData memory upperPointData = pool.points(rightPoint);
            feeGrowthOutsideLower = lowerPointData.accFeeYOut_128;
            feeGrowthOutsideUpper = upperPointData.accFeeYOut_128;
        }

        unchecked {
            uint256 feeGrowthBelow;
            if (point >= leftPoint) {
                feeGrowthBelow = feeGrowthOutsideLower;
            } else {
                feeGrowthBelow = feeGrowthGlobal - feeGrowthOutsideLower;
            }

            uint256 feeGrowthAbove;
            if (point < rightPoint) {
                feeGrowthAbove = feeGrowthOutsideUpper;
            } else {
                feeGrowthAbove = feeGrowthGlobal - feeGrowthOutsideUpper;
            }
            uint256 feeGrowthInside = feeGrowthGlobal - feeGrowthBelow - feeGrowthAbove;

            fee = MulDivMath.mulDivFloor(
                liquidity,
                feeGrowthInside - feeGrowthInsideLast,
                0x100000000000000000000000000000000
            );
        }
    }

    function _applyManagingFee(uint256 amount0, uint256 amount1) private {
        uint256 _managingFee = managingFee;
        managerBalance0 += (amount0 * _managingFee) / 10_000;
        managerBalance1 += (amount1 * _managingFee) / 10_000;
    }

    function _applyPerformanceFee(uint256 fee0, uint256 fee1) private {
        uint256 _performanceFee = performanceFee;
        managerBalance0 += (fee0 * _performanceFee) / 10_000;
        managerBalance1 += (fee1 * _performanceFee) / 10_000;
    }

    function _netManagingFees(
        uint256 amount0,
        uint256 amount1
    ) private view returns (uint256 amount0AfterFee, uint256 amount1AfterFee) {
        uint256 _managingFee = managingFee;
        uint256 deduct0 = (amount0 * _managingFee) / 10_000;
        uint256 deduct1 = (amount1 * _managingFee) / 10_000;
        amount0AfterFee = amount0 - deduct0;
        amount1AfterFee = amount1 - deduct1;
    }

    function _netPerformanceFees(
        uint256 rawFee0,
        uint256 rawFee1
    ) private view returns (uint256 fee0AfterDeduction, uint256 fee1AfterDeduction) {
        uint256 _performanceFee = performanceFee;
        uint256 deduct0 = (rawFee0 * _performanceFee) / 10_000;
        uint256 deduct1 = (rawFee1 * _performanceFee) / 10_000;
        fee0AfterDeduction = rawFee0 - deduct0;
        fee1AfterDeduction = rawFee1 - deduct1;
    }

    function _updatePoints(int24 _leftPoint, int24 _rightPoint) private {
        _validateTicks(_leftPoint, _rightPoint);
        leftPoint = _leftPoint;
        rightPoint = _rightPoint;

        // Upon updating current points inThePosition status is set to true.
        inThePosition = true;
        emit InThePositionStatusSet(true);
        emit TicksSet(_leftPoint, _rightPoint);
    }

    function _validateTicks(int24 _leftPoint, int24 _rightPoint) private view {
        if (_leftPoint < LEFT_MOST_PT || _rightPoint > RIGHT_MOST_PT)
            revert VaultErrors.TicksOutOfRange();

        if (
            _leftPoint >= _rightPoint ||
            _leftPoint % pointDelta != 0 ||
            _rightPoint % pointDelta != 0
        ) revert VaultErrors.InvalidTicksSpacing();
    }
}