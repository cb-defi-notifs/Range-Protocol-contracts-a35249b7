//SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {SafeERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {OwnableUpgradeable} from "./access/OwnableUpgradeable.sol";
import {RangeProtocolVaultStorage} from "./RangeProtocolVaultStorage.sol";
import {IiZiSwapPool} from "./iZiSwap/interfaces/IiZiSwapPool.sol";
import {VaultLib} from "./libraries/VaultLib.sol";
import {VaultErrors} from "./errors/VaultErrors.sol";

contract RangeProtocolVault is
    Initializable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    OwnableUpgradeable,
    ERC20Upgradeable,
    PausableUpgradeable,
    RangeProtocolVaultStorage
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    modifier onlySelfCall() {
        if (msg.sender != address(this)) revert VaultErrors.OnlySelfCallAllowed();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _pool,
        int24 _pointDelta,
        bytes memory data
    ) external override initializer {
        (address manager, string memory _name, string memory _symbol) = abi.decode(
            data,
            (address, string, string)
        );

        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __Ownable_init();
        __ERC20_init(_name, _symbol);
        __Pausable_init();

        state.pool = IiZiSwapPool(_pool);
        state.tokenX = IERC20Upgradeable(state.pool.tokenX());
        state.tokenY = IERC20Upgradeable(state.pool.tokenY());
        state.pointDelta = _pointDelta;
        state.factory = msg.sender;
        // Managing fee is 0% at the time vault initialization.
        VaultLib.updateFees(state, 0, 250);

        _transferOwnership(manager);
    }

    function updatePoints(int24 leftPoint, int24 rightPoint) external override onlyManager {
        VaultLib.updatePoints(state, leftPoint, rightPoint);
    }

    function pause() external onlyManager {
        _pause();
    }

    function unpause() external onlyManager {
        _unpause();
    }

    function mintDepositCallback(
        uint256 tokenXAmount,
        uint256 tokenYAmount,
        bytes calldata
    ) external override {
        if (msg.sender != address(state.pool)) revert VaultErrors.OnlyPoolAllowed();
        if (tokenXAmount > 0) state.tokenX.safeTransfer(msg.sender, tokenXAmount);
        if (tokenYAmount > 0) state.tokenY.safeTransfer(msg.sender, tokenYAmount);
    }

    function swapX2YCallback(
        uint256 tokenXAmount,
        uint256,
        bytes calldata
    ) external override {
        if (msg.sender != address(state.pool)) revert VaultErrors.OnlyPoolAllowed();
        if (tokenXAmount > 0) state.tokenX.safeTransfer(msg.sender, tokenXAmount);
    }

    function swapY2XCallback(
        uint256,
        uint256 tokenYAmount,
        bytes calldata
    ) external override {
        if (msg.sender != address(state.pool)) revert VaultErrors.OnlyPoolAllowed();
        if (tokenYAmount > 0) state.tokenY.safeTransfer(msg.sender, tokenYAmount);
    }

    function mintTo(address to, uint256 amount) external override onlySelfCall {
        _mint(to, amount);
    }

    function burnFrom(address from, uint256 amount) external override onlySelfCall {
        _burn(from, amount);
    }

    function mint(
        uint256 mintAmount
    ) external override nonReentrant whenNotPaused returns (uint256 amountX, uint256 amountY) {
        return VaultLib.mint(state, mintAmount);
    }

    function burn(
        uint256 burnAmount
    ) external override nonReentrant whenNotPaused returns (uint256 amountX, uint256 amountY) {
        return VaultLib.burn(state, burnAmount);
    }

    function removeLiquidity() external override onlyManager {
        VaultLib.removeLiquidity(state);
    }

    function swap(
        bool zeroForOne,
        uint128 swapAmount,
        int24 pointLimit
    ) external override onlyManager returns (uint256 amountX, uint256 amountY) {
        return VaultLib.swap(state, zeroForOne, swapAmount, pointLimit);
    }

    function addLiquidity(
        int24 newLeftPoint,
        int24 newRightPoint,
        uint128 amountX,
        uint128 amountY
    ) external override onlyManager returns (uint256 remainingamountX, uint256 remainingamountY) {
        return VaultLib.addLiquidity(state, newLeftPoint, newRightPoint, amountX, amountY);
    }

    function pullFeeFromPool() external onlyManager {
        VaultLib.pullFeeFromPool(state);
    }

    function collectManager() external override onlyManager {
        VaultLib.collectManager(state, manager());
    }

    function updateFees(
        uint16 newManagingFee,
        uint16 newPerformanceFee
    ) external override onlyManager {
        VaultLib.updateFees(state, newManagingFee, newPerformanceFee);
    }

    function getMintAmounts(
        uint128 amountXMax,
        uint128 amountYMax
    ) external view override returns (uint256 amountX, uint256 amountY, uint256 mintAmount) {
        return VaultLib.getMintAmounts(state, amountXMax, amountYMax);
    }

    function getCurrentFees() external view override returns (uint256 fee0, uint256 fee1) {
        return VaultLib.getCurrentFees(state);
    }

    function getPositionID() public view override returns (bytes32 positionID) {
        return VaultLib.getPositionID(state);
    }

    function getUnderlyingBalances()
        external
        view
        override
        returns (uint256 amountXCurrent, uint256 amountYCurrent)
    {
        return VaultLib.getUnderlyingBalances(state);
    }

    function getUnderlyingBalancesByShare(
        uint256 shares
    ) external view override returns (uint256 amountX, uint256 amountY) {
        return VaultLib.getUnderlyingBalancesByShare(state, shares);
    }

    function _authorizeUpgrade(address) internal override {
        if (msg.sender != state.factory) revert VaultErrors.OnlyFactoryAllowed();
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override {
        super._beforeTokenTransfer(from, to, amount);
        VaultLib._beforeTokenTransfer(state, from, to, amount);
    }
}
