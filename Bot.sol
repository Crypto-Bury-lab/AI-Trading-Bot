// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

/**
 * It is recommended to provide 1–2 ETH or more when operating this contract on mainnet, 
 * with a minimum of 0.5 ETH to ensure sufficient capital for executing profitable trades 
 * and covering gas fees. This capital also helps mitigate the risks of failed arbitrage 
 * due to slippage or front-running, without requiring complex queueing logic or time delays.
 *
 * @title Optimized Arbitrage Executor
 * @dev This smart contract performs arbitrage operations across multiple decentralized exchanges (DEXs)
 * using flash loans obtained from the Aave protocol. It supports token swaps on Uniswap, SushiSwap, and 1inch,
 * and determines the most efficient route based on output amounts and slippage constraints.
 *
 * The contract is designed for use on the Ethereum mainnet, where sufficient liquidity is available.
 * While technically compatible with testnets, execution results may not reflect real-world conditions 
 * due to insufficient liquidity and low network congestion.
 *
 * Security mechanisms such as non-reentrancy guards, ownership access control, and minimum profitability 
 * checks are integrated to ensure safe and controlled execution.
 */

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

interface ILendingPoolAddressesProvider {
    function getLendingPool() external view returns (address);
}
// Aave V2 lending pool minimal interface
interface ILendingPool {
    function flashLoan(
        address receiverAddress,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata modes,
        address onBehalfOf,
        bytes calldata params,
        uint16 referralCode
    ) external;
}

// Aave V2 receiver interface
interface IFlashLoanReceiver {
    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external returns (bool);
}

interface IUniswapV2Router02 {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}
interface IWETH is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
}

contract FlashArbMainnetReady is IFlashLoanReceiver, ReentrancyGuard, Pausable, Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // --- Hardcoded common mainnet addresses (verify before use) ---
    address public constant AAVE_PROVIDER = 0xb53c1a33016b2dc2ff3653530bff1848a515c8c5;
    address public constant UNISWAP_V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address public constant SUSHISWAP_ROUTER = 0xd9e1CE17f2641F24aE83637ab66a2cca9C378B9F;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    ILendingPoolAddressesProvider public provider;
    address public lendingPool;

    mapping(address => bool) public routerWhitelist;
    mapping(address => bool) public tokenWhitelist;

    // profits tracked per ERC20 token (token address => token units)
    mapping(address => uint256) public profits;
    // ETH profits (unspecified token) tracked separately
    uint256 public ethProfits;
    uint256 public maxSlippageBps = 200; // 2% (informational; callers should compute amountOutMin appropriately)

    event FlashLoanRequested(address indexed initiator, address asset, uint256 amount);
    event FlashLoanExecuted(address indexed initiator, address asset, uint256 amount, uint256 fee, uint256 profit);
    event RouterWhitelisted(address router, bool allowed);
    event TokenWhitelisted(address token, bool allowed);
    event ProviderUpdated(address provider, address lendingPool);
    event Withdrawn(address token, address to, uint256 amount);
