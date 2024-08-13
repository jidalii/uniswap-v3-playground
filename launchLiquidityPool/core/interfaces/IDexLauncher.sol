// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IDexLauncher {
    struct PositionInfo {
        uint256 lpTokenId;
        address poolAddress;
    }

    /// @notice Represents the deposit of an NFT
    struct Deposit {
        address owner;
        uint128 liquidity;
        address token0;
        address token1;
    }

    event DexLuancherInitialized(
        address uniswapV3Factory, address uniswapPositionManager, address wgas, uint24 dexPoolFee
    );

    event tickUpdated(int24 poolTick, int24 tickLower, int24 tickHigher);

    event PoolCreated(address tk, address pool, uint160 sqrtPriceX96);

    event PoolLiquidityMinted(
        address tk, uint256 tokenId, address poolAddress, uint256 tkAmount, uint256 gasAmount, uint256 liquidity
    );

    event PoolLiquidityRefunded(
        address pool, address to, address token0, uint256 refundAmount0, address token1, uint256 refundAmount1
    );

    error CannotReceiveETH();
    error InvalidAddress();
    error InvalidParameters();
    error InvalidUniswapCallbackCaller();

    function approveTokens(address tk0, uint256 amount0, address tk1, uint256 amount1) external;

    // function mintLiquidity(
    //     address tk,
    //     uint256 tkAmount,
    //     uint256 amount0Min,
    //     uint256 amount1Min
    // )
    //     external
    //     payable
    //     returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes memory) external;

    function positionInfoForToken(address token) external view returns (PositionInfo memory);

    // function createPool(address tk) external returns (address);
}
