// What the repairs in scripts/repair.ts do for devices, seen through the
// Worker's API: the problem as a device meets it, then the repair, then what
// the device gets. test/repair.test.ts covers the checks on the rows.
import { env } from 'cloudflare:workers';
import { describe, expect, it } from 'vitest';
import { checkDatabase, repairDatabase, type SqlRunner } from '../scripts/repair';
import {
  AUTH_KEY,
  DAY,
  EMAIL,
  MINUTE,
  START,
  clearDatabase,
  createConfirmedAccount,
  createWorld,
  lastCode,
  signUp,
} from './helpers';

clearDatabase();

type World = ReturnType<typeof createWorld>;

const sql: SqlRunner = {
  all: async (query) => (await env.DB.prepare(query).all<Record<string, unknown>>()).results,
  run: async (query) => (await env.DB.prepare(query).run()).meta.changes,
};

/** An encrypted envelope, as the app writes it (contents made up). */
function envelope(text: string) {
  return { v: 1, n: 'bm9uY2U', c: btoa(text) };
}

function record(id: string, updatedAt: number, { deleted = false, kind = 'lesson' } = {}) {
  return { kind, id, updatedAt, deleted, data: deleted ? {} : envelope(id) };
}

async function push(world: World, auth: string, ...records: unknown[]) {
  return world.call('POST', '/v1/changes', { auth, body: { records } });
}

/** Pulls like a device: page by page from [since], [limit] at a time. */
async function pullAll(world: World, auth: string, since: number, limit: number) {
  const ids: string[] = [];
  let cursor = since;
  for (;;) {
    const page = (await world.call('GET', `/v1/changes?since=${cursor}&limit=${limit}`, { auth })).body;
    ids.push(...page.records.map((r: { id: string }) => r.id));
    cursor = page.cursor;
    if (!page.hasMore) return { ids, cursor };
  }
}

/** Checks, then repairs what was found, as `check-db --repair` does. */
async function repair(now: number) {
  return repairDatabase(sql, await checkDatabase(sql, now), now);
}

describe('duplicate_seq', () => {
  it('a device that missed a record sharing a seq gets it after the repair', async () => {
    const world = createWorld();
    const auth = await createConfirmedAccount(world);
    await push(world, auth, record('a', 10), record('b', 20), record('c', 30));
    // Damage: c takes b's seq, as a bad manual edit or import could.
    await env.DB.prepare("UPDATE records SET seq = 2 WHERE id = 'c'").run();

    // A device pulling two at a time stops at seq 2 and never sees the
    // other record at seq 2.
    const before = await pullAll(world, auth, 0, 2);
    expect(before.ids).toHaveLength(2);
    expect(before.cursor).toBe(2);
    const missed = ['b', 'c'].find((id) => !before.ids.includes(id))!;
    expect((await pullAll(world, auth, before.cursor, 2)).ids).toEqual([]);

    expect(await repair(START)).toEqual([{ check: 'duplicate_seq', changed: 1 }]);

    // The same device, pulling from where it stopped, now gets it.
    const after = await pullAll(world, auth, before.cursor, 2);
    expect(after.ids).toEqual([missed]);
    // A device that had everything gets it once more, unchanged: the same
    // updatedAt and data, which the app recognises as a version it has.
    const all = (await world.call('GET', '/v1/changes?since=0', { auth })).body.records;
    const moved = all.find((r: { id: string }) => r.id === missed);
    expect(moved).toEqual(record(missed, missed === 'b' ? 20 : 30));
    expect(await checkDatabase(sql, START)).toEqual([]);
  });

  it('keeps later pushes in order after the moved records', async () => {
    const world = createWorld();
    const auth = await createConfirmedAccount(world);
    await push(world, auth, record('a', 10), record('b', 20));
    await env.DB.prepare("UPDATE records SET seq = 1 WHERE id = 'b'").run();
    await repair(START);
    const { cursor } = await pullAll(world, auth, 0, 100);

    await push(world, auth, record('new', 30));

    expect(await pullAll(world, auth, cursor, 100)).toEqual({ ids: ['new'], cursor: cursor + 1 });
  });
});

describe('tombstone_data', () => {
  it('empties a deletion without making devices pull it again', async () => {
    const world = createWorld();
    const auth = await createConfirmedAccount(world);
    await push(world, auth, record('a', 10), record('a', 20, { deleted: true }));
    await env.DB.prepare("UPDATE records SET data = ?1 WHERE id = 'a'").bind(JSON.stringify(envelope('a'))).run();
    const { cursor } = await pullAll(world, auth, 0, 100);

    expect(await repair(START)).toEqual([{ check: 'tombstone_data', changed: 1 }]);

    // Nothing new to pull, and the deletion still reads as a deletion.
    expect((await pullAll(world, auth, cursor, 100)).ids).toEqual([]);
    const [gone] = (await world.call('GET', '/v1/changes?since=0', { auth })).body.records;
    expect(gone).toEqual({ kind: 'lesson', id: 'a', updatedAt: 20, deleted: true, data: {} });
  });
});

