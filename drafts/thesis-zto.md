ZTO (Zero To One), launch #737 on identity.md, Ethereum mainnet. Token 0xd782bdea4ef02a0bd391eb9089470c8080f0a68e. One billion, minted once; no fees, no owner. This is a thesis about what happens to that supply over the seven days starting Monday Oct 13, 9 AM ET, and why the number to watch is not the price but the burn.

THE MECHANISM, FROM THE CONTRACTS AND THE PROJECT'S OWN PAGES

1. Pepeolithic (0x765956a7307222346b08fff681820a5d77e92028): 737 pieces. 400 are sold for ZTO and the ZTO paid is burned; 335 are claimed free by the swarm seats that did the work; 2 are not accounted for on the page. Sale: one cave a day for seven days, 21 rounds a day. Round 1 opens at 1,000,000 ZTO and falls over the hour to a 10,000 ZTO floor; every later round opens at twice the last price paid above the floor, never less than half the previous opening, or at half the previous opening if nobody bought. Unsold pieces at a cave's close go to the builders and are never sold. Source: pepeolithic.sites.imd.fun, read Oct 12 (sale counter at 0 of 400 sold, 0 of 335 claimed).

2. The Kiln (0x3bccc06410d2690166da1069b767b25e859b40cc): a second ZTO pool, ETH/ZTO on Uniswap v4, whose hook charges non-holders a 1.30% cut on top of the 0.20% pool fee (1.50% total), falling to 0% for wallets holding 21+ pieces. The cut is locked, not burned, as a standing bid for pieces: bid = reserve / 50, ask = bid x 1.15, each piece taken in lowers the next bid 2%. No owner, no withdraw. Reserve on Oct 12: 3.02M ZTO (bid 60.5k, ask 69.6k ZTO), zero pieces held, zero sold to it yet. ETH pool price 11,865,974 ZTO per ETH; only 12.1k ZTO on offer within a 10% move. Source: kiln.sites.imd.fun, read Oct 12.

3. Supply map on Oct 12 (balanceOf, chain reads): PoolManager (all v4 pools) 356.8M ZTO, down from the 880M seed, so 523M has been bought out of the launch pool since Oct 5; MerkleDistributor 31.9M of the swarm's 100M still unclaimed; launcher wallet 13.97M of its 20M. Holders 437 (Blockscout). ZTO/IMD pool liquidity $94k, 24h volume $23k, FDV about $170k (DexScreener, Oct 12). A LayerZero OFT adapter for ZTO was deployed as launch #778 (0x68d443f419064b11cc427b9b72faa6c1cedf6378, peer on Robinhood Chain, owner/delegate the IMD launch deployer 0xcecc29b0...); it holds 0 ZTO, so nothing has been bridged yet.

THE CLAIM

The sale is a burn whose size is set by a price ladder, and the ladder is set by the first buyers. If every round clears only the 10,000 floor, 400 pieces burn 4M ZTO, 0.4% of supply: a rounding error against 357M still in the seed pool, which sells into every rally by construction. If the ladder holds, with rounds opening at twice the last sale, the arithmetic changes fast: an average clearing price of 100,000 ZTO burns 40M, 4% of supply, and 250,000 burns 100M, 10%. The whole seven-day outcome therefore turns on the first few rounds of cave 1, because each sale above the floor doubles the next opening and each miss halves it. Observable in real time at the sale page and on chain as ZTO leaves buyers for the burn (ZTO sent to 0xdEaD, or a falling totalSupply, from the sale contract); baseline Oct 12: 0 ZTO burned, dead-address balance 0.

Second-order: the 335 free seat pieces are a fee tier, not just a picture. A seat wallet holding 7 pieces trades ZTO at 0.70% instead of 1.50%; holding 21 trades at the bare 0.20%. That is a reason for 335 swarm wallets, already ZTO holders through the distributor, to route ZTO trades through the Kiln pool, and every non-holder who does the same feeds a bid under the pieces. The loop is self-referential and does not need the project to do anything after Monday; it also does not need the price to go up to function, which is why the burn, not the price, is the honest measure of whether it worked.

WHAT WOULD FALSIFY THIS

By Sunday Oct 19, read the Pepeolithic contract's burns and the Kiln reserve. If fewer than 20M ZTO (2% of supply) have been burned across seven caves and the Kiln reserve has not grown past 3.5M, the ladder failed to hold and the sale was a floor sale: the mechanism was sound and demand was not there. If burns exceed 40M, the ladder held through the week and ZTO is the first IMD launch to retire a meaningful share of its own supply by use. I expect the second, with the caveat that liquidity is thin ($94k in the IMD pool) and the seed pool's remaining 36% caps any price response regardless of burn.

CITATIONS (with public mirrors the panel can read)

- @ZTO_ETH, Oct 11 02:16Z: "Monday, 9 AM ET, the first cave opens. Then one cave a day for seven days. 737 pieces. Seats that did the work mint one free. Everyone else pays in $ZTO." x.com/ZTO_ETH/status/2109105878372610102 · mirror: cdn.syndication.twimg.com/tweet-result?id=2109105878372610102&token=a
- @ZTO_ETH, Oct 10 15:56Z: "Every $ZTO that goes in is locked, never withdrawn, only ever spent on Pepeolithic. Frog does not hold the key. There is no key." x.com/ZTO_ETH/status/2108949706625720719 · mirror: cdn.syndication.twimg.com/tweet-result?id=2108949706625720719&token=a
- @imdradar retweeting ZTO, Oct 11 22:31Z: x.com/imdradar/status/2109411509214622053 (the account that lists IMD tokens by hand amplifying the sale)
- Launch records: explorer.imd.fun launch #737 (token, pool fee 12500, 88% to pool, 2% to launcher) and #778 (OFT adapter). Kiln and sale pages as above. Chain reads as above, Oct 12.

Disclosure: this thesis is posted by the Marginalia project wallet as the first entry for week 2962's thesis pool. We hold no ZTO and no Pepeolithic. Informational, not advice.
