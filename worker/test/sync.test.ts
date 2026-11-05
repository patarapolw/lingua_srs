import { describe, expect, it } from 'vitest';
import {
  DAY,
  OTHER_AUTH_KEY,
  OTHER_EMAIL,
  clearDatabase,
  createConfirmedAccount,
  createWorld,
  START,
} from './helpers';

clearDatabase();

type World = ReturnType<typeof createWorld>;

function record(id: string, updatedAt: number, data: Record<string, unknown> = { n: updatedAt }, kind = 'lesson') {
  return { kind, id, updatedAt, deleted: false, data };
}

async function push(world: World, auth: string, ...records: unknown[]) {
  return world.call('POST', '/v1/changes', { auth, body: { records } });
}

describe('pushing and pulling changes', () => {
  it('returns what was pushed, in the shape the app expects', async () => {
    const world = createWorld();
    const auth = await createConfirmedAccount(world);

    const pushed = await push(world, auth, record('a', 100, { title: 'Hello' }), record('b', 200));
    expect(pushed.status).toBe(200);
    expect(pushed.body).toEqual({ accepted: 2 });

    const pulled = await world.call('GET', '/v1/changes?since=0', { auth });
    expect(pulled.status).toBe(200);
    expect(pulled.body).toEqual({
      records: [
        { kind: 'lesson', id: 'a', updatedAt: 100, deleted: false, data: { title: 'Hello' } },
        { kind: 'lesson', id: 'b', updatedAt: 200, deleted: false, data: { n: 200 } },
      ],
      cursor: 2,
      hasMore: false,
    });
  });

  it('keeps the newest copy and ignores older or equal ones', async () => {
    const world = createWorld();
    const auth = await createConfirmedAccount(world);
    await push(world, auth, record('a', 200, { v: 'new' }));

    expect((await push(world, auth, record('a', 100, { v: 'old' }))).body).toEqual({ accepted: 0 });
    expect((await push(world, auth, record('a', 200, { v: 'same time' }))).body).toEqual({ accepted: 0 });
    expect((await push(world, auth, record('a', 300, { v: 'newer' }))).body).toEqual({ accepted: 1 });

    const { records } = (await world.call('GET', '/v1/changes', { auth })).body;
    expect(records).toHaveLength(1);
    expect(records[0].data).toEqual({ v: 'newer' });
  });

  it('is safe to repeat the same push', async () => {
    const world = createWorld();
    const auth = await createConfirmedAccount(world);
    await push(world, auth, record('a', 100));

    expect((await push(world, auth, record('a', 100))).body).toEqual({ accepted: 0 });
  });

  it('settles two copies of a record in one push by their dates', async () => {
    const world = createWorld();
    const auth = await createConfirmedAccount(world);

    await push(world, auth, record('a', 200, { v: 'later' }), record('a', 100, { v: 'earlier' }));

    const { records } = (await world.call('GET', '/v1/changes', { auth })).body;
    expect(records.map((r: { data: unknown }) => r.data)).toEqual([{ v: 'later' }]);
  });

  it('keeps a deletion as a tombstone without data', async () => {
    const world = createWorld();
    const auth = await createConfirmedAccount(world);
    await push(world, auth, record('a', 100, { secret: 'x' }));

    await push(world, auth, { kind: 'lesson', id: 'a', updatedAt: 200, deleted: true, data: { ignored: 1 } });

    const { records } = (await world.call('GET', '/v1/changes', { auth })).body;
    expect(records).toEqual([{ kind: 'lesson', id: 'a', updatedAt: 200, deleted: true, data: {} }]);
  });

  it('keeps kinds apart', async () => {
    const world = createWorld();
    const auth = await createConfirmedAccount(world);

    await push(world, auth, record('1', 100, {}, 'lesson'), record('1', 100, {}, 'sentence'));

    expect((await world.call('GET', '/v1/changes', { auth })).body.records).toHaveLength(2);
  });

  it('lists an updated record again after the cursor a device already has', async () => {
    const world = createWorld();
    const auth = await createConfirmedAccount(world);
    await push(world, auth, record('a', 100), record('b', 100));
    const first = (await world.call('GET', '/v1/changes?since=0', { auth })).body;

    await push(world, auth, record('a', 200, { n: 'edited' }));

    const next = (await world.call('GET', `/v1/changes?since=${first.cursor}`, { auth })).body;
    expect(next.records.map((r: { id: string }) => r.id)).toEqual(['a']);
    expect(next.records[0].data).toEqual({ n: 'edited' });
    expect(next.cursor).toBeGreaterThan(first.cursor);
  });

  it('pages through changes with the cursor', async () => {
    const world = createWorld();
    const auth = await createConfirmedAccount(world);
    await push(world, auth, ...['a', 'b', 'c', 'd', 'e'].map((id) => record(id, 100)));

    const seen: string[] = [];
    let cursor = 0;
    let pages = 0;
    for (;;) {
      const page = (await world.call('GET', `/v1/changes?since=${cursor}&limit=2`, { auth })).body;
      seen.push(...page.records.map((r: { id: string }) => r.id));
      cursor = page.cursor;
      pages++;
      if (!page.hasMore) break;
    }

    expect(seen).toEqual(['a', 'b', 'c', 'd', 'e']);
    expect(pages).toBe(3);
    const empty = (await world.call('GET', `/v1/changes?since=${cursor}`, { auth })).body;
    expect(empty).toEqual({ records: [], cursor, hasMore: false });
  });

  it('keeps accounts apart', async () => {
    const world = createWorld();
    const mine = await createConfirmedAccount(world);
    const theirs = await createConfirmedAccount(world, OTHER_EMAIL, OTHER_AUTH_KEY);
    await push(world, mine, record('a', 100, { owner: 'me' }));
    await push(world, theirs, record('a', 50, { owner: 'them' }));

    expect((await world.call('GET', '/v1/changes', { auth: mine })).body.records[0].data).toEqual({ owner: 'me' });
    expect((await world.call('GET', '/v1/changes', { auth: theirs })).body.records[0].data).toEqual({
      owner: 'them',
    });
  });

  it('rejects bad batches and records', async () => {
    const world = createWorld();
    const auth = await createConfirmedAccount(world);
    const tooMany = Array.from({ length: 101 }, (_, i) => record(`r${i}`, 1));
    const bad = [
      { records: [] },
      { records: tooMany },
      { records: 'nope' },
      { records: [record('a', 1, {}, 'Bad Kind')] },
      { records: [{ ...record('a', 1), id: '' }] },
      { records: [{ ...record('a', 1), id: 'x'.repeat(129) }] },
      { records: [{ ...record('a', 1), updatedAt: -1 }] },
      { records: [{ ...record('a', 1), updatedAt: 1.5 }] },
      { records: [{ ...record('a', 1), updatedAt: START + 2 * DAY }] },
      { records: [{ ...record('a', 1), deleted: 'no' }] },
      { records: [{ ...record('a', 1), data: [] }] },
      { records: [record('a', 1, { blob: 'x'.repeat(33 * 1024) })] },
    ];
    for (const body of bad) {
      const result = await world.call('POST', '/v1/changes', { auth, body });
      expect(result.status, JSON.stringify(body).slice(0, 80)).toBe(400);
    }
    expect((await world.call('GET', '/v1/changes?since=abc', { auth })).status).toBe(400);
  });

  it('accepts exactly 100 records in a batch', async () => {
    const world = createWorld();
    const auth = await createConfirmedAccount(world);

    const result = await push(world, auth, ...Array.from({ length: 100 }, (_, i) => record(`r${i}`, 1)));

    expect(result.body).toEqual({ accepted: 100 });
  });
});

