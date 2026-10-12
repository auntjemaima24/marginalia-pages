// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The companion implementations the hook clones (EIP-1167) in its constructor. They were deployed
/// first, as the contracts-only IMD launch #1240 on Ethereum mainnet (tx
/// 0x93a1b0cce64e04d4bd7edd7b5fb6e6268b1fd5ab68fb5b990e66c56e972d71a3, block 26163341, source commit
/// 43087f6e of the launch repository). The clones are immutable proxies; each is initialised once by the hook
/// in the launch transaction. Tests etch rehearsal code at these same addresses.
library MarginaliaImpls {
    address internal constant ROUTER_IMPL = 0x365CcB3cfBC430600485234F56FD5ECb23fd70D1;
    address internal constant JUDGE_IMPL = 0xC93460730a79a22282f063A0c6BA5E340Ac372b4;
    address internal constant TREASURY_IMPL = 0xe2086012f5F9CC7cAECDBC70dE392e263aAe8481;
    /// @dev Stateless price reads, the settlement rule and score arithmetic (no clone needed: it holds nothing).
    address internal constant PRICER = 0xEaff9B262341A0cB05579227e662BFE768A71cfb;
}
