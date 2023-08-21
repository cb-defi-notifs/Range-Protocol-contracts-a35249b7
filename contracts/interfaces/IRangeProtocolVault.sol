//SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import {IiZiSwapCallback, IiZiSwapMintCallback} from "../iZiSwap/interfaces/IiZiSwapCallback.sol";

interface IRangeProtocolVault is IiZiSwapCallback, IiZiSwapMintCallback {
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

    function initialize(address _pool, int24 _tickSpacing, bytes memory data) external;

    function updatePoints(int24 _leftPoint, int24 _rightPoint) external;

    function mint(uint256 mintAmount) external returns (uint256 amount0, uint256 amount1);

    function burn(uint256 burnAmount) external returns (uint256 amount0, uint256 amount1);

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

    function getUnderlyingBalancesAtPrice(
        uint160 sqrtRatioX96
    ) external view returns (uint256 amount0Current, uint256 amount1Current);

    function getCurrentFees() external view returns (uint256 fee0, uint256 fee1);

    function getPositionID() external view returns (bytes32 positionID);

    struct UserVaultInfo {
        address user;
        uint256 token0;
        uint256 token1;
    }

    function getUserVaults(
        uint256 fromIdx,
        uint256 toIdx
    ) external view returns (UserVaultInfo[] memory);
}
