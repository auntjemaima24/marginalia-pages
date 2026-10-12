// The chain layer: one public client, one optional wallet, the four contracts, and `send`, which simulates
// every call before it is sent so a revert never costs gas, and which only logs in dry mode.
import { createPublicClient, createWalletClient, http, fallback, parseGwei, formatGwei } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { mainnet } from 'viem/chains';
import { readFileSync } from 'node:fs';
import { config } from './config.js';

const here = new URL('.', import.meta.url);
const loadAbi = (name) => JSON.parse(readFileSync(new URL(`../abi/${name}.json`, here), 'utf8'));

export const abi = {
  hook: loadAbi('hook'),
  router: loadAbi('router'),
  judge: loadAbi('judge'),
  factory: loadAbi('factory'),
  erc20: loadAbi('erc20'),
};

export const chain = mainnet;
// primary + fallback: a dedicated metered key first, the public node when it errors or times out
function transport() {
  const urls = [config.rpcUrl, config.rpcFallbackUrl].filter((u, i, arr) => u && arr.indexOf(u) === i);
  const ts = urls.map((u) => http(u, { timeout: 15_000, retryCount: 1 }));
  return ts.length > 1 ? fallback(ts, { rank: false }) : ts[0];
}
export const pub = createPublicClient({ chain, transport: transport() });
export const logsClient = createPublicClient({ chain, transport: http(config.logsRpcUrl) });
export const account = config.privateKey ? privateKeyToAccount(config.privateKey) : null;
export const wallet = account ? createWalletClient({ account, chain, transport: transport() }) : null;

export const contracts = {
  hook: { address: config.hook, abi: abi.hook },
  router: null, // resolved at boot
  judge: null,
  factory: { address: config.factory, abi: abi.factory },
  imd: null,
};

export async function resolveCompanions() {
  const [router, judge, imd] = await Promise.all([
    pub.readContract({ ...contracts.hook, functionName: 'router' }),
    pub.readContract({ ...contracts.hook, functionName: 'judge' }),
    pub.readContract({ ...contracts.hook, functionName: 'imd' }),
  ]);
  contracts.router = { address: router, abi: abi.router };
  contracts.judge = { address: judge, abi: abi.judge };
  contracts.imd = { address: imd, abi: abi.erc20 };
  return { router, judge, imd };
}

export const read = (c, functionName, args = []) => pub.readContract({ ...c, functionName, args });

/// Simulate, then send. Returns {ok, hash?, reason?}. In dry mode it simulates and reports only.
export async function send(label, c, functionName, args = [], { value } = {}) {
  const from = account ? account.address : '0x0000000000000000000000000000000000000001';
  let request;
  try {
    ({ request } = await pub.simulateContract({ ...c, functionName, args, account: from, value }));
  } catch (e) {
    return { ok: false, reason: shortReason(e) };
  }
  if (config.dry) {
    console.log(`[dry] would send ${label}: ${functionName}(${args.map(String).join(', ')})`);
    return { ok: true, dry: true };
  }
  if (txCount() >= config.maxTxPerDay) {
    return { ok: false, reason: `daily tx cap reached (${config.maxTxPerDay}); holding until the next UTC day` };
  }
  const fees = await pub.estimateFeesPerGas();
  if (fees.maxFeePerGas > parseGwei(String(config.maxFeeGwei))) {
    return { ok: false, reason: `gas too high: ${formatGwei(fees.maxFeePerGas)} gwei > cap ${config.maxFeeGwei}` };
  }
  const hash = await wallet.writeContract({ ...request, maxFeePerGas: fees.maxFeePerGas, maxPriorityFeePerGas: fees.maxPriorityFeePerGas });
  bumpTxCount();
  console.log(`sent ${label}: ${functionName}(${args.map(String).join(', ')}) -> ${hash}`);
  const receipt = await pub.waitForTransactionReceipt({ hash, timeout: 180_000 }).catch(() => null);
  return { ok: receipt ? receipt.status === 'success' : null, hash, gasUsed: receipt ? Number(receipt.gasUsed) : null };
}

// in-memory per-UTC-day transaction counter (a restart resets it; the cap is a brake, not a ledger)
let txDay = '', txN = 0;
function txCount() {
  const d = new Date().toISOString().slice(0, 10);
  if (d !== txDay) { txDay = d; txN = 0; }
  return txN;
}
function bumpTxCount() { txCount(); txN++; }
export function txStats() { return { day: txDay, sent: txCount(), cap: config.maxTxPerDay }; }

export function shortReason(e) {
  const s = (e && (e.shortMessage || e.message)) || String(e);
  const m = s.match(/reverted with the following reason:\s*(.+)|Error:\s*([A-Za-z0-9_]+\(\))/);
  return (m && (m[1] || m[2])) || s.split('\n')[0].slice(0, 160);
}

export async function latestBlock() {
  return Number(await pub.getBlockNumber());
}

export async function blockTimestamp(n) {
  const b = await pub.getBlock({ blockNumber: BigInt(n) });
  return Number(b.timestamp);
}
