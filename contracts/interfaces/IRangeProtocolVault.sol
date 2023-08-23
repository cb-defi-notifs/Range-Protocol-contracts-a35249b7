//SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {IiZiSwapCallback, IiZiSwapMintCallback} from "../iZiSwap/interfaces/IiZiSwapCallback.sol";
import {IiZiSwapPool} from "../iZiSwap/interfaces/IiZiSwapPool.sol";
import {DataTypes} from "../libraries/DataTypes.sol";

interface IRangeProtocolVault is IERC20Upgradeable, IiZiSwapCallback, IiZiSwapMintCallback {
    event Minted(
        address indexed receiver,
        uint256 mintAmount,
        uint256 amount0In,
        uint256 amount1In
    );
    event Burned(
        address indexed receiver,
        uint256 burnAmount,
        uint256 amount0Out,
        uint256 amount1Out
    );
    event LiquidityAdded(
        uint256 liquidityMinted,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0In,
        uint256 amount1In
    );
    event LiquidityRemoved(
        uint256 liquidityRemoved,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Out,
        uint256 amount1Out
    );
    event FeesEarned(uint256 feesEarned0, uint256 feesEarned1);
    event FeesUpdated(uint16 managingFee, uint16 performanceFee);
    event InThePositionStatusSet(bool inThePosition);
    event Swapped(bool zeroForOne, uint256 amount0, uint256 amount1);
    event TicksSet(int24 lowerTick, int24 upperTick);
    event MintStarted();

    function leftPoint() external view returns (int24);

    function rightPoint() external view returns (int24);

    function pointDelta() external view returns (int24);

    function pool() external view returns (IiZiSwapPool);

    function tokenX() external view returns (IERC20Upgradeable);

    function tokenY() external view returns (IERC20Upgradeable);

    function inThePosition() external view returns (bool);

    function mintStarted() external view returns (bool);

    function factory() external view returns (address);

    function managingFee() external view returns (uint16);

    function performanceFee() external view returns (uint16);

    function managerBalanceX() external view returns (uint256);

    function managerBalanceY() external view returns (uint256);

    function userVaults(address user) external view returns (DataTypes.UserVault memory);

    function users(uint256 idx) external view returns (address);

    function initialize(address _pool, int24 _tickSpacing, bytes memory data) external;

    function updatePoints(int24 _leftPoint, int24 _rightPoint) external;

    function mintTo(address to, uint256 amount) external;

    function mint(uint256 mintAmount) external returns (uint256 amount0, uint256 amount1);

    function burn(uint256 burnAmount) external returns (uint256 amount0, uint256 amount1);

    function burnFrom(address from, uint256 burnAmount) external;

    function removeLiquidity() external;

    function swap(
        bool zeroForOne,
        uint128 swapAmount,
        int24 pointLimit
    ) external returns (uint256 amount0, uint256 amount1);

    function addLiquidity(
        int24 newLowerTick,
        int24 newUpperTick,
        uint128 amount0,
        uint128 amount1
    ) external returns (uint256 remainingAmount0, uint256 remainingAmount1);

    function collectManager() external;

    function updateFees(uint16 newManagingFee, uint16 newPerformanceFee) external;

    function getMintAmounts(
        uint128 amount0Max,
        uint128 amount1Max
    ) external view returns (uint256 amount0, uint256 amount1, uint256 mintAmount);

    function getUnderlyingBalances()
        external
        view
        returns (uint256 amount0Current, uint256 amount1Current);

    function getUnderlyingBalancesByShare(
        uint256 shares
    ) external view returns (uint256 amountX, uint256 amountY);

    //
    //    function getUnderlyingBalancesAtPrice(
    //        uint160 sqrtRatioX96
    //    ) external view returns (uint256 amount0Current, uint256 amount1Current);

    function getCurrentFees() external view returns (uint256 fee0, uint256 fee1);

    function getPositionID() external view returns (bytes32 positionID);

    function getUserVaults(
        uint256 fromIdx,
        uint256 toIdx
    ) external view returns (DataTypes.UserVaultInfo[] memory);
}
