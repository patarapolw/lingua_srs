import { env } from 'cloudflare:workers';
import { beforeEach, describe, expect, it } from 'vitest';
import {
  accountStats,
  CHECK_IDS,
  checkDatabase,
  kindStats,
  repairDatabase,
  sqlString,
  type Finding,
  type SqlRunner,
} from '../scripts/repair';
import { DAY, EMAIL, OTHER_EMAIL, START } from './helpers';

/** The script's queries, run on the test database. */
const sql: SqlRunner = {
  all: async (query) => (await env.DB.prepare(query).all<Record<string, unknown>>()).results,
  run: async (query) => (await env.DB.prepare(query).run()).meta.changes,
};

const ENVELOPE = JSON.stringify({ v: 1, n: 'bm9uY2U', c: 'Y2lwaGVy' });

async function exec(...statements: string[]): Promise<void> {
  await env.DB.batch(statements.map((statement) => env.DB.prepare(statement)));
}

function account(email: string, { verifiedAt = START - DAY, createdAt = START - 2 * DAY } = {}): string {
  return (
    'INSERT INTO accounts (email, auth_hash, wrapped_data_key, kdf, verified_at, created_at) ' +
    `VALUES ('${email}', 'h', 'k', '{}', ${verifiedAt ?? 'NULL'}, ${createdAt})`
  );
}

function record(
  email: string,
  id: string,
  seq: number,
  { kind = 'lesson', updatedAt = START - DAY, deleted = 0, data = ENVELOPE } = {},
): string {
  return (
    'INSERT INTO records (email, kind, id, seq, updated_at, deleted, data) VALUES ' +
    `('${email}', '${kind}', ${sqlString(id)}, ${seq}, ${updatedAt}, ${deleted}, ${sqlString(data)})`
  );
}

function found(findings: Finding[]): Record<string, number> {
  return Object.fromEntries(findings.map((finding) => [finding.check, finding.count]));
}

beforeEach(async () => {
  await exec(
    'DELETE FROM pairing_invites',
    'DELETE FROM records',
    'DELETE FROM inbox',
    'DELETE FROM email_codes',
    'DELETE FROM usage',
    'DELETE FROM accounts',
  );
});

