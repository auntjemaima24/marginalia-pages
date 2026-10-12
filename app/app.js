// Marginalia minimal site: reads the chain directly, posts through the router with an injected wallet.
// No backend, no analytics. Public read RPC for logs; the wallet's RPC for writes.
import {
  createPublicClient, createWalletClient, custom, http, parseAbi, formatEther, parseEther,
  encodeAbiParameters, keccak256, getAddress, isAddress, pad, hexToBigInt,
} from 'https://esm.sh/viem@2.21.0';
import { mainnet } from 'https://esm.sh/viem@2.21.0/chains';

const HOOK = '0xf0457dd0cf526686190e4f057ba19db14d34a0cc';
const MARG = '0xfa0efea559bde229031c2b0a219472316647759c';
const IMD = '0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7';
const POOL_MANAGER = '0x000000000004444c5dc75cb358380d2e3de08a90';
const DEPLOY_BLOCK = 26169583n;
const MARG_KEY = { currency0: IMD, currency1: MARG, fee: 12500, tickSpacing: 60, hooks: HOOK };
const READ_RPC = 'https://ethereum-rpc.publicnode.com';

const hookAbi = parseAbi([
  'event NotePosted(bytes32 indexed id, address indexed author, address indexed x, uint8 class, uint8 side, uint32 targetBps, uint16 horizonDays, bytes32 parentId, string text)',
  'event Settled(bytes32 indexed id, uint8 outcome, uint256 price, int256 scoreDelta, address settler)',
  'function noteOf(bytes32) view returns ((address author,address x,uint8 side,uint32 targetBps,uint16 horizonDays,uint8 class,uint8 status,uint256 postPrice,uint256 postBalance,uint256 deposit,bytes32 parentId,uint32 children))',
  'function horizonEnd(bytes32) view returns (uint256)',
  'function router() view returns (address)',
  'function records(address) view returns (int256 score,uint32 posted,uint32 right,uint32 wrong,uint32 broken,uint32 retracted,uint32 judgedWins)',
  'function refundPool(uint32) view returns (uint256)',
  'function thesisPool(uint32) view returns (uint256)',
  'function today() view returns (uint32)',
  'function week() view returns (uint32)',
  'function noteCount() view returns (uint256)',
  'function margPriceInImd() view returns (uint256)',
  'function STAMP() view returns (uint256)',
  'function MARG_BUY() view returns (uint256)',
  'function BOND_MIN() view returns (uint256)',
  'function BOND_MAX() view returns (uint256)',
  'function TEXT_MAX() view returns (uint256)',
  'function THESIS_TEXT_MAX() view returns (uint256)',
]);
const routerAbi = parseAbi([
  'struct Venue { uint8 kind; bytes32 ref; address quote; bool xIsToken0; }',
  'struct NoteParams { address x; Venue venue; uint8 side; uint32 targetBps; uint16 horizonDays; bytes32 parentId; uint8 class; string text; }',
  'struct PoolKey { address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks; }',
  'function checkpointVenue(NoteParams p, PoolKey v4Key)',
  'function validateVenue(NoteParams p, PoolKey key) view returns (Venue)',
  'function priceWindows(bytes32) view returns (uint64 startedAt,uint64 blockNumber,uint256 xStart,uint256 xMin,uint256 xMax,uint256 quoteMin,uint256 quoteMax)',
  'function note(NoteParams p, PoolKey v4Key, uint256 imdIn, uint256 minMargOut, uint256 deadline) returns (uint256)',
]);
const erc20Abi = parseAbi([
  'function allowance(address,address) view returns (uint256)',
  'function approve(address,uint256) returns (bool)',
  'function balanceOf(address) view returns (uint256)',
  'function symbol() view returns (string)',
]);

