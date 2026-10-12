// Keeper configuration: everything comes from the environment, with the live launch #1283 as defaults.
// RPC_URL is required. KEEPER_PRIVATE_KEY is optional: without it the keeper runs in dry mode and only
// logs what it would send. Never print the key.

const env = process.env;

function int(name, dflt) {
  const v = env[name];
  if (v === undefined || v === '') return dflt;
  const n = Number(v);
  if (!Number.isFinite(n)) throw new Error(`${name} must be a number`);
  return n;
}

export const config = {
  rpcUrl: env.RPC_URL,
  // a second RPC the client fails over to when the primary errors or times out (default: the public node)
  rpcFallbackUrl: env.RPC_FALLBACK_URL || 'https://ethereum-rpc.publicnode.com',
  // eth_getLogs over wide ranges: Alchemy's free tier allows 10 blocks per call, so logs default to a public node
  logsRpcUrl: env.LOGS_RPC_URL || 'https://ethereum-rpc.publicnode.com',
  privateKey: env.KEEPER_PRIVATE_KEY || null,
  chainId: int('CHAIN_ID', 1),
  hook: (env.HOOK_ADDRESS || '0xf0457dd0cf526686190e4f057ba19db14d34a0cc').toLowerCase(),
  deployBlock: int('DEPLOY_BLOCK', 26169583),
  launchNumber: int('LAUNCH_NUMBER', 1283),
  payingWallet: (env.PAYING_WALLET || '0xc95f88706ea9649f73b40d3c89b273dc7ebc9d74').toLowerCase(),
  factory: (env.LAUNCH_FACTORY || '0x12C63b581d07093F6126bc02263c58f7EadaA96F').toLowerCase(),
  dbPath: env.DB_PATH || './data/keeper.db',
  pollMs: int('POLL_MS', 60_000),
  logChunk: int('LOG_CHUNK', 2_000),
  port: int('PORT', 8790),
  apiToken: env.KEEPER_API_TOKEN || null,
  // observation schedule: minutes after the horizon at which the n-th observation is due
  obsScheduleMin: (env.OBS_SCHEDULE_MIN || '5,35,70,300').split(',').map((s) => Number(s.trim())),
  // a venue checkpoint is refreshed when its window is older than this (the router expires them at 6h)
  checkpointRefreshMin: int('CHECKPOINT_REFRESH_MIN', 300),
  // fee claim is OFF until the operator publishes the split. CLAIM_FEES=1 enables the weekly claim;
  // FUND_POT_BPS is the share of the IMD side sent to hook.fundPot right after the claim (0 = keep all).
  claimFees: env.CLAIM_FEES === '1',
  fundPotBps: int('FUND_POT_BPS', 0),
  claimEveryDays: int('CLAIM_EVERY_DAYS', 7),
  maxFeeGwei: int('MAX_FEE_GWEI', 30),
  // HARD CAPS: the keeper never sends more than this many transactions per UTC day, whatever the chain says
  maxTxPerDay: int('MAX_TX_PER_DAY', 60),
  dry: env.DRY === '1' || process.argv.includes('--dry'),
  once: process.argv.includes('--once'),
};

if (!config.rpcUrl) {
  console.error('RPC_URL is required');
  process.exit(2);
}
if (!config.privateKey) config.dry = true;
