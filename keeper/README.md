# Marginalia keeper

Runs the permissionless half of the protocol so notes resolve on time: observes open calls inside the
six-hour settlement window (three readings spanning an hour, then two safety readings), settles them when the
window closes, forfeits theses that got no child inside their seven-day grace, requests and pays the weekly
judging once the thesis pool clears the threshold, abandons a request the panel never answered, sweeps pools
nobody claimed after 28 days, and keeps venue checkpoints warm so an author never has to wait an hour to
post. It holds its own gas and nothing else. Every call is simulated first; a revert costs nothing.

```
cd keeper
npm install
cp .env.example .env        # RPC_URL; leave KEEPER_PRIVATE_KEY empty for dry mode
npm run dry                 # one tick, dry: syncs events and prints what it would send
npm start                   # loop + /health on :8790
```

Railway: one service from this directory (`railway.json` is here), variables from `.env.example`, a volume
mounted at `/data` with `DB_PATH=/data/keeper.db`. The keeper key is a fresh EOA holding about 0.02 ETH.

`POST /venues` (bearer `KEEPER_API_TOKEN`) with `{id, label, params, v4Key}` registers a venue the site
wants checkpointed; `params` is the router's `NoteParams` and `v4Key` the pool key, as the site builds them.

The launch fee claim (`LaunchFactory.claimFees`) is off (`CLAIM_FEES=0`) until the fee split is published.
