// The keeper's jobs. Each is idempotent, simulates before sending, and records what it did or why it waited.
import { contracts, read, send, account } from './chain.js';
import { config } from './config.js';
import { STATUS, refreshStatus } from './sync.js';
import { getMeta, setMeta } from './db.js';

const now = () => Math.floor(Date.now() / 1000);
const DAY = 86_400;
const WEEK = 7 * DAY;

// constants read once from the hook
let K = null;
export async function loadConstants() {
  const names = ['SETTLE_WINDOW', 'OBS_MIN', 'OBS_MIN_SPAN', 'OBS_GAP_BLOCKS', 'THESIS_GRACE', 'SWEEP_AFTER', 'JUDGE_THRESHOLD'];
  const vals = await Promise.all(names.map((n) => read(contracts.hook, n)));
  K = Object.fromEntries(names.map((n, i) => [n, Number(vals[i])]));
  K.ANSWER_DEADLINE = Number(await read(contracts.judge, 'ANSWER_DEADLINE'));
  return K;
}

function logTx(db, kind, ref, r) {
  if (r.dry) return;
  if (r.hash) db.prepare('INSERT OR REPLACE INTO txs (hash, kind, ref, sent_at, ok, gas_used) VALUES (?, ?, ?, ?, ?, ?)').run(r.hash, kind, String(ref), now(), r.ok === null ? null : r.ok ? 1 : 0, r.gasUsed);
}

// ------------------------------------------------------------------ 1. observe + settle calls

export async function observeAndSettle(db, headBlock) {
  const t = now();
  const open = db.prepare('SELECT * FROM notes WHERE is_thesis = 0 AND status = ? AND horizon_end IS NOT NULL AND horizon_end <= ? ORDER BY horizon_end').all(STATUS.Open, t);
  const out = { observed: 0, settled: 0, waiting: 0 };
  for (const n of open) {
    const end = n.horizon_end;
    if (t > end + K.SETTLE_WINDOW) {
      // the window closed: settle (VoidNoData if the series is short; the hook decides)
      const r = await send(`settle ${n.id.slice(0, 10)}`, contracts.hook, 'settle', [n.id]);
      logTx(db, 'settle', n.id, r);
      if (r.ok) { out.settled++; if (!r.dry) await refreshStatus(db, n.id); }
      else {
        db.prepare('UPDATE notes SET last_error = ? WHERE id = ?').run(r.reason, n.id);
        if (/NotOpen|AlreadySettled/i.test(r.reason || '')) await refreshStatus(db, n.id);
      }
      continue;
    }
    // inside the window: is the next observation due?
    const k = n.obs_count;
    const dueMin = config.obsScheduleMin[k];
    if (dueMin === undefined) { out.waiting++; continue; } // schedule exhausted; wait for settle
    if (t < end + dueMin * 60) { out.waiting++; continue; }
    if (n.obs_last_block && headBlock < n.obs_last_block + K.OBS_GAP_BLOCKS + 1) { out.waiting++; continue; }
    const r = await send(`observe#${k + 1} ${n.id.slice(0, 10)}`, contracts.hook, 'observe', [n.id]);
    logTx(db, 'observe', n.id, r);
    if (r.ok) out.observed++;
    else db.prepare('UPDATE notes SET last_error = ? WHERE id = ?').run(r.reason, n.id);
  }
  return out;
}

// ------------------------------------------------------------------ 2. theses past their grace

export async function forfeitLapsedTheses(db) {
  const t = now();
  const rows = db.prepare('SELECT id, posted_at FROM notes WHERE is_thesis = 1 AND status = ? AND posted_at + ? < ?').all(STATUS.ThesisOpen, K.THESIS_GRACE, t);
  const out = { forfeited: 0, released: 0 };
  for (const n of rows) {
    const live = await refreshStatus(db, n.id);
    if (live !== STATUS.ThesisOpen) { out.released++; continue; }
    const r = await send(`settleThesis ${n.id.slice(0, 10)}`, contracts.hook, 'settleThesis', [n.id]);
    logTx(db, 'settleThesis', n.id, r);
    if (r.ok) { out.forfeited++; if (!r.dry) await refreshStatus(db, n.id); }
    else db.prepare('UPDATE notes SET last_error = ? WHERE id = ?').run(r.reason, n.id);
  }
  return out;
}

