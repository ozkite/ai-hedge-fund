// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

// Uniswap V3 Interfaces (Base uses same as Ethereum)
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

contract BaseHedgeFund is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // === TOKENS ===
    address public constant WETH = 0x4200000000000000000000000000000000000006;
    address public constant WBTC = 0x68f180fcCe6836688e9084f035309E29Bf0A2095;

    // === UNISWAP V3 ROUTER (Base) ===
    ISwapRouter public constant swapRouter = ISwapRouter(0x4752ba5DBc23f44D87826276F97F279a628dd330);

    // === MANAGER ROLE ===
    address public manager;
    address public treasury; // For fees

    // === FEE ===
    uint256 public performanceFee = 10; // 10% of profits (in basis points, 10 = 0.1%)
    uint256 public constant FEE_DENOMINATOR = 1000;

    // === VAULT STATE ===
    struct Position {
        uint256 ethBalance;
        uint256 wbtcBalance;
        uint256 lastValue;
    }

    mapping(address => Position) public positions;
    uint256 public totalValueLocked;

    // === EVENTS ===
    event Deposit(address indexed user, uint256 ethAmount, uint256 wbtcAmount);
    event Withdraw(address indexed user, uint256 ethAmount, uint256 wbtcAmount);
    event Rebalance(uint256 ethAmount, uint256 wbtcAmount, uint256 value);
    event Swap(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);
    event PerformanceFeeCollected(uint256 fee);

    // === MODIFIERS ===
    modifier onlyManager() {
        require(msg.sender == manager, "Not manager");
        _;
    }

    // === CONSTRUCTOR ===
    constructor(address _treasury) {
        manager = msg.sender;
        treasury = _treasury;
    }

    // === RECEIVE ETH ===
    receive() external payable {}

    // === DEPOSIT ETH or WBTC ===
    function depositETH() external payable nonReentrant {
        require(msg.value > 0, "No ETH sent");

        Position storage pos = positions[msg.sender];
        pos.ethBalance += msg.value;

        uint256 total = _totalValue(pos.ethBalance, pos.wbtcBalance);
        if (pos.lastValue == 0) {
            pos.lastValue = total;
        }

        totalValueLocked += msg.value;

        emit Deposit(msg.sender, msg.value, 0);
    }

    function depositWBTC(uint256 amount) external nonReentrant {
        require(amount > 0, "No WBTC sent");
        IERC20(WBTC).safeTransferFrom(msg.sender, address(this), amount);

        Position storage pos = positions[msg.sender];
        pos.wbtcBalance += amount;

        uint256 total = _totalValue(pos.ethBalance, pos.wbtcBalance);
        if (pos.lastValue == 0) {
            pos.lastValue = total;
        }

        totalValueLocked += _wbtcToEth(amount);

        emit Deposit(msg.sender, 0, amount);
    }

    // === WITHDRAW PROPORTIONAL SHARES ===
    function withdraw() external nonReentrant {
        Position storage pos = positions[msg.sender];
        require(pos.ethBalance > 0 || pos.wbtcBalance > 0, "No balance");

        uint256 ethAmount = pos.ethBalance;
        uint256 wbtcAmount = pos.wbtcBalance;

        // Pay out
        if (ethAmount > 0) {
            payable(msg.sender).transfer(ethAmount);
        }
        if (wbtcAmount > 0) {
            IERC20(WBTC).safeTransfer(msg.sender, wbtcAmount);
        }

        // Collect performance fee on profit
        uint256 currentValue = _totalValue(ethAmount, wbtcAmount);
        if (currentValue > pos.lastValue) {
            uint256 profit = currentValue - pos.lastValue;
            uint256 fee = (profit * performanceFee) / FEE_DENOMINATOR;
            if (fee > 0) {
                payable(treasury).transfer(fee);
                emit PerformanceFeeCollected(fee);
            }
        }

        totalValueLocked -= _totalValue(ethAmount, wbtcBalance);
        delete positions[msg.sender];

        emit Withdraw(msg.sender, ethAmount, wbtcAmount);
    }

    // === MANAGER: REBALANCE PORTFOLIO ===
    function rebalance(
        uint256 ethToSwap,
        uint24 poolFee
    ) external onlyManager {
        require(address(this).balance >= ethToSwap, "Insufficient ETH");

        // Swap ETH → WBTC
        _swapETHForWBTC(ethToSwap, poolFee);

        emit Rebalance(address(this).balance, IERC20(WBTC).balanceOf(address(this)), totalValueLocked);
    }

    // === INTERNAL: SWAP ETH → WBTC ===
    function _swapETHForWBTC(uint256 amount, uint24 poolFee) internal {
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: WETH,
            tokenOut: WBTC,
            fee: poolFee, // 0.05%, 0.3%, or 1%
            recipient: address(this),
            deadline: block.timestamp + 15 minutes,
            amountIn: amount,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        uint256 amountOut = swapRouter.exactInputSingle{value: amount}(params);
        emit Swap(WETH, WBTC, amount, amountOut);
    }

    // === INTERNAL: TOTAL VALUE IN ETH ===
    function _totalValue(uint256 eth, uint256 wbtc) internal view returns (uint256) {
        return eth + _wbtcToEth(wbtc);
    }

    function _wbtcToEth(uint256 wbtcAmount) internal view returns (uint256) {
        // Simplified: 1 WBTC ≈ 15 ETH (adjust with oracle later)
        return (wbtcAmount * 15) / 1e8; // WBTC has 8 decimals
    }

    // === SET MANAGER ===
    function setManager(address newManager) external onlyOwner {
        manager = newManager;
    }

    // === EMERGENCY WITHDRAW ===
    function emergencyWithdraw(address token) external onlyOwner {
        uint256 balance = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(owner(), balance);
    }

    // === GET USER VALUE ===
    function getUserValue(address user) external view returns (uint256) {
        Position memory pos = positions[user];
        return _totalValue(pos.ethBalance, pos.wbtcBalance);
    }
}