describe('cleanups', () => {
  it('a stale unconfirmed signup is dropped, and the email can sign up again', async () => {
    const world = createWorld();
    await signUp(world);
    world.clock.now += 8 * DAY;

    expect((await repair(world.clock.now)).map((r) => r.check)).toEqual(
      expect.arrayContaining(['stale_unconfirmed', 'expired_email_codes']),
    );
    expect(await env.DB.prepare('SELECT COUNT(*) AS n FROM accounts').first('n')).toBe(0);

    await signUp(world);
    const confirmed = await world.call('POST', '/v1/accounts/confirm', {
      body: { email: EMAIL, authKey: AUTH_KEY, code: lastCode(world) },
    });
    expect(confirmed.status).toBe(200);
  });

  it('an expired code is refused the same way before and after the repair', async () => {
    const world = createWorld();
    await signUp(world);
    const code = lastCode(world);
    world.clock.now += 31 * MINUTE;
    const confirm = () =>
      world.call('POST', '/v1/accounts/confirm', { body: { email: EMAIL, authKey: AUTH_KEY, code } });

    const before = await confirm();
    await repair(world.clock.now);
    const after = await confirm();

    expect(before).toMatchObject({ status: 400, body: { error: 'invalid_code' } });
    expect(after).toMatchObject({ status: 400, body: { error: 'invalid_code' } });
    // Signing up again sends a code that works; the recent signup was kept.
    await signUp(world);
    const confirmed = await world.call('POST', '/v1/accounts/confirm', {
      body: { email: EMAIL, authKey: AUTH_KEY, code: lastCode(world) },
    });
    expect(confirmed.status).toBe(200);
  });

  it('an expired pairing invite stays refused, and a live one still works', async () => {
    const world = createWorld();
    const auth = await createConfirmedAccount(world);
    const old = (await world.call('POST', '/v1/account/pairing', { auth, body: { payload: 'old' } })).body;
    world.clock.now += 11 * MINUTE;
    // Written straight in: a new invite through the API drops the old one itself.
    await env.DB.prepare(
      "INSERT INTO pairing_invites (token_hash, email, payload, expires_at) VALUES ('live', ?1, 'p', ?2)",
    )
      .bind(EMAIL, world.clock.now + MINUTE)
      .run();

    expect(await repair(world.clock.now)).toEqual([{ check: 'expired_pairing_invites', changed: 1 }]);

    expect((await world.call('GET', `/v1/pairings/${old.token}`)).status).toBe(404);
    const left = await env.DB.prepare('SELECT token_hash FROM pairing_invites').all();
    expect(left.results).toEqual([{ token_hash: 'live' }]);
  });
});

describe('the daily write limit', () => {
  it("clearing old counters does not reset today's limit", async () => {
    const world = createWorld({ MAX_WRITES_PER_DAY: '2' });
    const auth = await createConfirmedAccount(world);
    await push(world, auth, record('a', 1));
    world.clock.now += DAY;
    await push(world, auth, record('b', 1), record('c', 1));
    expect((await push(world, auth, record('d', 1))).status).toBe(429);

    const repaired = await repair(world.clock.now);

    // Yesterday's counter goes; today's stays, and still stops a push.
    expect(repaired.map((r) => r.check)).not.toContain('write_limit_reached');
    expect((await push(world, auth, record('d', 1))).status).toBe(429);
  });

  it('is reported, and the SQL in docs/admin.md lets the account finish today', async () => {
    const world = createWorld({ MAX_WRITES_PER_DAY: '2' });
    const auth = await createConfirmedAccount(world);
    await push(world, auth, record('a', 1), record('b', 1));
    expect((await push(world, auth, record('c', 1))).status).toBe(429);

    const findings = await checkDatabase(sql, world.clock.now, { writeLimit: 2 });
    expect(findings.map((f) => [f.check, f.repairable])).toEqual([['write_limit_reached', false]]);
    // --repair leaves the limit alone.
    expect(await repairDatabase(sql, findings, world.clock.now)).toEqual([]);
    expect((await push(world, auth, record('c', 1))).status).toBe(429);

    const today = new Date(world.clock.now).toISOString().slice(0, 10);
    await env.DB.prepare(`DELETE FROM usage WHERE scope='w:${EMAIL}' AND day='${today}'`).run();

    expect((await push(world, auth, record('c', 1))).status).toBe(200);
  });
});

describe('what is only reported', () => {
  it('leaves a broken record for devices to skip, as before', async () => {
    const world = createWorld();
    const auth = await createConfirmedAccount(world);
    await push(world, auth, record('ok', 10), { kind: 'lesson', id: 'broken', updatedAt: 20, deleted: false, data: { x: 1 } });

    const findings = await checkDatabase(sql, START);
    expect(findings.map((f) => f.check)).toEqual(['bad_envelope']);
    expect(await repairDatabase(sql, findings, START)).toEqual([]);

    const ids = (await world.call('GET', '/v1/changes?since=0', { auth })).body.records.map((r: { id: string }) => r.id);
    expect(ids).toEqual(['ok', 'broken']);
  });

  it('a second repair finds nothing left to do', async () => {
    const world = createWorld();
    const auth = await createConfirmedAccount(world);
    await push(world, auth, record('a', 10), record('b', 20), record('c', 30, { deleted: true }));
    await env.DB.batch([
      env.DB.prepare("UPDATE records SET seq = 1 WHERE id = 'b'"),
      env.DB.prepare(`UPDATE records SET data = '{"v":1}' WHERE id = 'c'`),
    ]);

    expect((await repair(START)).length).toBe(2);
    expect(await checkDatabase(sql, START)).toEqual([]);
    expect(await repair(START)).toEqual([]);
  });
});