// ------------------------------------------------------------------ 3. weekly judging

export async function judging(db) {
  const t = now();
  const current = Number(await read(contracts.hook, 'week'));
  const first = Number(getMeta(db, 'firstWeek', current));
  const out = { requested: 0, paid: 0, abandoned: 0 };
  for (let w = first; w < current; w++) {
    const row = db.prepare('SELECT * FROM weeks WHERE week = ?').get(w) || { week: w, judged: 0, paid: 0 };
    if (row.paid) continue;
    const [judged, paid] = await Promise.all([read(contracts.judge, 'judgedSet', [w]), read(contracts.judge, 'paid', [w])]);
    if (paid) { db.prepare('INSERT OR REPLACE INTO weeks (week, judged, paid) VALUES (?, 1, 1)').run(w); continue; }
    if (judged) {
      const r = await send(`payJudged ${w}`, contracts.judge, 'payJudged', [w]);
      logTx(db, 'payJudged', w, r);
      if (r.ok) { out.paid++; if (!r.dry) db.prepare('INSERT OR REPLACE INTO weeks (week, judged, paid) VALUES (?, 1, 1)').run(w); }
      else db.prepare('INSERT INTO weeks (week, judged, last_error) VALUES (?, 1, ?) ON CONFLICT(week) DO UPDATE SET judged = 1, last_error = excluded.last_error').run(w, r.reason);
      continue;
    }
    // not judged yet: the first draw waits for week-end + grace; the pool must clear the threshold
    if (t < (w + 1) * WEEK + K.THESIS_GRACE) continue;
    const pool = await read(contracts.hook, 'thesisPool', [w]);
    if (pool < BigInt(K.JUDGE_THRESHOLD)) continue;
    const eligible = await read(contracts.judge, 'eligibleTheses', [w]);
    if (eligible.length === 0) continue;
    const requestId = await read(contracts.judge, 'requestOf', [w]);
    const requestedAt = Number(await read(contracts.judge, 'requestedAt', [w]));
    const pending = requestId !== '0x0000000000000000000000000000000000000000000000000000000000000000';
    if (pending && t < requestedAt + K.ANSWER_DEADLINE) continue; // the panel has until the deadline
    if (pending) {
      const r = await send(`abandonRequest ${w}`, contracts.judge, 'abandonRequest', [w]);
      logTx(db, 'abandonRequest', w, r);
      if (!r.ok) { db.prepare('INSERT INTO weeks (week, last_error) VALUES (?, ?) ON CONFLICT(week) DO UPDATE SET last_error = excluded.last_error').run(w, r.reason); continue; }
      out.abandoned++;
    }
    const r = await send(`requestJudging ${w}`, contracts.judge, 'requestJudging', [w]);
    logTx(db, 'requestJudging', w, r);
    if (r.ok) { out.requested++; db.prepare('INSERT INTO weeks (week, requested_at) VALUES (?, ?) ON CONFLICT(week) DO UPDATE SET requested_at = excluded.requested_at').run(w, t); }
    else db.prepare('INSERT INTO weeks (week, last_error) VALUES (?, ?) ON CONFLICT(week) DO UPDATE SET last_error = excluded.last_error').run(w, r.reason);
  }
  return out;
}

// ------------------------------------------------------------------ 4. sweeps of stale pools (28 days)