const pub = createPublicClient({ chain: mainnet, transport: http(READ_RPC) });
const $ = (id) => document.getElementById(id);
const STATUS = ['open', 'right', 'wrong', 'void (sold)', 'void (no data)', 'retracted', 'thesis open', 'thesis closed'];
const STATUS_CLASS = ['open', 'right', 'wrong', 'void', 'void', 'retracted', 'thesis', 'thesis'];
let wallet = null, account = null, routerAddr = null, consts = null;

// ------------------------------------------------------------------ nav
function show(view) {
  for (const v of document.querySelectorAll('.view')) v.classList.toggle('hidden', v.id !== view);
  for (const a of document.querySelectorAll('nav a')) a.classList.toggle('active', a.dataset.nav === view);
  if (view === 'pools') loadPools();
}
window.addEventListener('hashchange', () => show(location.hash.slice(1) || 'feed'));

// ------------------------------------------------------------------ wallet
async function connect() {
  if (!window.ethereum) { alert('No wallet found. Open this page in a wallet browser or install one.'); return; }
  wallet = createWalletClient({ chain: mainnet, transport: custom(window.ethereum) });
  [account] = await wallet.requestAddresses();
  const chainId = await wallet.getChainId();
  if (chainId !== 1) { try { await wallet.switchChain({ id: 1 }); } catch { alert('Switch the wallet to Ethereum mainnet.'); } }
  $('connect').textContent = account.slice(0, 6) + '…' + account.slice(-4);
  refreshApproval();
}
$('connect').onclick = connect;

// ------------------------------------------------------------------ feed
const short = (a) => a.slice(0, 6) + '…' + a.slice(-4);
const symCache = new Map();
async function symbolOf(addr) {
  const k = addr.toLowerCase();
  if (k === MARG.toLowerCase()) return 'MARG';
  if (!symCache.has(k)) symCache.set(k, pub.readContract({ address: addr, abi: erc20Abi, functionName: 'symbol' }).catch(() => short(addr)));
  return symCache.get(k);
}
async function getLogsChunked(args) {
  const head = await pub.getBlockNumber();
  const out = [];
  for (let from = DEPLOY_BLOCK; from <= head; from += 2000n) {
    const to = from + 1999n > head ? head : from + 1999n;
    out.push(...await pub.getLogs({ ...args, fromBlock: from, toBlock: to }));
  }
  return out;
}
async function loadFeed() {
  try {
    const posted = await getLogsChunked({ address: HOOK, event: hookAbi.find((e) => e.name === 'NotePosted') });
    const settled = await getLogsChunked({ address: HOOK, event: hookAbi.find((e) => e.name === 'Settled') });
    const settledBy = new Map(settled.map((l) => [l.args.id, l.args]));
    posted.sort((a, b) => Number(b.blockNumber - a.blockNumber));
    $('feed-status').textContent = posted.length ? `${posted.length} notes` : 'no notes yet — be the first';
    const cards = [];
    for (const l of posted.slice(0, 100)) {
      const a = l.args;
      const v = await pub.readContract({ address: HOOK, abi: hookAbi, functionName: 'noteOf', args: [a.id] });
      const sym = await symbolOf(a.x);
      const thesis = Number(a.targetBps) === 0;
      const status = Number(v.status);
      const s = settledBy.get(a.id);
      const target = thesis ? 'thesis' : `${Number(a.side) === 0 ? 'BUY' : 'SELL'} · ${Number(a.side) === 0 ? '+' : '−'}${Math.abs(Number(a.targetBps) - 10000) / 100}% in ${a.horizonDays}d`;
      cards.push(`<div class="card">
        <div class="head"><span><strong>${sym}</strong> · ${target}</span><span class="tag ${STATUS_CLASS[status]}">${STATUS[status]}</span></div>
        <div class="text">${escapeHtml(a.text)}</div>
        <div class="head"><span>by <a href="#record" data-addr="${a.author}">${short(a.author)}</a> · bond ${formatEther(v.deposit)} IMD${a.parentId !== '0x' + '0'.repeat(64) ? ' · counter/child' : ''}</span>
        <span><a href="https://etherscan.io/tx/${l.transactionHash}">tx</a> · <code>${a.id.slice(0, 10)}</code>${s ? ` · settled ${formatPrice(s.price)}` : ''}</span></div>
      </div>`);
    }
    $('notes').innerHTML = cards.join('') || '<p class="muted">Nothing posted yet. The first note goes on the record forever.</p>';
    for (const el of document.querySelectorAll('[data-addr]')) el.onclick = () => { $('record-addr').value = el.dataset.addr; lookupRecord(); };
  } catch (e) {
    $('feed-status').textContent = 'could not load: ' + (e.shortMessage || e.message);
  }
}
const formatPrice = (p) => p ? Number(formatEther(p)).toPrecision(4) + ' IMD' : '—';
function escapeHtml(s) { return s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c])); }