describe('the daily write limit', () => {
  it('refuses writes past the limit with a Retry-After, and allows them the next day', async () => {
    const world = createWorld({ MAX_WRITES_PER_DAY: '3' });
    const auth = await createConfirmedAccount(world);

    expect((await push(world, auth, record('a', 1), record('b', 1))).status).toBe(200);
    const refused = await push(world, auth, record('c', 1), record('d', 1));
    expect(refused.status).toBe(429);
    expect(refused.body).toEqual({ error: 'quota_exceeded' });
    expect(Number(refused.headers.get('Retry-After'))).toBeGreaterThan(0);
    expect((await push(world, auth, record('c', 1))).status).toBe(200);
    expect((await push(world, auth, record('d', 1))).status).toBe(429);

    world.clock.now += DAY;
    expect((await push(world, auth, record('d', 1))).status).toBe(200);
  });

  it('is counted per account', async () => {
    const world = createWorld({ MAX_WRITES_PER_DAY: '1' });
    const mine = await createConfirmedAccount(world);
    const theirs = await createConfirmedAccount(world, OTHER_EMAIL, OTHER_AUTH_KEY);

    expect((await push(world, mine, record('a', 1))).status).toBe(200);
    expect((await push(world, mine, record('b', 1))).status).toBe(429);
    expect((await push(world, theirs, record('a', 1))).status).toBe(200);
  });

  it('does not limit reading', async () => {
    const world = createWorld({ MAX_WRITES_PER_DAY: '1' });
    const auth = await createConfirmedAccount(world);
    await push(world, auth, record('a', 1));
    await push(world, auth, record('b', 1));

    expect((await world.call('GET', '/v1/changes', { auth })).status).toBe(200);
  });
});

