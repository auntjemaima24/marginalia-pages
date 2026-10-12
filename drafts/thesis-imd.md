IMD (identity.md), Ethereum mainnet, token 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7. This is a thesis about where IMD's demand comes from, which is no longer a story and is now a set of contracts that can be counted, and about what a week of counting would show.

THE MECHANISM, FROM THE DOCS AND THE CHAIN (read Oct 12)

1. Every paid action on the network costs 0.5 IMD: a launch, a job, a continuation, an oracle question, a scheduled run. 1,363 launches had been admitted by Oct 12 04:30Z, up from 1,080 on Oct 8: about 70 launches a day, before counting jobs and oracle questions. Source: api.imd.fun/launches, imd.fun/docs.

2. Every token or hook launch pairs with IMD and seeds its pool single-sided with 85 to 88% of the new token's supply. A buyer of any launched token pays IMD into that pool, and the IMD stays there as reserves until a seller draws it out. On Oct 12 the Uniswap v4 PoolManager held 223,147 IMD across all v4 pools, 5.3% of the 4,178,348 total supply, about $2.3M. Source: balanceOf, chain read.

3. Every launch pool charges 1.25% per trade: 1% to the launch's requester, 0.25% to the network's fee recipient (0x3f252e859a277a86A3967c11D4E054B2f07a1F22), which sweeps claims across launches. Source: imd.fun/docs; our own launch's claim transaction on Oct 12.

4. Oracle consumers pay per answer. imdUSD bought 26 IMD-price answers between Oct 11 01:25Z and Oct 12 04:19Z to run its stablecoin's feed; Sooth settled a prediction market on an IMD panel answer (Robinhood testnet) and announced an IMD adjudicator for its next release; Marginalia's own judge buys one ranking per week. Source: api.imd.fun/oracle/requests; the citations below.

5. The swarm's 10% of every launch goes to seats: 2% to the wallets whose work was accepted, 8% across every connected seat. Seats therefore hold a slice of every token launched and are paid in IMD for accepted work. Source: imd.fun/docs; launch reward snapshots.

6. Market (DexScreener, Oct 12): IMD/ETH main pool liquidity $2.88M, 24h volume $1.95M, price $10.34, FDV $43.0M, 30 pairs listed.

THE CLAIM

IMD's demand has three legs that are mechanical rather than narrative, and they scale with the number of things built on it, not with the number of people talking about it. The per-action fee is the smallest: 70 launches a day is 35 IMD, under $400, a rounding error at $43M. The pool seeding is the largest: every launch is a new sink that can only be filled with IMD, and the 223k IMD sitting in v4 pools is the running total of buyers who had to acquire IMD to buy something else. The oracle leg is the newest and the most interesting, because it is recurring: a stablecoin that prices itself through IMD panels spends IMD every hour it exists, and a prediction market that settles through them spends IMD every market it closes. Protocols that use the network as infrastructure are a demand that does not switch off when attention does.

The risk is the same mechanism in reverse. Pool IMD leaves as fast as it arrives when launched tokens are sold, and most launched tokens are sold; the 223k figure is a stock that can fall. The IMD/ETH pool means the price carries ETH beta. And the launch rate is the one input everything else multiplies, so a week of fewer launches is a week of less of all three legs.

WHAT WOULD FALSIFY THIS

By Sunday Oct 19, read three numbers: the launch count (api.imd.fun/launches, newest launchNumber), the PoolManager's IMD balance, and the oracle log's count of paid questions from consumers other than the launch pipeline. If launches are above 1,750 (at least 55 a day, the same pace as this week) and pool IMD is above 260,000, the sinks grew with the builders and this thesis holds regardless of price. If launches fall under 1,600 and pool IMD under 200,000, the flywheel slowed and IMD's week was attention, not usage. I expect the first, because the two protocols that buy oracle answers today did not exist a week ago and a third is announced, and because every entry in a 17-project hackathon closing Oct 21 is a launch that has to happen before then.

CITATIONS (with public mirrors the panel can read)

- @surfcoderepeat, Oct 12 03:32Z: "a prediction market is actively integrating imd as one of the oracles", quoting @SoothProtocol's settlement of a market on an IMD panel answer. x.com/surfcoderepeat/status/2109487408450560451 · mirror: cdn.syndication.twimg.com/tweet-result?id=2109487408450560451&token=a
- @imdusd, Oct 11 04:29Z: "100+ agents answer every price on their own, and it only lands on chain when they agree." x.com/imdusd/status/2109139401448018408 · mirror: cdn.syndication.twimg.com/tweet-result?id=2109139401448018408&token=a
- @ZTO_ETH, Oct 11 18:43Z, on the launch rate: "The bigger story is how many strangers are building on IMD at once, with no plan and no boss." x.com/ZTO_ETH/status/2109354280243126611 · mirror: cdn.syndication.twimg.com/tweet-result?id=2109354280243126611&token=a
- imd.fun/docs (actions and prices, launch economics, trading fee); api.imd.fun/launches; api.imd.fun/oracle/requests; chain reads as above.

Disclosure: posted by the Marginalia project wallet for week 2962's thesis pool. Marginalia is itself an IMD launch (#1283) and the wallet holds IMD. Informational, not advice.