describe('checkDatabase', () => {
  it('finds nothing in a healthy database', async () => {
    await exec(
      account(EMAIL),
      record(EMAIL, 'a', 1),
      record(EMAIL, 'b', 2, { deleted: 1, data: '{}' }),
      `INSERT INTO usage (scope, day, n) VALUES ('w:${EMAIL}', '2026-11-03', 4)`,
    );

    expect(await checkDatabase(sql, START)).toEqual([]);
  });

  it('runs every check without an SQL error', async () => {
    // Each check counts and samples; an empty database still runs them all.
    expect(CHECK_IDS.length).toBeGreaterThan(8);
    await expect(checkDatabase(sql, START)).resolves.toEqual([]);
  });

  it('finds records sharing a seq, and moves all but one to the end', async () => {
    await exec(
      account(EMAIL),
      account(OTHER_EMAIL),
      record(EMAIL, 'a', 1),
      record(EMAIL, 'b', 2),
      record(EMAIL, 'c', 2),
      record(EMAIL, 'd', 2),
      record(EMAIL, 'e', 0),
      // Another account's seq 2 is not a clash.
      record(OTHER_EMAIL, 'b', 2),
    );

    const findings = await checkDatabase(sql, START);
    expect(found(findings)).toEqual({ duplicate_seq: 3 });
    expect(findings[0].samples.map((row) => row.id).sort()).toEqual(['c', 'd', 'e']);

    expect(await repairDatabase(sql, findings, START)).toEqual([{ check: 'duplicate_seq', changed: 3 }]);
    expect(await checkDatabase(sql, START)).toEqual([]);
    const { results } = await env.DB.prepare(`SELECT id, seq FROM records WHERE email = ?1 ORDER BY seq`)
      .bind(EMAIL)
      .all<{ id: string; seq: number }>();
    // In seq order: e (seq 0) first, then c and d.
    expect(results.map((row) => row.id)).toEqual(['a', 'b', 'e', 'c', 'd']);
    expect(results.map((row) => row.seq)).toEqual([1, 2, 3, 4, 5]);
  });

  it('reports broken envelopes and invalid rows without changing them', async () => {
    await exec(
      account(EMAIL),
      record(EMAIL, 'not-json', 1, { data: 'nope' }),
      record(EMAIL, 'array', 2, { data: '[]' }),
      record(EMAIL, 'no-cipher', 3, { data: JSON.stringify({ v: 1, n: 'x' }) }),
      record(EMAIL, 'new-version', 4, { data: JSON.stringify({ v: 2, n: 'x', c: 'y' }) }),
      record(EMAIL, 'bad-kind', 5, { kind: 'Lesson' }),
      record(EMAIL, 'future', 6, { updatedAt: START + 2 * DAY }),
      record(EMAIL, 'huge', 7, { data: JSON.stringify({ v: 1, n: 'x', c: 'y'.repeat(33 * 1024) }) }),
    );

    const findings = await checkDatabase(sql, START);
    expect(found(findings)).toEqual({
      bad_envelope: 4,
      invalid_fields: 1,
      future_updated_at: 1,
      oversized_records: 1,
    });
    expect(findings.every((finding) => !finding.repairable)).toBe(true);
    expect(findings.find((finding) => finding.check === 'invalid_fields')!.samples[0].id).toBe('bad-kind');

    expect(await repairDatabase(sql, findings, START)).toEqual([]);
    const { n } = (await env.DB.prepare('SELECT COUNT(*) AS n FROM records').first<{ n: number }>())!;
    expect(n).toBe(7);
  });

  it('empties the data of deleted records', async () => {
    await exec(account(EMAIL), record(EMAIL, 'gone', 1, { deleted: 1 }));

    const findings = await checkDatabase(sql, START);
    expect(found(findings)).toEqual({ tombstone_data: 1 });

    await repairDatabase(sql, findings, START);
    const row = await env.DB.prepare('SELECT data, deleted, seq FROM records').first();
    expect(row).toEqual({ data: '{}', deleted: 1, seq: 1 });
  });

  it('cleans up what the Worker would drop later', async () => {
    const stale = 'stale@example.com';
    await exec(
      account(EMAIL),
      account(stale, { verifiedAt: null as unknown as number, createdAt: START - 8 * DAY }),
      `INSERT INTO email_codes (email, code_hash, expires_at, created_at) VALUES ('${stale}', 'c', ${START - 7 * DAY}, ${START - 8 * DAY})`,
      `INSERT INTO pairing_invites (token_hash, email, payload, expires_at) VALUES ('t1', '${EMAIL}', 'p', ${START - 1})`,
      `INSERT INTO pairing_invites (token_hash, email, payload, expires_at) VALUES ('t2', '${EMAIL}', 'p', ${START + 1})`,
      `INSERT INTO usage (scope, day, n) VALUES ('w:${EMAIL}', '2026-11-02', 9)`,
      `INSERT INTO usage (scope, day, n) VALUES ('w:${EMAIL}', '2026-11-03', 1)`,
      `INSERT INTO usage (scope, day, n) VALUES ('emails', '2026-11-03', 3)`,
    );

    const findings = await checkDatabase(sql, START);
    expect(found(findings)).toEqual({
      stale_unconfirmed: 1,
      expired_email_codes: 1,
      expired_pairing_invites: 1,
      old_usage: 1,
    });

    await repairDatabase(sql, findings, START);
    expect(await checkDatabase(sql, START)).toEqual([]);
    const emails = await env.DB.prepare('SELECT email FROM accounts').all<{ email: string }>();
    expect(emails.results.map((row) => row.email)).toEqual([EMAIL]);
    const invites = await env.DB.prepare('SELECT token_hash FROM pairing_invites').all();
    expect(invites.results).toEqual([{ token_hash: 't2' }]);
    const usage = await env.DB.prepare('SELECT scope, day FROM usage ORDER BY scope').all();
    expect(usage.results).toEqual([
      { scope: 'emails', day: '2026-11-03' },
      { scope: `w:${EMAIL}`, day: '2026-11-03' },
    ]);
  });

  it('keeps a recent unconfirmed signup', async () => {
    await exec(account('new@example.com', { verifiedAt: null as unknown as number, createdAt: START - DAY }));

    expect(await checkDatabase(sql, START)).toEqual([]);
  });

  it('finds and deletes the write counters of a deleted account', async () => {
    await exec(`INSERT INTO usage (scope, day, n) VALUES ('w:gone@example.com', '2026-11-03', 5)`);

    const findings = await checkDatabase(sql, START);
    expect(found(findings)).toEqual({ orphan_usage: 1 });

    await repairDatabase(sql, findings, START);
    expect(await checkDatabase(sql, START)).toEqual([]);
  });

  it('keeps an id with a quote in it intact when moving its seq', async () => {
    await exec(account(EMAIL), record(EMAIL, "it's", 1), record(EMAIL, "it's too", 1));

    await repairDatabase(sql, await checkDatabase(sql, START), START);

    const { results } = await env.DB.prepare('SELECT id, seq FROM records ORDER BY seq').all();
    expect(results).toEqual([
      { id: "it's", seq: 1 },
      { id: "it's too", seq: 2 },
    ]);
  });
});

