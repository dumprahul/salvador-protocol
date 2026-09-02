// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

interface IFleetSettlement {
    event BundledBidSettled(uint256 totalBid, uint256 poolCount);

    /// @notice Bundle salvage corrections across `pools` into one bid paid in `bidToken`, splitting
    /// `totalBid` across each pool's general average fund in proportion to that pool's own,
    /// independently measured gap (never a caller-supplied split). All deposits succeed atomically
    /// or the whole call reverts.
    /// @dev `bidToken` must match every bundled pool's registered quote token — bundling pools with
    /// different quote assets needs a conversion step this contract does not perform; the
    /// whitepaper's own worked example bundles same-quote-asset pools (ETH/USDC, ETH/USDT), which
    /// this restriction still covers as long as they're both registered against a shared
    /// settlement currency.
    function submitBundledBid(PoolId[] calldata pools, uint256 totalBid, IERC20 bidToken) external;
}
