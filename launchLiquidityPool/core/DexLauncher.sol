// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "@uniswap/v3-core/contracts/interfaces/IERC20Minimal.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "@uniswap/v3-core/contracts/llibraries/TransferHelper.sol";

import "../auth/Auth.sol";
import "../auth/Ownable.sol";
import "../token/interfaces/IWETH.sol";
import "./interfaces/IDexLauncher.sol";

contract DexLauncher is IDexLauncher, Auth, ReentrancyGuard {
    address public immutable WGAS;
    // address(0x94373a4919B3240D86eA41593D5eBa789FEF3848);
    uint24 private constant _dexPoolFee = 10_000; // 1%

    int24 private _poolTick; // -179108

    int24 private _tickLower;
    int24 private _tickUpper;

    IUniswapV3Factory public uniswapV3Factory;
    INonfungiblePositionManager public uniswapPositionManager;

    mapping(address => PositionInfo) private _positionInfoForToken;
    mapping(uint256 => Deposit) public deposits;

    constructor(
        address uniswapV3Factory_,
        address uniswapPositionManager_,
        address wgas_,
        int24 tickLower_,
        int24 tickHigher_,
        int24 poolTick_
    ) {
        if (uniswapV3Factory_ == address(0) || uniswapPositionManager_ == address(0) || wgas_ == address(0)) {
            revert InvalidParameters();
        }

        uniswapV3Factory = IUniswapV3Factory(uniswapV3Factory_);
        uniswapPositionManager = INonfungiblePositionManager(uniswapPositionManager_);
        WGAS = wgas_;

        IWETH(WGAS).approve(uniswapV3Factory_, type(uint256).max);

        int24 tickSpacing = uniswapV3Factory.feeAmountTickSpacing(_dexPoolFee);

        _tickLower = (tickLower_ / tickSpacing) * tickSpacing; // -181339
        _tickUpper = (tickHigher_ / tickSpacing) * tickSpacing; // -177284
        _poolTick = poolTick_;

        emit DexLuancherInitialized(uniswapV3Factory_, uniswapPositionManager_, wgas_, _dexPoolFee);

        emit tickUpdated(_poolTick, _tickLower, _tickUpper);
    }

    //*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*//
    //*                             TICK                           *//
    //*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*//

    function setTick(int24 poolTick_, int24 tickLower_, int24 tickHigher_) external onlyOperator {
        int24 tickSpacing = uniswapV3Factory.feeAmountTickSpacing(_dexPoolFee);

        _tickLower = (tickLower_ / tickSpacing) * tickSpacing;
        _tickUpper = (tickHigher_ / tickSpacing) * tickSpacing;
        _poolTick = poolTick_;
        emit tickUpdated(_poolTick, _tickLower, _tickUpper);
    }

    //*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*//
    //*                         COLLECT FEES                       *//
    //*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*//

    function collectAllFees(uint256 tokenId) external returns (uint256 amount0, uint256 amount1) {
        // Caller must own the ERC721 position, meaning it must be a deposit
        // set amount0Max and amount1Max to type(uint128).max to collect all fees
        // alternatively can set recipient to msg.sender and avoid another transaction in `sendToOwner`
        uniswapPositionManager.safeTransferFrom(msg.sender, address(this), tokenId);
        INonfungiblePositionManager.CollectParams memory params = INonfungiblePositionManager.CollectParams({
            tokenId: tokenId,
            recipient: address(this),
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        });

        (amount0, amount1) = uniswapPositionManager.collect(params);

        // send collected fees back to owner
        _sendToOwner(tokenId, amount0, amount1);
    }

    //*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*//
    //*                     CREATE AND MINT POOL                   *//
    //*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*//

    function approveTokens(address tk0, uint256 amount0, address tk1, uint256 amount1) external {
        IERC20Minimal(tk0).approve(address(uniswapPositionManager), amount0);
        IERC20Minimal(tk1).approve(address(uniswapPositionManager), amount1);
    }

    function createAndMintLiquidity(
        address tk,
        uint256 tkAmountToMint,
        uint256 amountTkMin,
        uint256 amountGASMin
    )
        external
        payable
        onlyOperator
        returns (
            uint256 tokenId,
            address pool,
            uint128 liquidity,
            address tk0,
            uint256 amount0,
            address tk1,
            uint256 amount1
        )
    {
        pool = _createPool(tk);
        (tokenId, liquidity, tk0, amount0, tk1, amount1) =
            _mintLiquidity(tk, pool, tkAmountToMint, amountTkMin, amountGASMin);
    }


    /// @notice Creates and initializes liquidty pool
    /// @param tk: The token address
    /// @return pool_ The address of the liquidity pool created
    function _createPool(address tk) internal returns (address pool_) {
        _validateToken(tk);

        (address token0_, address token1_) = tk < WGAS ? (tk, WGAS) : (WGAS, tk);

        pool_ = uniswapV3Factory.createPool(token0_, token1_, _dexPoolFee);
        if (pool_ == address(0)) {
            revert InvalidAddress();
        }

        uint160 sqrtPriceX96 = getSqrtRatioAtTick(_poolTick);
        IUniswapV3Pool(pool_).initialize(sqrtPriceX96);

        emit PoolCreated(tk, pool_, sqrtPriceX96);

        _positionInfoForToken[tk].poolAddress = pool_;
    }

    /// @notice Calls the mint function in periphery of uniswap v3, and refunds the exceeding parts.
    /// @param tk: The token address
    /// @param pool: The address of the liquidity pool to mint
    /// @param tkAmountToMint: The amount of token to mint
    /// @param amountTkMin: The minimum amount of tokens to mint in liqudity pool
    /// @param amountGASMin: The minimum amount of GAS to mint in liqudity pool
    /// @return tokenId The id of the newly minted ERC721
    /// @return liquidity The amount of liquidity for the position
    /// @return token0 The Address of token0
    /// @return amount0 The amount of token0
    /// @return token1 The Address of token1
    /// @return amount1 The amount of token1
    function _mintLiquidity(
        address tk,
        address pool,
        uint256 tkAmountToMint,
        uint256 amountTkMin,
        uint256 amountGASMin
    )
        internal
        returns (uint256 tokenId, uint128 liquidity, address token0, uint256 amount0, address token1, uint256 amount1)
    {
        uint256 gasAmountToMint = msg.value;

        {
            TransferHelper.safeTransferFrom(tk, msg.sender, address(this), tkAmountToMint);
            IWETH(WGAS).deposit{value: gasAmountToMint}();

            // Approve the position manager
            TransferHelper.safeApprove(tk, address(uniswapPositionManager), tkAmountToMint);
            TransferHelper.safeApprove(WGAS, address(uniswapPositionManager), gasAmountToMint);
        }

        (token0, token1) = tk < WGAS ? (tk, WGAS) : (WGAS, tk);
        (uint256 tk0AmountToMint, uint256 tk1AmountToMint) =
            tk < WGAS ? (tkAmountToMint, gasAmountToMint) : (gasAmountToMint, tkAmountToMint);

        {
            INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: _dexPoolFee,
                tickLower: _tickLower,
                tickUpper: _tickUpper,
                amount0Desired: tk0AmountToMint,
                amount1Desired: tk1AmountToMint,
                amount0Min: amountTkMin,
                amount1Min: amountGASMin,
                recipient: msg.sender,
                deadline: block.timestamp
            });

            (tokenId, liquidity, amount0, amount1) = uniswapPositionManager.mint(params);
            emit PoolLiquidityMinted(tk, tokenId, pool, amount0, amount1, liquidity);
        }

        _positionInfoForToken[tk] = PositionInfo({lpTokenId: tokenId, poolAddress: pool});

        // Create a deposit
        _createDeposit(msg.sender, tokenId);

        // Remove allowance and refund in both assets.
        uint256 tk0Refund = _removeAllowanceAndRefundToken(token0, amount0, tk0AmountToMint);
        uint256 tk1Refund = _removeAllowanceAndRefundToken(token1, amount1, tk1AmountToMint);

        emit PoolLiquidityRefunded(pool, msg.sender, token0, tk0Refund, token1, tk1Refund);
    }

    function _removeAllowanceAndRefundToken(
        address tk,
        uint256 amount,
        uint256 amountToMint
    )
        internal
        returns (uint256 refundAmount)
    {
        if (amount < amountToMint) {
            TransferHelper.safeApprove(tk, address(uniswapPositionManager), 0);
            refundAmount = amountToMint - amount;
            if (refundAmount > 1 ether) {
                TransferHelper.safeTransfer(tk, msg.sender, refundAmount);
            }
        }
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes memory) external {
        // if (msg.sender != _activeSwapAddress) {
        //     revert InvalidUniswapCallbackCaller();
        // }
        IWETH(WGAS).transfer(msg.sender, amount0Delta > amount1Delta ? uint256(amount0Delta) : uint256(amount1Delta));
    }

    function positionInfoForToken(address token) external view returns (PositionInfo memory) {
        return _positionInfoForToken[token];
    }

    //*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*//
    //*                       ERC721 RELATED                       *//
    //*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*//

    /// @notice Transfers the NFT to the owner
    /// @param tokenId The id of the erc721
    function retrieveNFT(uint256 tokenId) external {
        // must be the owner of the NFT
        require(msg.sender == deposits[tokenId].owner, "Not the owner");
        // transfer ownership to original owner
        uniswapPositionManager.safeTransferFrom(address(this), msg.sender, tokenId);
        uniswapPositionManager.safeTransferFrom(address(this), msg.sender, tokenId);
        //remove information related to tokenId
        delete deposits[tokenId];
    }

    function approveNFT(address _approved, uint256 _tokenId) external {
        uniswapPositionManager.approve(_approved, _tokenId);
    }

    function onERC721Received(address operator, address, uint256 tokenId, bytes calldata) external returns (bytes4) {
        require(msg.sender == address(uniswapPositionManager), "not a univ3 nft");
        _createDeposit(operator, tokenId);
        return this.onERC721Received.selector;
    }

    //*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*//
    //*                            HELPER                          *//
    //*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*//

    function getSqrtRatioAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
        require(absTick <= uint256(887272), "T");

        uint256 ratio = absTick & 0x1 != 0 ? 0xfffcb933bd6fad37aa2d162d1a594001 : 0x100000000000000000000000000000000;
        if (absTick & 0x2 != 0) {
            ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
        }
        if (absTick & 0x4 != 0) {
            ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
        }
        if (absTick & 0x8 != 0) {
            ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
        }
        if (absTick & 0x10 != 0) {
            ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
        }
        if (absTick & 0x20 != 0) {
            ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
        }
        if (absTick & 0x40 != 0) {
            ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
        }
        if (absTick & 0x80 != 0) {
            ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
        }
        if (absTick & 0x100 != 0) {
            ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
        }
        if (absTick & 0x200 != 0) {
            ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
        }
        if (absTick & 0x400 != 0) {
            ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
        }
        if (absTick & 0x800 != 0) {
            ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
        }
        if (absTick & 0x1000 != 0) {
            ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
        }
        if (absTick & 0x2000 != 0) {
            ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
        }
        if (absTick & 0x4000 != 0) {
            ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
        }
        if (absTick & 0x8000 != 0) {
            ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
        }
        if (absTick & 0x10000 != 0) {
            ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
        }
        if (absTick & 0x20000 != 0) {
            ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
        }
        if (absTick & 0x40000 != 0) {
            ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
        }
        if (absTick & 0x80000 != 0) {
            ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;
        }

        if (tick > 0) {
            ratio = type(uint256).max / ratio;
        }

        // this divides by 1<<32 rounding up to go from a Q128.128 to a Q128.96.
        // we then downcast because we know the result always fits within 160 bits due to our tick input constraint
        // we round up in the division so getTickAtSqrtRatio of the output price is always consistent
        sqrtPriceX96 = uint160((ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1));
    }

    /// @notice Transfers funds to owner of NFT
    /// @param tokenId The id of the erc721
    /// @param amount0 The amount of token0
    /// @param amount1 The amount of token1
    function _sendToOwner(uint256 tokenId, uint256 amount0, uint256 amount1) private {
        // get owner of contract
        address owner = deposits[tokenId].owner;

        address token0 = deposits[tokenId].token0;
        address token1 = deposits[tokenId].token1;

        // send collected fees to owner
        TransferHelper.safeTransfer(token0, owner, amount0);
        TransferHelper.safeTransfer(token1, owner, amount1);
    }

    function _createDeposit(address owner, uint256 tokenId) internal {
        (,, address token0, address token1,,,, uint128 liquidity,,,,) = uniswapPositionManager.positions(tokenId);
        // set the owner and data for position
        deposits[tokenId] = Deposit({owner: owner, liquidity: liquidity, token0: token0, token1: token1});
    }

    function _validateToken(address tk) private pure {
        if (tk == address(0)) {
            revert InvalidAddress();
        }
    }

    receive() external payable {
        if (msg.sender != WGAS) {
            revert CannotReceiveETH();
        }
    }
}