describe('the daily write limit', () => {
  it("reports accounts that reached today's limit", async () => {
    await exec(
      account(EMAIL),
      account(OTHER_EMAIL),
      `INSERT INTO usage (scope, day, n) VALUES ('w:${EMAIL}', '2026-11-03', 2000)`,
      `INSERT INTO usage (scope, day, n) VALUES ('w:${OTHER_EMAIL}', '2026-11-03', 1999)`,
    );

    const findings = await checkDatabase(sql, START);
    expect(found(findings)).toEqual({ write_limit_reached: 1 });
    expect(findings[0].samples).toEqual([{ email: EMAIL, day: '2026-11-03', writes: 2000 }]);
    expect(findings[0].repairable).toBe(false);

    // A Worker with a lower MAX_WRITES_PER_DAY.
    expect(found(await checkDatabase(sql, START, { writeLimit: 500 }))).toEqual({ write_limit_reached: 2 });
    // Nothing is changed.
    expect(await repairDatabase(sql, findings, START)).toEqual([]);
  });

  it('does not count yesterday', async () => {
    await exec(account(EMAIL), `INSERT INTO usage (scope, day, n) VALUES ('w:${EMAIL}', '2026-11-03', 2500)`);

    expect(found(await checkDatabase(sql, START + DAY))).toEqual({ old_usage: 1 });
  });
});

describe('stats', () => {
  it('counts records, packs, bytes and writes per account and kind', async () => {
    await exec(
      account(EMAIL),
      account(OTHER_EMAIL),
      record(EMAIL, 'a', 1),
      record(EMAIL, 'b', 2, { deleted: 1, data: '{}' }),
      record(EMAIL, 'c', 3, { kind: 'card', updatedAt: START }),
      record(EMAIL, 'p', 4, { kind: 'pack' }),
      `INSERT INTO usage (scope, day, n) VALUES ('w:${EMAIL}', '2026-11-03', 42)`,
      `INSERT INTO usage (scope, day, n) VALUES ('w:${EMAIL}', '2026-11-02', 7)`,
    );

    const accounts = await accountStats(sql, START);
    expect(
      accounts.map((row) => [row.email, row.records, row.deleted, row.max_seq, row.packs, row.writes_today]),
    ).toEqual([
      [OTHER_EMAIL, 0, 0, null, 0, 0],
      [EMAIL, 4, 1, 4, 1, 42],
    ]);
    expect(accounts[1].last_updated_at).toBe(START);
    expect(accounts[1].bytes).toBe(ENVELOPE.length * 3 + 2);
    expect(await accountStats(sql, START, EMAIL)).toHaveLength(1);

    expect(await kindStats(sql, EMAIL)).toEqual([
      { kind: 'card', records: 1, deleted: 0, bytes: ENVELOPE.length },
      { kind: 'lesson', records: 2, deleted: 1, bytes: ENVELOPE.length + 2 },
      { kind: 'pack', records: 1, deleted: 0, bytes: ENVELOPE.length },
    ]);
  });
});
