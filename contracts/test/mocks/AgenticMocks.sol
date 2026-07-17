// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BasketToken2} from "../../src/BasketToken2.sol";

/// @dev 6-decimals USDG stand-in with open mint.
contract MockUSDG is ERC20 {
    constructor() ERC20("USD Global", "USDG") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Settable Chainlink aggregator (8 decimals).
contract MockFeed {
    int256 public answer;
    uint256 public updatedAt;

    constructor(int256 answer_) {
        answer = answer_;
        updatedAt = block.timestamp;
    }

    function set(int256 answer_, uint256 updatedAt_) external {
        answer = answer_;
        updatedAt = updatedAt_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

/// @dev Honest RFQ maker: settles `swap(tokenIn, amountIn, tokenOut, amountOut)`
///      by pulling exactly amountIn from the caller and paying amountOut from
///      its own inventory. The test funds its inventory directly.
contract MockMaker {
    function swap(address tokenIn, uint256 amountIn, address tokenOut, uint256 amountOut) external {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).transfer(msg.sender, amountOut);
    }
}

/// @dev Pulls only part of the approval — must trip LegUnderfilled.
contract PartialPullMaker {
    function swap(address tokenIn, uint256 amountIn, address tokenOut, uint256 amountOut) external {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn / 2);
        IERC20(tokenOut).transfer(msg.sender, amountOut);
    }
}

/// @dev Takes the full input and pays nothing back.
contract ThiefMaker {
    function swap(address tokenIn, uint256 amountIn, address, uint256) external {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
    }
}

/// @dev Tries to re-enter the basket (redeem or another rebalance) while
///      settling — the shared reentrancy guard must kill the inner call.
contract ReentrantMaker {
    enum Mode {
        REDEEM,
        REBALANCE
    }

    Mode public mode;

    function setMode(Mode m) external {
        mode = m;
    }

    function swap(address tokenIn, uint256 amountIn, address tokenOut, uint256 amountOut) external {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        if (mode == Mode.REDEEM) {
            BasketToken2(msg.sender).redeem(1, address(this));
        } else {
            BasketToken2(msg.sender).rebalance(new BasketToken2.TradeLeg[](0), new address[](0));
        }
        IERC20(tokenOut).transfer(msg.sender, amountOut);
    }
}