// ------------------------------------------------------------------ constants + pools
async function loadConsts() {
  const names = ['STAMP', 'MARG_BUY', 'BOND_MIN', 'BOND_MAX', 'TEXT_MAX', 'THESIS_TEXT_MAX'];
  const vals = await Promise.all(names.map((n) => pub.readContract({ address: HOOK, abi: hookAbi, functionName: n })));
  consts = Object.fromEntries(names.map((n, i) => [n, vals[i]]));
  routerAddr = await pub.readContract({ address: HOOK, abi: hookAbi, functionName: 'router' });
  updateImdIn();
}
async function loadPools() {
  const [today, week] = await Promise.all([pub.readContract({ address: HOOK, abi: hookAbi, functionName: 'today' }), pub.readContract({ address: HOOK, abi: hookAbi, functionName: 'week' })]);
  const [refund, thesis, count, price] = await Promise.all([
    pub.readContract({ address: HOOK, abi: hookAbi, functionName: 'refundPool', args: [today] }),
    pub.readContract({ address: HOOK, abi: hookAbi, functionName: 'thesisPool', args: [week] }),
    pub.readContract({ address: HOOK, abi: hookAbi, functionName: 'noteCount' }),
    pub.readContract({ address: HOOK, abi: hookAbi, functionName: 'margPriceInImd' }).catch(() => 0n),
  ]);
  $('pools-cards').innerHTML = `
    <div class="card"><div class="kv"><span>Today's writer refund pool</span><strong>${Number(formatEther(refund)).toFixed(3)} IMD</strong><span>This week's thesis prize pool</span><strong>${Number(formatEther(thesis)).toFixed(3)} IMD</strong><span>Notes ever posted</span><strong>${count}</strong><span>MARG per IMD on the launch pool</span><strong>${price ? Math.round(1e18 / Number(price)).toLocaleString() : '—'}</strong></div></div>`;
}

// ------------------------------------------------------------------ post flow
function updateImdIn() {
  if (!consts) return;
  const bond = parseEther(String($('bond').value || '0'));
  $('imd-in').textContent = formatEther(consts.STAMP + consts.MARG_BUY + bond);
}
$('bond').oninput = updateImdIn;
$('kind').onchange = () => {
  const thesis = $('kind').value === 'thesis';
  $('call-fields').classList.toggle('hidden', thesis);
  $('text-limit').textContent = thesis ? '(up to 8192 bytes)' : '(up to 280 bytes)';
};
$('venue-kind').onchange = () => $('venue-ref-row').classList.toggle('hidden', $('venue-kind').value === 'marg');

