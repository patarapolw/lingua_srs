import { Deps, Env, HttpError } from './types';
import { checkWriteQuota, writeUsageStatements } from './quota';
import { intSetting, json, readJson } from './util';

const MAX_BATCH = 100;
const MAX_PAGE = 500;
const MAX_RECORD_BYTES = 32 * 1024;
/** A record dated further ahead than this would win every conflict for good. */
const MAX_CLOCK_AHEAD_MS = 24 * 60 * 60 * 1000;

interface Incoming {
  kind: string;
  id: string;
  updatedAt: number;
  deleted: boolean;
  data: string;
}

function parseRecord(value: unknown, now: number): Incoming {
  const bad = () => new HttpError(400, 'invalid_record');
  if (typeof value !== 'object' || value === null || Array.isArray(value)) throw bad();
  const record = value as Record<string, unknown>;
  const { kind, id, updatedAt, deleted, data } = record;
  if (typeof kind !== 'string' || !/^[a-z][a-z0-9_]{0,31}$/.test(kind)) throw bad();
  if (typeof id !== 'string' || id.length < 1 || id.length > 128) throw bad();
  if (!Number.isSafeInteger(updatedAt) || (updatedAt as number) < 0) throw bad();
  if ((updatedAt as number) > now + MAX_CLOCK_AHEAD_MS) throw bad();
  if (typeof deleted !== 'boolean') throw bad();
  if (typeof data !== 'object' || data === null || Array.isArray(data)) throw bad();
  const serialized = deleted ? '{}' : JSON.stringify(data);
  if (new TextEncoder().encode(serialized).length > MAX_RECORD_BYTES) throw bad();
  return { kind, id, updatedAt: updatedAt as number, deleted, data: serialized };
}

function intParam(value: string | null, fallback: number, min: number, max: number): number {
  if (value === null) return fallback;
  if (!/^\d{1,15}$/.test(value)) throw new HttpError(400, 'invalid_query');
  return Math.min(Math.max(Number(value), min), max);
}

/** One page of records changed after the `since` cursor, oldest change first. */
export async function pullChanges(url: URL, email: string, env: Env): Promise<Response> {
  const since = intParam(url.searchParams.get('since'), 0, 0, Number.MAX_SAFE_INTEGER);
  const limit = intParam(url.searchParams.get('limit'), MAX_PAGE, 1, MAX_PAGE);
  const { results } = await env.DB.prepare(
    'SELECT seq, kind, id, updated_at, deleted, data FROM records ' +
      'WHERE email = ?1 AND seq > ?2 ORDER BY seq LIMIT ?3',
  )
    .bind(email, since, limit + 1)
    .all<{ seq: number; kind: string; id: string; updated_at: number; deleted: number; data: string }>();
  const page = results.slice(0, limit);
  return json({
    records: page.map((row) => ({
      kind: row.kind,
      id: row.id,
      updatedAt: row.updated_at,
      deleted: row.deleted === 1,
      data: JSON.parse(row.data),
    })),
    cursor: page.length > 0 ? page[page.length - 1].seq : since,
    hasMore: results.length > limit,
  });
}

/**
 * Stores records. The newest `updatedAt` wins; an older or equal copy is
 * ignored and not counted, so repeating a push is harmless. Every stored
 * change gets the account's next `seq`, which is what devices pull by.
 */
export async function pushChanges(request: Request, email: string, env: Env, deps: Deps): Promise<Response> {
  const body = await readJson(request, 1024 * 1024);
  if (!Array.isArray(body.records) || body.records.length < 1 || body.records.length > MAX_BATCH) {
    throw new HttpError(400, 'invalid_records');
  }
  const now = deps.now();
  const records = body.records.map((record) => parseRecord(record, now));
  await checkWriteQuota(env, email, records.length, intSetting(env.MAX_WRITES_PER_DAY, 2000), now);

  const upserts = records.map((record) =>
    env.DB.prepare(
      'INSERT INTO records (email, kind, id, seq, updated_at, deleted, data) ' +
        'VALUES (?1, ?2, ?3, (SELECT COALESCE(MAX(seq), 0) + 1 FROM records WHERE email = ?1), ?4, ?5, ?6) ' +
        'ON CONFLICT (email, kind, id) DO UPDATE SET ' +
        'seq = excluded.seq, updated_at = excluded.updated_at, deleted = excluded.deleted, data = excluded.data ' +
        'WHERE excluded.updated_at > records.updated_at',
    ).bind(email, record.kind, record.id, record.updatedAt, record.deleted ? 1 : 0, record.data),
  );
  const results = await env.DB.batch([...upserts, ...writeUsageStatements(env, email, records.length, now)]);
  const accepted = results.slice(0, upserts.length).reduce((sum, result) => sum + result.meta.changes, 0);
  return json({ accepted });
}