describe('the inbox', () => {
  it('lists items in order and removes them when asked', async () => {
    const world = createWorld();
    const auth = await createConfirmedAccount(world);
    const first = await world.call('POST', '/v1/inbox', { auth, body: { text: 'cipher one' } });
    world.clock.now += 1000;
    const second = await world.call('POST', '/v1/inbox', { auth, body: { text: 'cipher two' } });
    expect(first.status).toBe(201);
    expect(first.body.id).toMatch(/^[0-9a-f-]{36}$/);

    const listed = await world.call('GET', '/v1/inbox', { auth });
    expect(listed.body.items).toEqual([
      { id: first.body.id, text: 'cipher one', createdAt: START },
      { id: second.body.id, text: 'cipher two', createdAt: START + 1000 },
    ]);

    expect((await world.call('DELETE', `/v1/inbox/${first.body.id}`, { auth })).status).toBe(204);
    expect((await world.call('DELETE', `/v1/inbox/${first.body.id}`, { auth })).status).toBe(204);
    expect((await world.call('GET', '/v1/inbox', { auth })).body.items.map((i: { id: string }) => i.id)).toEqual([
      second.body.id,
    ]);
  });

  it('keeps accounts apart', async () => {
    const world = createWorld();
    const mine = await createConfirmedAccount(world);
    const theirs = await createConfirmedAccount(world, OTHER_EMAIL, OTHER_AUTH_KEY);
    const item = await world.call('POST', '/v1/inbox', { auth: mine, body: { text: 'mine' } });

    expect((await world.call('GET', '/v1/inbox', { auth: theirs })).body.items).toEqual([]);
    await world.call('DELETE', `/v1/inbox/${item.body.id}`, { auth: theirs });
    expect((await world.call('GET', '/v1/inbox', { auth: mine })).body.items).toHaveLength(1);
  });

  it('rejects empty and oversized items, and stops at 100', async () => {
    const world = createWorld();
    const auth = await createConfirmedAccount(world);

    expect((await world.call('POST', '/v1/inbox', { auth, body: { text: '' } })).status).toBe(400);
    expect((await world.call('POST', '/v1/inbox', { auth, body: { text: 5 } })).status).toBe(400);
    expect(
      (await world.call('POST', '/v1/inbox', { auth, body: { text: 'x'.repeat(64 * 1024 + 1) } })).status,
    ).toBe(400);

    for (let i = 0; i < 100; i++) {
      expect((await world.call('POST', '/v1/inbox', { auth, body: { text: `item ${i}` } })).status).toBe(201);
    }
    const full = await world.call('POST', '/v1/inbox', { auth, body: { text: 'one too many' } });
    expect(full.status).toBe(429);
    expect(full.body).toEqual({ error: 'inbox_full' });
  });

  it('counts toward the daily write limit', async () => {
    const world = createWorld({ MAX_WRITES_PER_DAY: '1' });
    const auth = await createConfirmedAccount(world);

    expect((await world.call('POST', '/v1/inbox', { auth, body: { text: 'a' } })).status).toBe(201);
    expect((await world.call('POST', '/v1/inbox', { auth, body: { text: 'b' } })).status).toBe(429);
  });
});

describe('routing', () => {
  it('needs credentials for everything except creating and confirming an account', async () => {
    const world = createWorld();
    for (const [method, path] of [
      ['GET', '/v1/account'],
      ['GET', '/v1/changes'],
      ['POST', '/v1/changes'],
      ['GET', '/v1/inbox'],
      ['DELETE', '/v1/inbox/x'],
    ]) {
      expect((await world.call(method, path)).status, `${method} ${path}`).toBe(401);
    }
  });

  it('answers unknown paths with 404 and wrong methods with 405', async () => {
    const world = createWorld();
    const auth = await createConfirmedAccount(world);

    expect((await world.call('GET', '/nope', { auth })).status).toBe(404);
    expect((await world.call('GET', '/v1/nope', { auth })).status).toBe(404);
    const wrong = await world.call('PATCH', '/v1/changes', { auth });
    expect(wrong.status).toBe(405);
    expect(wrong.headers.get('Allow')).toBe('GET, POST');
    expect((await world.call('GET', '/v1/accounts')).status).toBe(405);
  });

  it('accepts a trailing slash and never caches', async () => {
    const world = createWorld();
    const auth = await createConfirmedAccount(world);

    const result = await world.call('GET', '/v1/changes/', { auth });

    expect(result.status).toBe(200);
    expect(result.headers.get('Cache-Control')).toBe('no-store');
  });

  it('answers malformed JSON with 400', async () => {
    const world = createWorld();
    const auth = await createConfirmedAccount(world);

    const result = await world.call('POST', '/v1/changes', { auth, body: 'not an object' });

    expect(result.status).toBe(400);
    expect(result.body).toEqual({ error: 'invalid_json' });
  });
});