function buildParams() {
  const x = getAddress($('x').value.trim());
  const thesis = $('kind').value === 'thesis';
  const vk = $('venue-kind').value;
  let venue, key;
  if (vk === 'marg') {
    if (x.toLowerCase() !== MARG.toLowerCase()) throw new Error('The launch pool venue is for notes on MARG. Pick a v3 pool or v2 pair for another token.');
    key = MARG_KEY;
    const encoded = encodeAbiParameters([{ type: 'address' }, { type: 'address' }, { type: 'uint24' }, { type: 'int24' }, { type: 'address' }], [key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks]);
    venue = { kind: 1, ref: keccak256(encoded), quote: IMD, xIsToken0: false };
  } else {
    const ref = $('venue-ref').value.trim();
    if (!isAddress(ref)) throw new Error('Enter the pool or pair address.');
    key = { currency0: '0x0000000000000000000000000000000000000000', currency1: '0x0000000000000000000000000000000000000000', fee: 0, tickSpacing: 0, hooks: '0x0000000000000000000000000000000000000000' };
    venue = { kind: vk === 'v3' ? 2 : 3, ref: pad(ref, { size: 32 }), quote: '0x0000000000000000000000000000000000000000', xIsToken0: false };
  }
  const parent = $('parent').value.trim();
  const text = $('text').value;
  const bytes = new TextEncoder().encode(text).length;
  if (thesis ? bytes > Number(consts.THESIS_TEXT_MAX) : bytes > Number(consts.TEXT_MAX)) throw new Error('Text too long.');
  const p = {
    x, venue,
    side: thesis ? 0 : Number($('side').value),
    targetBps: thesis ? 0 : (Number($('side').value) === 0 ? 10000 + Number($('target').value) * 100 : 10000 - Number($('target').value) * 100),
    horizonDays: thesis ? 0 : Number($('horizon').value),
    parentId: parent ? parent : '0x' + '0'.repeat(64),
    class: 1,
    text,
  };
  if (!thesis && (p.targetBps < 0 || Number($('target').value) < 10)) throw new Error('Target must be at least 10%.');
  return { p, key, thesis };
}

async function venueWindow(p, key) {
  const v = await pub.readContract({ address: routerAddr, abi: routerAbi, functionName: 'validateVenue', args: [p, key] });
  const id = keccak256(encodeAbiParameters([{ type: 'tuple', components: [{ type: 'uint8' }, { type: 'bytes32' }, { type: 'address' }, { type: 'bool' }] }], [[v.kind, v.ref, v.quote, v.xIsToken0]]));
  const w = await pub.readContract({ address: routerAddr, abi: routerAbi, functionName: 'priceWindows', args: [id] });
  return { v, startedAt: Number(w[0]) };
}

async function refreshCheckpoint() {
  try {
    const { p, key, thesis } = buildParams();
    if (thesis) { $('ckpt-status').textContent = 'theses need no checkpoint'; return; }
    const { startedAt } = await venueWindow(p, key);
    if (!startedAt) { $('ckpt-status').textContent = 'no window yet'; return; }
    const age = Math.floor(Date.now() / 1000) - startedAt;
    if (age < 3600) $('ckpt-status').textContent = `window started ${Math.floor(age / 60)} min ago — ready in ${60 - Math.floor(age / 60)} min`;
    else if (age <= 6 * 3600) $('ckpt-status').textContent = `ready (window ${Math.floor(age / 60)} min old)`;
    else $('ckpt-status').textContent = 'window expired — checkpoint again';
  } catch (e) { $('ckpt-status').textContent = e.message; }
}
['x', 'venue-kind', 'venue-ref', 'kind'].forEach((id) => $(id).addEventListener('change', refreshCheckpoint));

async function refreshApproval() {
  if (!account || !routerAddr) return;
  const allowance = await pub.readContract({ address: IMD, abi: erc20Abi, functionName: 'allowance', args: [account, routerAddr] });
  const bal = await pub.readContract({ address: IMD, abi: erc20Abi, functionName: 'balanceOf', args: [account] });
  $('approve-status').textContent = `allowance ${Number(formatEther(allowance)).toFixed(2)} · balance ${Number(formatEther(bal)).toFixed(2)} IMD`;
}

