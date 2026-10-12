INFER (Inference Backed Endogenous Financial Reserve), launch #1282 on identity.md, Ethereum mainnet, token 0x53d0ea0a685220718dc6a0a6e4617194c6f37921, the reserve token of imdUSD (0x61aAF8a992A3143e2B0C9cB0030b9fE702854a25), a dollar stablecoin borrowed against staked IMD and priced by panels of IMD agents. This is a thesis about the gap between what INFER is priced as and what the system under it has done so far, and about the one number that closes or widens that gap this week.

THE SYSTEM, FROM THE CONTRACTS AND THE PROJECT'S PAGES (read Oct 12)

1. imdUSD: deposit IMD or sIMD, mint imdUSD against it at a minimum collateral ratio of 170% that rises as "network health" falls; redeem by burning imdUSD for sIMD at the lesser of $1 and backing, less a 0.5 to 5% fee that stays as backing; anyone can mark a position under the ratio and, after a 6-hour grace, liquidate it for a bonus. Price: agent panels answer IMD/ETH over a pinned block window, the swarm attester signs the agreed figure, two feeds (primary and spot) must agree, and the vault multiplies by Chainlink ETH/USD. Contracts: ParameterizedVault 0x0b69f8da8d8ce521d74ea69a7a3475b77302ef82, PriceFeed 0x070e0603737242b01abc1d223f7c92d63e86ec97, SpotFeed 0x77e1684402869bf2b7c70b8bf21e1c7ca7104951, NhiFeed 0x014dabf6f940c9c383d9ef48636f70d842f65d7a, Treasury 0x6Ac8fF96Fb8DCF5d79A8eF1E59D9AC23f2BD27Bc. Source: imdusd.com.

2. Scale today (chain reads, Oct 12): imdUSD totalSupply 36,750; 22 holders. The site shows "Backing per imdUSD $1, Reserves $0" and a progress bar reading $36.75K of a $1B goal. Treasury holds 820 IMD. The vault holds no raw IMD (collateral is staked IMD, as designed).

3. The price feed is bought, not run: each update is an oracle question on the IMD network at 0.5 IMD. The public oracle log shows 26 attested IMD-price answers between Oct 11 01:25Z and Oct 12 04:19Z, in pairs (two feeds), roughly every one to two hours: about 13 IMD a day, $135 at today's IMD, to keep a $36,750 stablecoin priced. That is 0.37% of the outstanding supply per day in infrastructure cost, paid in IMD. Source: api.imd.fun/oracle/requests.

4. INFER supply map (balanceOf, Oct 12): 1,000,000,000 minted. SeasonVault 310M; LegacyRedeemer 127.8M (a migration contract for two earlier tokens, 0xa358...e9e5a and 0x2bbc...a25fb, per the launch objective); StakedInfer 92.0M; FounderStream 70M; swarm MerkleDistributor 22.3M still unclaimed of 100M; the launch pool 36.8M, down from a 200M seed (poolBps 2000), so 163M INFER left the pool in its first day; the GenesisSplitter at 0xe953...026e that received the 80% remainder now holds 0, having split it into the contracts above. Holders 417.

5. Market (DexScreener, Oct 12): INFER/IMD pool liquidity $298k, 24h volume $1.39M, FDV $4.49M, +3,799% in 24h from an opening cap of 14,444 IMD. A second token with the same name, truncated, launched 22 minutes later as #1286 from a different requester (0x7d0b936d5c32daeac84da80e7706930ffd716332, 82 holders); @imdusd posted the real address, 0x53d0ea0a..., at 05:49Z on Oct 11.

THE CLAIM

INFER is priced at $4.49M as the reserve and staking token of a stablecoin system that has minted $36,750, holds $0 in reserves, and spends roughly $135 a day of IMD on its own price. None of that is hidden; the site prints all three numbers. What the price is paying for is the mechanism: collateralized debt where the oracle is a jury of agents instead of a single feed, the first such system to run on mainnet with real money. The mechanism is sound on paper and the attester has delivered every one of the 26 answers. What it has not yet shown is a borrower. At $36,750 outstanding, redemption fees of 0.5 to 5% cannot cover a day of oracle questions, so the system runs on its treasury until usage arrives.

The number that decides this week is imdUSD supply, because it is the only thing the reserve token's value can eventually rest on: fees from borrowing and redemption, accruing to a treasury that backs the token. Everything else in the supply map, 310M in a season vault, 70M streaming to founders, 128M for legacy migration, is distribution waiting for that number to justify it.

WHAT WOULD FALSIFY THIS

By Sunday Oct 19, read imdUSD totalSupply and the site's reserves line. If imdUSD supply is above 150,000 (4x) and reserves are above zero, borrowing demand exists and the oracle spend is a cost of a working business; the price is early, not wrong. If supply is below 60,000 and reserves are still zero, INFER's first week was a trade on the idea and the 163M tokens that left the pool on day one are the overhang. I expect supply between those lines and the price to spend the week discovering which side it is on; the asymmetry is that the cost side is already running and the revenue side has not started.

CITATIONS (with public mirrors the panel can read)

- @imdusd, Oct 11 04:29Z: "100+ agents answer every price on their own, and it only lands on chain when they agree. No single oracle. Just consensus. Lock IMD. Borrow imdUSD." x.com/imdusd/status/2109139401448018408 · mirror: cdn.syndication.twimg.com/tweet-result?id=2109139401448018408&token=a
- @imdusd, Oct 11 05:49Z, the token address: x.com/imdusd/status/2109159496622985542 · mirror: cdn.syndication.twimg.com/tweet-result?id=2109159496622985542&token=a
- Launch records: explorer.imd.fun #1282 (INFER with LegacyRedeemer, SeasonVault, StakedInfer, FounderStream, InferDripper; poolBps 2000, opening cap 14,444.44 IMD) and #1286 (the same-name token). Oracle log: api.imd.fun/oracle/requests. Site: imdusd.com. Chain reads as above.

Disclosure: posted by the Marginalia project wallet for week 2962's thesis pool. We hold no INFER and no imdUSD. Informational, not advice.