export async function sweeps(db) {
  const t = now();
  const today = Number(await read(contracts.hook, 'today'));
  const firstDay = Number(getMeta(db, 'firstDay', today));
  const out = { days: 0, weeks: 0 };
  for (let d = firstDay; (d + 1) * DAY + K.SWEEP_AFTER <= t; d++) {
    if ((db.prepare('SELECT swept FROM days WHERE day = ?').get(d) || {}).swept) continue;
    const pool = await read(contracts.hook, 'refundPool', [d]);
    if (pool === 0n) { db.prepare('INSERT OR REPLACE INTO days (day, swept) VALUES (?, 1)').run(d); continue; }
    const r = await send(`sweep refund day ${d}`, contracts.hook, 'sweep', [0, d]);
    logTx(db, 'sweepDay', d, r);
    if (r.ok) { out.days++; if (!r.dry) db.prepare('INSERT OR REPLACE INTO days (day, swept) VALUES (?, 1)').run(d); }
    else db.prepare('INSERT INTO days (day, last_error) VALUES (?, ?) ON CONFLICT(day) DO UPDATE SET last_error = excluded.last_error').run(d, r.reason);
  }
  const current = Number(await read(contracts.hook, 'week'));
  const firstWeek = Number(getMeta(db, 'firstWeek', current));
  for (let w = firstWeek; (w + 1) * WEEK + K.SWEEP_AFTER <= t; w++) {
    if ((db.prepare('SELECT swept FROM weeks WHERE week = ?').get(w) || {}).swept) continue;
    const pool = await read(contracts.hook, 'thesisPool', [w]);
    if (pool === 0n) { db.prepare('INSERT INTO weeks (week, swept) VALUES (?, 1) ON CONFLICT(week) DO UPDATE SET swept = 1').run(w); continue; }
    const r = await send(`sweep thesis week ${w}`, contracts.hook, 'sweep', [1, w]);
    logTx(db, 'sweepWeek', w, r);
    if (r.ok) { out.weeks++; if (!r.dry) db.prepare('INSERT INTO weeks (week, swept) VALUES (?, 1) ON CONFLICT(week) DO UPDATE SET swept = 1').run(w); }
    else db.prepare('INSERT INTO weeks (week, last_error) VALUES (?, ?) ON CONFLICT(week) DO UPDATE SET last_error = excluded.last_error').run(w, r.reason);
  }
  return out;
}

// ------------------------------------------------------------------ 5. venue checkpoints (fed by the site)

/// A venue row holds the NoteParams and PoolKey the router's checkpointVenue takes; the keeper re-checkpoints
/// it whenever the stored window is older than the refresh interval, so an author never has to wait an hour.
export async function checkpoints(db) {
  const t = now();
  const rows = db.prepare('SELECT * FROM venues').all();
  const out = { refreshed: 0, fresh: 0 };
  for (const v of rows) {
    const p = JSON.parse(v.params_json);
    const key = JSON.parse(v.v4key_json);
    // read the live window: id = keccak(abi.encode(venue)) is computed by the router; we approximate freshness
    // by our own stamp, and let the router refuse a reset of a live window (it reverts; we record and move on)
    if (v.last_checkpoint_at && t < v.last_checkpoint_at + config.checkpointRefreshMin * 60) { out.fresh++; continue; }
    const r = await send(`checkpoint ${v.label || v.id}`, contracts.router, 'checkpointVenue', [p, key]);
    logTx(db, 'checkpoint', v.id, r);
    if (r.ok) { out.refreshed++; if (!r.dry) db.prepare('UPDATE venues SET last_checkpoint_at = ?, last_error = NULL WHERE id = ?').run(t, v.id); }
    else db.prepare('UPDATE venues SET last_error = ? WHERE id = ?').run(r.reason, v.id);
  }
  return out;
}

// ------------------------------------------------------------------ 6. the launch fee (OFF until the split is published)

export async function feeClaim(db) {
  if (!config.claimFees) return { skipped: 'CLAIM_FEES is off' };
  const t = now();
  const last = Number(getMeta(db, 'lastClaimAt', 0));
  if (t < last + config.claimEveryDays * DAY) return { skipped: 'not due' };
  const r = await send(`claimFees ${config.launchNumber}`, contracts.factory, 'claimFees', [config.launchNumber]);
  logTx(db, 'claimFees', config.launchNumber, r);
  if (!r.ok) return { error: r.reason };
  if (!r.dry) setMeta(db, 'lastClaimAt', t);
  // the fee lands in the PAYING wallet (the launch requester), never in the keeper's. The split (fundPot of
  // the IMD side) can only be executed here if the keeper key IS the paying wallet; otherwise the operator
  // runs the split from that wallet and the keeper only triggers the claim.
  if (config.fundPotBps > 0 && account && account.address.toLowerCase() === config.payingWallet) {
    const bal = await read(contracts.imd, 'balanceOf', [account.address]);
    const share = (bal * BigInt(config.fundPotBps)) / 10_000n;
    if (share > 0n) {
      const a = await send('approve imd for fundPot', contracts.imd, 'approve', [config.hook, share]);
      if (a.ok) { const f = await send('fundPot', contracts.hook, 'fundPot', [share]); logTx(db, 'fundPot', share.toString(), f); }
    }
  }
  return { claimed: true, hash: r.hash };
}
