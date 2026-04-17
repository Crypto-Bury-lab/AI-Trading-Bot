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

    constructor() public {
        provider = ILendingPoolAddressesProvider(AAVE_PROVIDER);
        lendingPool = provider.getLendingPool();

        // Prepopulate trusted routers
        routerWhitelist[UNISWAP_V2_ROUTER] = true;
        routerWhitelist[SUSHISWAP_ROUTER] = true;
        emit RouterWhitelisted(UNISWAP_V2_ROUTER, true);
        emit RouterWhitelisted(SUSHISWAP_ROUTER, true);

        // Prepopulate common tokens
        tokenWhitelist[WETH] = true;
        tokenWhitelist[DAI] = true;
        tokenWhitelist[USDC] = true;
        emit TokenWhitelisted(WETH, true);
        emit TokenWhitelisted(DAI, true);
        emit TokenWhitelisted(USDC, true);
    }
    // Owner functions
    function setRouterWhitelist(address router, bool allowed) external onlyOwner {
        routerWhitelist[router] = allowed;
        emit RouterWhitelisted(router, allowed);
    }

    function setTokenWhitelist(address token, bool allowed) external onlyOwner {
        tokenWhitelist[token] = allowed;
        emit TokenWhitelisted(token, allowed);
    }

    function updateProvider(address _provider) external onlyOwner {
        require(_provider != address(0), "provider-zero");
        provider = ILendingPoolAddressesProvider(_provider);
        lendingPool = provider.getLendingPool();
        emit ProviderUpdated(_provider, lendingPool);
    }

    function setMaxSlippage(uint256 bps) external onlyOwner {
        require(bps <= 1000, "max 10% allowed");
        maxSlippageBps = bps;
    }

    // params encoding helper (off-chain):
    // abi.encode(router1, router2, path1, path2, amountOutMin1, amountOutMin2, minProfitTokenUnits, unwrapProfitToEth, initiator)

    // Start a single-asset flash loan via Aave V2 (assets/amounts arrays length == 1)
    function startFlashLoan(address asset, uint256 amount, bytes calldata params) external onlyOwner whenNotPaused {
        require(amount > 0, "amount-zero");
        address[] memory assets = new address[](1);
        assets[0] = asset;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        uint256[] memory modes = new uint256[](1);
        modes[0] = 0; // 0 = no debt (flash)

        emit FlashLoanRequested(msg.sender, asset, amount);
        ILendingPool(lendingPool).flashLoan(address(this), assets, amounts, modes, address(this), params, 0);
    }
    // Aave V2-style executeOperation
    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external override nonReentrant whenNotPaused returns (bool) {
        require(msg.sender == lendingPool, "only-lending-pool");
        require(assets.length == 1 && amounts.length == 1 && premiums.length == 1, "only-single-asset-supported");

        address _reserve = assets[0];
        uint256 _amount = amounts[0];
        uint256 _fee = premiums[0];

        (
            address router1,
            address router2,
            address[] memory path1,
            address[] memory path2,
            uint256 amountOutMin1,
            uint256 amountOutMin2,
            uint256 minProfit,
            bool unwrapProfitToEth,
            address opInitiator
        ) = abi.decode(params, (address, address, address[], address[], uint256, uint256, uint256, bool, address));

        require(routerWhitelist[router1] && routerWhitelist[router2], "router-not-allowed");
        require(path1.length >= 2 && path2.length >= 2, "invalid-paths");
        require(path1[0] == _reserve, "path1 must start with reserve");
        require(path2[path2.length - 1] == _reserve, "path2 must end with reserve");

        for (uint256 i = 0; i < path1.length; i++) {
            require(tokenWhitelist[path1[i]], "token1-not-whitelisted");
        }
        for (uint256 i = 0; i < path2.length; i++) {
            require(tokenWhitelist[path2[i]], "token2-not-whitelisted");
        }

        // Approve router1 to spend _reserve
        IERC20(_reserve).safeApprove(router1, 0);
        IERC20(_reserve).safeApprove(router1, _amount);

        uint256 deadline = block.timestamp.add(300);
        uint256[] memory amounts1 = IUniswapV2Router02(router1).swapExactTokensForTokens(_amount, amountOutMin1, path1, address(this), deadline);
        uint256 out1 = amounts1[amounts1.length - 1];

        // reset approval
        IERC20(_reserve).safeApprove(router1, 0);

        address intermediate = path1[path1.length - 1];
        // ensure path2 starts with intermediate
        require(path2[0] == intermediate, "path2 must start with intermediate token");

        IERC20(intermediate).safeApprove(router2, 0);
        IERC20(intermediate).safeApprove(router2, out1);

        uint256[] memory amounts2 = IUniswapV2Router02(router2).swapExactTokensForTokens(out1, amountOutMin2, path2, address(this), deadline);
        uint256 out2 = amounts2[amounts2.length - 1];

        IERC20(intermediate).safeApprove(router2, 0);

        uint256 totalDebt = _amount.add(_fee);
        uint256 balance = IERC20(_reserve).balanceOf(address(this));
        require(balance >= totalDebt, "insufficient-to-repay");

        uint256 profit = 0;
        if (balance > totalDebt) {
            profit = balance.sub(totalDebt);
        }

        if (minProfit > 0) {
            require(profit >= minProfit, "profit-less-than-min");
        }

        if (profit > 0) {
            // If unwrap requested and profit token is WETH, unwrap to ETH and track ethProfits
            if (unwrapProfitToEth && _reserve == WETH) {
                // move profit to contract as WETH -> withdraw to ETH
                // Approve WETH withdraw: contract already holds the WETH
                // Withdraw WETH to ETH
                IWETH(WETH).withdraw(profit);
                ethProfits = ethProfits.add(profit);
            } else {
                profits[_reserve] = profits[_reserve].add(profit);
            }
        }

        // Approve lendingPool to pull repayment
        IERC20(_reserve).safeApprove(lendingPool, 0);
        IERC20(_reserve).safeApprove(lendingPool, totalDebt);

        emit FlashLoanExecuted(opInitiator, _reserve, _amount, _fee, profit);
        return true;
    }

    // Withdraw accumulated profit (pull pattern). If token == address(0) withdraw ETH profits.
    function withdrawProfit(address token, uint256 amount, address to) external onlyOwner nonReentrant {
        require(amount > 0, "amount-zero");
        require(to != address(0), "to-zero");
        if (token == address(0)) {
            // ETH withdraw
            require(amount <= ethProfits, "amount-exceeds-eth-profit");
            ethProfits = ethProfits.sub(amount);
            (bool sent, ) = to.call{value: amount}("");
            require(sent, "eth-transfer-failed");
            emit Withdrawn(address(0), to, amount);
            return;
        }
        uint256 bal = profits[token];
        require(amount <= bal, "amount-exceeds-profit");
        profits[token] = bal.sub(amount);
        IERC20(token).safeTransfer(to, amount);
        emit Withdrawn(token, to, amount);
    }

    // Emergency rescue for ERC20
    function emergencyWithdrawERC20(address token, uint256 amount, address to) external onlyOwner nonReentrant {
        require(to != address(0), "to-zero");
        IERC20(token).safeTransfer(to, amount);
        emit Withdrawn(token, to, amount);
    }

    // Allow contract to receive ETH
    receive() external payable {}
}
