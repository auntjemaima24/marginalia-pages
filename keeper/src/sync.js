// Event sync: walk the hook's logs from the last cursor, in bounded chunks, and keep the notes table current.
// Everything the tasks need is derived from events plus `horizonEnd(id)`; the venue is not on chain in a
// readable form (neither NotePosted nor noteOf carries it), which is why checkpoints come from the site.
import { parseAbiItem } from 'viem';
import { pub, logsClient, contracts, read, latestBlock } from './chain.js';
import { config } from './config.js';
import { getMeta, setMeta } from './db.js';

const EVENTS = [
  parseAbiItem('event NotePosted(bytes32 indexed id, address indexed author, address indexed x, uint8 class, uint8 side, uint32 targetBps, uint16 horizonDays, bytes32 parentId, string text)'),
  parseAbiItem('event Observed(bytes32 indexed id, uint256 xRead, uint256 quoteRead)'),
  parseAbiItem('event Settled(bytes32 indexed id, uint8 outcome, uint256 price, int256 scoreDelta, address settler)'),
  parseAbiItem('event Retracted(bytes32 indexed id, string text)'),
  parseAbiItem('event ThesisForfeited(bytes32 indexed id)'),
  parseAbiItem('event ThesisReleased(bytes32 indexed id)'),
];

// Status enum of MarginaliaTypes
export const STATUS = { Open: 0, Right: 1, Wrong: 2, VoidSold: 3, VoidNoData: 4, Retracted: 5, ThesisOpen: 6, ThesisClosed: 7 };

export async function syncEvents(db) {
  const head = await latestBlock();
  let from = Number(getMeta(db, 'cursor', config.deployBlock));
  const safeHead = head - 2; // two confirmations
  if (from > safeHead) return { from, to: safeHead, logs: 0 };
  let total = 0;
  const tsCache = new Map();
  const tsOf = async (bn) => {
    if (!tsCache.has(bn)) tsCache.set(bn, Number((await pub.getBlock({ blockNumber: BigInt(bn) })).timestamp));
    return tsCache.get(bn);
  };
  const upsertNote = db.prepare(`INSERT INTO notes (id, author, x, side, target_bps, horizon_days, class, parent_id, posted_at, posted_block, is_thesis, status)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO NOTHING`);
  const setStatus = db.prepare('UPDATE notes SET status = ?, settled_at = ? WHERE id = ?');
  const bumpObs = db.prepare('UPDATE notes SET obs_count = obs_count + 1, obs_first_ts = COALESCE(obs_first_ts, ?), obs_last_block = ? WHERE id = ?');
  let chunk = Number(getMeta(db, 'logChunk', config.logChunk));
  while (from <= safeHead) {
    const to = Math.min(from + chunk - 1, safeHead);
    let logs;
    try {
      logs = await logsClient.getLogs({ address: config.hook, events: EVENTS, fromBlock: BigInt(from), toBlock: BigInt(to) });
    } catch (e) {
      const msg = (e && (e.shortMessage || e.message)) || String(e);
      if (/block range|too many|limit|exceed/i.test(msg) && chunk > 10) {
        chunk = Math.max(10, Math.floor(chunk / 2));
        setMeta(db, 'logChunk', chunk);
        console.warn(`getLogs range refused, chunk -> ${chunk}`);
        continue;
      }
      throw e;
    }
    logs.sort((a, b) => Number(a.blockNumber - b.blockNumber) || a.logIndex - b.logIndex);
    for (const l of logs) {
      const a = l.args;
      const bn = Number(l.blockNumber);
      switch (l.eventName) {
        case 'NotePosted': {
          const ts = await tsOf(bn);
          const thesis = Number(a.targetBps) === 0 ? 1 : 0;
          upsertNote.run(a.id, a.author.toLowerCase(), a.x.toLowerCase(), Number(a.side), Number(a.targetBps), Number(a.horizonDays), Number(a.class),
            a.parentId, ts, bn, thesis, thesis ? STATUS.ThesisOpen : STATUS.Open);
          break;
        }
        case 'Observed': bumpObs.run(await tsOf(bn), bn, a.id); break;
        case 'Settled': setStatus.run(Number(a.outcome), await tsOf(bn), a.id); break;
        case 'Retracted': setStatus.run(STATUS.Retracted, await tsOf(bn), a.id); break;
        case 'ThesisForfeited': setStatus.run(STATUS.ThesisClosed, await tsOf(bn), a.id); break;
        case 'ThesisReleased': setStatus.run(STATUS.ThesisClosed, await tsOf(bn), a.id); break;
      }
    }
    total += logs.length;
    setMeta(db, 'cursor', to + 1);
    from = to + 1;
  }
  // horizons for open calls that do not have one yet
  const missing = db.prepare('SELECT id FROM notes WHERE is_thesis = 0 AND horizon_end IS NULL').all();
  for (const { id } of missing) {
    const end = Number(await read(contracts.hook, 'horizonEnd', [id]));
    db.prepare('UPDATE notes SET horizon_end = ? WHERE id = ?').run(end, id);
  }
  return { to: safeHead, logs: total, head };
}

/// Re-read a note's live status from the chain (after a send, or when a call reverted unexpectedly).
export async function refreshStatus(db, id) {
  const v = await read(contracts.hook, 'noteOf', [id]);
  const status = Number(v.status);
  db.prepare('UPDATE notes SET status = ? WHERE id = ?').run(status, id);
  return status;
}