async function tx(label, fn) {
  if (!wallet) { await connect(); if (!wallet) return null; }
  $('post-error').textContent = '';
  try {
    const hash = await fn();
    const r = await pub.waitForTransactionReceipt({ hash });
    if (r.status !== 'success') throw new Error(label + ' reverted');
    return hash;
  } catch (e) {
    $('post-error').textContent = e.shortMessage || e.message;
    return null;
  }
}

$('btn-ckpt').onclick = async () => {
  try {
    const { p, key, thesis } = buildParams();
    if (thesis) { $('ckpt-status').textContent = 'theses need no checkpoint'; return; }
    $('ckpt-status').textContent = 'sending…';
    const h = await tx('checkpoint', () => wallet.writeContract({ account, address: routerAddr, abi: routerAbi, functionName: 'checkpointVenue', args: [p, key] }));
    if (h) await refreshCheckpoint();
  } catch (e) { $('post-error').textContent = e.message; }
};

$('btn-approve').onclick = async () => {
  const bond = parseEther(String($('bond').value || '0'));
  const imdIn = consts.STAMP + consts.MARG_BUY + bond;
  $('approve-status').textContent = 'sending…';
  const h = await tx('approve', () => wallet.writeContract({ account, address: IMD, abi: erc20Abi, functionName: 'approve', args: [routerAddr, imdIn] }));
  if (h) refreshApproval();
};

$('btn-post').onclick = async () => {
  try {
    const { p, key } = buildParams();
    const bond = parseEther(String($('bond').value || '0'));
    if (bond < consts.BOND_MIN || bond > consts.BOND_MAX) throw new Error('Bond must be between 0.25 and 10 IMD.');
    const imdIn = consts.STAMP + consts.MARG_BUY + bond;
    // the swap buys exactly MARG_BUY of MARG; accept 10% below the current pool price
    const price = await pub.readContract({ address: HOOK, abi: hookAbi, functionName: 'margPriceInImd' }); // IMD per MARG, 1e18
    const minMargOut = price ? (consts.MARG_BUY * 10n ** 18n * 9n) / (price * 10n) : 0n;
    const deadline = BigInt(Math.floor(Date.now() / 1000) + 20 * 60);
    $('post-status').textContent = 'sending…';
    const h = await tx('post', () => wallet.writeContract({ account, address: routerAddr, abi: routerAbi, functionName: 'note', args: [p, key, imdIn, minMargOut, deadline] }));
    if (h) { $('post-status').textContent = 'posted'; $('text').value = ''; loadFeed(); location.hash = '#feed'; }
    else $('post-status').textContent = '';
  } catch (e) { $('post-error').textContent = e.message; }
};

// ------------------------------------------------------------------ record
async function lookupRecord() {
  const addr = $('record-addr').value.trim();
  if (!isAddress(addr)) { $('record-out').innerHTML = '<p class="error">Enter a wallet address.</p>'; return; }
  const r = await pub.readContract({ address: HOOK, abi: hookAbi, functionName: 'records', args: [addr] });
  const [score, posted, right, wrong, broken, retracted, judgedWins] = r;
  $('record-out').innerHTML = `<div class="card"><div class="kv"><span>Score</span><strong>${(Number(score) / 1e4).toFixed(2)}</strong><span>Posted</span><strong>${posted}</strong><span>Right</span><strong>${right}</strong><span>Wrong</span><strong>${wrong}</strong><span>Broken (sold the position)</span><strong>${broken}</strong><span>Retracted</span><strong>${retracted}</strong><span>Thesis prizes</span><strong>${judgedWins}</strong></div></div>`;
  location.hash = '#record';
}
$('record-form').onsubmit = (e) => { e.preventDefault(); lookupRecord(); };

// ------------------------------------------------------------------ boot
show(location.hash.slice(1) || 'feed');
loadConsts().then(() => { loadFeed(); refreshCheckpoint(); }).catch((e) => { $('feed-status').textContent = 'RPC error: ' + (e.shortMessage || e.message); });
