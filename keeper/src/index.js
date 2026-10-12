// Marginalia keeper: sync events, run the jobs, repeat. Permissionless work on the live hook; the only thing it
// holds is its own gas. A tiny HTTP server exposes /health and lets the site register venues to keep checkpointed.
import { createServer } from 'node:http';
import { config } from './config.js';
import { openDb, getMeta, setMeta } from './db.js';
import { resolveCompanions, account, latestBlock, read, contracts, pub, txStats } from './chain.js';
import { syncEvents } from './sync.js';
import { loadConstants, observeAndSettle, forfeitLapsedTheses, judging, sweeps, checkpoints, feeClaim } from './tasks.js';
import { formatEther } from 'viem';

const db = openDb(config.dbPath);
const state = { startedAt: Date.now(), lastTick: null, lastResult: null, lastError: null, ticks: 0 };

async function boot() {
  const { router, judge, imd } = await resolveCompanions();
  const K = await loadConstants();
  const [today, week] = await Promise.all([read(contracts.hook, 'today'), read(contracts.hook, 'week')]);
  if (!getMeta(db, 'firstDay')) setMeta(db, 'firstDay', Number(today));
  if (!getMeta(db, 'firstWeek')) setMeta(db, 'firstWeek', Number(week));
  const bal = account ? await pub.getBalance({ address: account.address }) : 0n;
  console.log(`marginalia keeper | hook ${config.hook} | router ${router} | judge ${judge} | imd ${imd}`);
  console.log(`mode ${config.dry ? 'DRY (no key or --dry)' : 'LIVE'} | keeper ${account ? account.address : 'none'} | gas ${formatEther(bal)} ETH | poll ${config.pollMs / 1000}s`);
  console.log(`caps: ${config.maxTxPerDay} tx/day, ${config.maxFeeGwei} gwei max fee, claim ${config.claimFees ? 'ON' : 'off'} | rpc ${config.rpcUrl.replace(/\/v2\/.*$/, '/v2/<key>')} → fallback ${config.rpcFallbackUrl} | logs ${config.logsRpcUrl}`);
  console.log(`rules: settle window ${K.SETTLE_WINDOW / 3600}h, obs min ${K.OBS_MIN} spanning ${K.OBS_MIN_SPAN / 3600}h gap ${K.OBS_GAP_BLOCKS} blocks, thesis grace ${K.THESIS_GRACE / 86400}d, sweep after ${K.SWEEP_AFTER / 86400}d, judge threshold ${formatEther(BigInt(K.JUDGE_THRESHOLD))} IMD`);
}

async function tick() {
  const started = Date.now();
  try {
    const head = await latestBlock();
    const s = await syncEvents(db);
    const r = {
      head,
      synced: s,
      observeSettle: await observeAndSettle(db, head),
      theses: await forfeitLapsedTheses(db),
      judging: await judging(db),
      sweeps: await sweeps(db),
      checkpoints: await checkpoints(db),
      fees: await feeClaim(db),
      ms: Date.now() - started,
    };
    state.lastResult = r;
    state.lastError = null;
    const open = db.prepare('SELECT COUNT(*) AS n FROM notes WHERE status IN (0, 6)').get().n;
    console.log(`tick ${new Date().toISOString()} head ${head} logs ${s.logs} open ${open} | obs ${r.observeSettle.observed} settled ${r.observeSettle.settled} waiting ${r.observeSettle.waiting} | theses ${r.theses.forfeited} | judge req ${r.judging.requested} paid ${r.judging.paid} | sweeps ${r.sweeps.days}/${r.sweeps.weeks} | ckpt ${r.checkpoints.refreshed} | ${r.ms}ms`);
  } catch (e) {
    state.lastError = (e && e.message) || String(e);
    console.error('tick failed:', state.lastError);
  }
  state.lastTick = Date.now();
  state.ticks++;
}

function serve() {
  const srv = createServer((req, res) => {
    const json = (code, body) => { res.writeHead(code, { 'content-type': 'application/json' }); res.end(JSON.stringify(body)); };
    if (req.method === 'GET' && req.url === '/health') {
      const open = db.prepare('SELECT COUNT(*) AS n FROM notes WHERE status IN (0, 6)').get().n;
      const total = db.prepare('SELECT COUNT(*) AS n FROM notes').get().n;
      return json(200, { ok: !state.lastError, mode: config.dry ? 'dry' : 'live', keeper: account ? account.address : null, tx: txStats(), ticks: state.ticks, lastTick: state.lastTick, lastError: state.lastError, notes: { total, open }, cursor: Number(getMeta(db, 'cursor', config.deployBlock)), last: state.lastResult });
    }
    if (req.method === 'POST' && req.url === '/venues') {
      if (!config.apiToken || req.headers.authorization !== `Bearer ${config.apiToken}`) return json(401, { error: 'unauthorized' });
      let body = '';
      req.on('data', (c) => { body += c; if (body.length > 65_536) req.destroy(); });
      req.on('end', () => {
        try {
          const { id, label, params, v4Key } = JSON.parse(body);
          if (!id || !params || !v4Key) return json(400, { error: 'id, params, v4Key required' });
          db.prepare('INSERT INTO venues (id, label, params_json, v4key_json, added_at) VALUES (?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET label = excluded.label, params_json = excluded.params_json, v4key_json = excluded.v4key_json').run(id, label || null, JSON.stringify(params), JSON.stringify(v4Key), Math.floor(Date.now() / 1000));
          json(200, { ok: true });
        } catch (e) { json(400, { error: (e && e.message) || String(e) }); }
      });
      return;
    }
    json(404, { error: 'not found' });
  });
  srv.listen(config.port, () => console.log(`health on :${config.port}/health`));
}

await boot();
if (config.once) {
  await tick();
  process.exit(state.lastError ? 1 : 0);
}
serve();
await tick();
setInterval(tick, config.pollMs);
