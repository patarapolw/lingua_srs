import { env } from 'cloudflare:workers';
import { describe, expect, it } from 'vitest';
import {
  AUTH_KEY,
  DAY,
  EMAIL,
  OTHER_AUTH_KEY,
  OTHER_EMAIL,
  basic,
  clearDatabase,
  createConfirmedAccount,
  createWorld,
  signUp,
} from './helpers';

clearDatabase();

const RECOVERY_KEY = 'R'.repeat(43);
const OTHER_RECOVERY_KEY = 'S'.repeat(43);
const RECOVERY_WRAPPED = 'cmVjb3Zlcnktd3JhcHBlZC1rZXk';

function recoveryRow(email = EMAIL) {
  return env.DB.prepare(
    'SELECT recovery_hash, recovery_wrapped_data_key, recovery_created_at FROM accounts WHERE email = ?1',
  )
    .bind(email)
    .first<{
      recovery_hash: string | null;
      recovery_wrapped_data_key: string | null;
      recovery_created_at: number | null;
    }>();
}

async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, '0')).join('');
}

describe('setting a recovery code', () => {
  it('stores only a hash of the recovery key and the wrapped data key', async () => {
    const world = createWorld();
    const auth = await createConfirmedAccount(world);

    const result = await world.call('PUT', '/v1/account/recovery', {
      auth,
      body: { recoveryKey: RECOVERY_KEY, wrappedDataKey: RECOVERY_WRAPPED },
    });

    expect(result.status).toBe(200);
    expect(result.body).toEqual({ status: 'ok', createdAt: world.clock.now });
    const row = await recoveryRow();
    expect(row!.recovery_hash).toBe(await sha256Hex(RECOVERY_KEY));
    expect(row!.recovery_wrapped_data_key).toBe(RECOVERY_WRAPPED);
    expect(row!.recovery_created_at).toBe(world.clock.now);
    const all = await env.DB.prepare('SELECT * FROM accounts').all();
    expect(JSON.stringify(all.results)).not.toContain(RECOVERY_KEY);
  });

  it('replaces the previous code', async () => {
    const world = createWorld();
    const auth = await createConfirmedAccount(world);
    await world.call('PUT', '/v1/account/recovery', {
      auth,
      body: { recoveryKey: RECOVERY_KEY, wrappedDataKey: RECOVERY_WRAPPED },
    });

    world.clock.now += DAY;
    await world.call('PUT', '/v1/account/recovery', {
      auth,
      body: { recoveryKey: OTHER_RECOVERY_KEY, wrappedDataKey: 'bmV3ZXI' },
    });

    const row = await recoveryRow();
    expect(row!.recovery_hash).toBe(await sha256Hex(OTHER_RECOVERY_KEY));
    expect(row!.recovery_wrapped_data_key).toBe('bmV3ZXI');
    expect(row!.recovery_created_at).toBe(world.clock.now);
  });

  it('leaves the password, the data key and the data alone', async () => {
    const world = createWorld();
    const auth = await createConfirmedAccount(world);
    const before = await world.call('GET', '/v1/account', { auth });

    await world.call('PUT', '/v1/account/recovery', {
      auth,
      body: { recoveryKey: RECOVERY_KEY, wrappedDataKey: RECOVERY_WRAPPED },
    });

    const after = await world.call('GET', '/v1/account', { auth });
    expect(after.status).toBe(200);
    expect(after.body).toEqual(before.body);
  });

  it('keeps the code through a password change, which re-wraps the same data key', async () => {
    const world = createWorld();
    const auth = await createConfirmedAccount(world);
    await world.call('PUT', '/v1/account/recovery', {
      auth,
      body: { recoveryKey: RECOVERY_KEY, wrappedDataKey: RECOVERY_WRAPPED },
    });

    await world.call('PUT', '/v1/account', {
      auth,
      body: { authKey: OTHER_AUTH_KEY, wrappedDataKey: 'bmV3LXdyYXBwZWQta2V5' },
    });

    expect((await recoveryRow())!.recovery_hash).toBe(await sha256Hex(RECOVERY_KEY));
  });

  it('only changes the signed-in account', async () => {
    const world = createWorld();
    const auth = await createConfirmedAccount(world);
    await createConfirmedAccount(world, OTHER_EMAIL, OTHER_AUTH_KEY);

    await world.call('PUT', '/v1/account/recovery', {
      auth,
      body: { recoveryKey: RECOVERY_KEY, wrappedDataKey: RECOVERY_WRAPPED },
    });

    expect((await recoveryRow(OTHER_EMAIL))!.recovery_hash).toBeNull();
  });

  it('needs valid credentials and a confirmed account', async () => {
    const world = createWorld();
    const body = { recoveryKey: RECOVERY_KEY, wrappedDataKey: RECOVERY_WRAPPED };

    expect((await world.call('PUT', '/v1/account/recovery', { body })).status).toBe(401);
    await signUp(world);
    expect(
      (await world.call('PUT', '/v1/account/recovery', { auth: basic(EMAIL, AUTH_KEY), body }))
        .status,
    ).toBe(403);
    expect(
      (await world.call('PUT', '/v1/account/recovery', { auth: basic(EMAIL, OTHER_AUTH_KEY), body }))
        .status,
    ).toBe(401);
    expect((await recoveryRow())!.recovery_hash).toBeNull();
  });

  it('rejects an unusable recovery key or wrapped key', async () => {
    const world = createWorld();
    const auth = await createConfirmedAccount(world);
    const good = { recoveryKey: RECOVERY_KEY, wrappedDataKey: RECOVERY_WRAPPED };
    for (const bad of [
      { ...good, recoveryKey: 'short' },
      { ...good, recoveryKey: undefined },
      { ...good, wrappedDataKey: '' },
      { ...good, wrappedDataKey: 'has spaces' },
    ]) {
      const result = await world.call('PUT', '/v1/account/recovery', { auth, body: bad });
      expect(result.status, JSON.stringify(bad)).toBe(400);
      expect(result.body).toEqual({ error: 'invalid_recovery' });
    }
    expect((await recoveryRow())!.recovery_hash).toBeNull();
  });

  it('only accepts PUT', async () => {
    const world = createWorld();
    const auth = await createConfirmedAccount(world);

    const result = await world.call('GET', '/v1/account/recovery', { auth });

    expect(result.status).toBe(405);
  });

  it('counts as a write against the daily limit', async () => {
    const world = createWorld({ MAX_WRITES_PER_DAY: '1' });
    const auth = await createConfirmedAccount(world);
    const body = { recoveryKey: RECOVERY_KEY, wrappedDataKey: RECOVERY_WRAPPED };

    expect((await world.call('PUT', '/v1/account/recovery', { auth, body })).status).toBe(200);
    const refused = await world.call('PUT', '/v1/account/recovery', {
      auth,
      body: { recoveryKey: OTHER_RECOVERY_KEY, wrappedDataKey: RECOVERY_WRAPPED },
    });

    expect(refused.status).toBe(429);
    expect(refused.body).toEqual({ error: 'quota_exceeded' });
    expect((await recoveryRow())!.recovery_hash).toBe(await sha256Hex(RECOVERY_KEY));
  });

  it('is forgotten when a pending signup is replaced', async () => {
    const world = createWorld();
    await signUp(world);
    // Recovery can only be set on a confirmed account; put a stale value in
    // by hand to check that a repeated signup clears it.
    await env.DB.prepare("UPDATE accounts SET recovery_hash = 'x' WHERE email = ?1").bind(EMAIL).run();

    await signUp(world, EMAIL, OTHER_AUTH_KEY);

    expect((await recoveryRow())!.recovery_hash).toBeNull();
  });

  it('is deleted with the account', async () => {
    const world = createWorld();
    const auth = await createConfirmedAccount(world);
    await world.call('PUT', '/v1/account/recovery', {
      auth,
      body: { recoveryKey: RECOVERY_KEY, wrappedDataKey: RECOVERY_WRAPPED },
    });

    expect((await world.call('DELETE', '/v1/account', { auth })).status).toBe(204);

    expect(await recoveryRow()).toBeNull();
  });
});

describe('recovering an account with its code', () => {
  const NEW_AUTH_KEY = 'N'.repeat(43);
  const NEW_WRAPPED = 'bmV3LXBhc3N3b3JkLXdyYXBwZWQ';
  const KDF = { alg: 'argon2id', memoryKiB: 65536, passes: 3, lanes: 1 };

  async function accountWithCode(world: ReturnType<typeof createWorld>) {
    const auth = await createConfirmedAccount(world);
    await world.call('PUT', '/v1/account/recovery', {
      auth,
      body: { recoveryKey: RECOVERY_KEY, wrappedDataKey: RECOVERY_WRAPPED },
    });
    return auth;
  }

  function start(world: ReturnType<typeof createWorld>, body: unknown) {
    return world.call('POST', '/v1/accounts/recovery', { body });
  }

  function complete(world: ReturnType<typeof createWorld>, body: Record<string, unknown> = {}) {
    return world.call('POST', '/v1/accounts/recovery/complete', {
      body: {
        email: EMAIL,
        recoveryKey: RECOVERY_KEY,
        authKey: NEW_AUTH_KEY,
        wrappedDataKey: NEW_WRAPPED,
        kdf: KDF,
        ...body,
      },
    });
  }

  it('returns the recovery-wrapped data key for the right code, without signing in', async () => {
    const world = createWorld();
    await accountWithCode(world);

    const result = await start(world, { email: 'Reader@Example.com', recoveryKey: RECOVERY_KEY });

    expect(result.status).toBe(200);
    expect(result.body).toEqual({ wrappedDataKey: RECOVERY_WRAPPED });
  });

  it('gives one answer for a wrong code, an unknown email, no code, or a bad request', async () => {
    const world = createWorld();
    await accountWithCode(world);
    await createConfirmedAccount(world, OTHER_EMAIL, OTHER_AUTH_KEY);
    const pending = 'pending@example.com';
    await signUp(world, pending);

    const answers = [
      await start(world, { email: EMAIL, recoveryKey: OTHER_RECOVERY_KEY }),
      await start(world, { email: 'nobody@example.com', recoveryKey: RECOVERY_KEY }),
      await start(world, { email: OTHER_EMAIL, recoveryKey: RECOVERY_KEY }),
      await start(world, { email: pending, recoveryKey: RECOVERY_KEY }),
      await start(world, { email: EMAIL, recoveryKey: 'short' }),
      await start(world, { email: 'not an email', recoveryKey: RECOVERY_KEY }),
      await start(world, { email: EMAIL }),
      await start(world, 'not an object'),
      await world.call('POST', '/v1/accounts/recovery', {}),
    ];

    for (const answer of answers) {
      expect(answer.status).toBe(400);
      expect(answer.body).toEqual({ error: 'invalid_recovery' });
    }
  });

  it('does not take a code from an unconfirmed account', async () => {
    const world = createWorld();
    await signUp(world);
    // Only a confirmed account can set a code; put one in by hand.
    await env.DB.prepare(
      'UPDATE accounts SET recovery_hash = ?2, recovery_wrapped_data_key = ?3 WHERE email = ?1',
    )
      .bind(EMAIL, await sha256Hex(RECOVERY_KEY), RECOVERY_WRAPPED)
      .run();

    expect((await start(world, { email: EMAIL, recoveryKey: RECOVERY_KEY })).status).toBe(400);
    expect((await complete(world)).status).toBe(400);
  });

  it('replaces the password, keeps the data and createdAt, and uses up the code', async () => {
    const world = createWorld();
    const oldAuth = await accountWithCode(world);
    await world.call('POST', '/v1/changes', {
      auth: oldAuth,
      body: { records: [{ kind: 'lesson', id: 'a', updatedAt: 1, deleted: false, data: { n: 1 } }] },
    });
    const invite = await world.call('POST', '/v1/account/pairing', {
      auth: oldAuth,
      body: { payload: 'encrypted' },
    });

    const result = await complete(world);

    expect(result.status).toBe(200);
    expect(result.body).toEqual({ status: 'ok' });
    // Other devices are signed out, as after a password change.
    expect((await world.call('GET', '/v1/account', { auth: oldAuth })).status).toBe(401);
    const newAuth = basic(EMAIL, NEW_AUTH_KEY);
    const account = await world.call('GET', '/v1/account', { auth: newAuth });
    expect(account.body).toEqual({ wrappedDataKey: NEW_WRAPPED, kdf: KDF, createdAt: expect.any(Number) });
    expect((await world.call('GET', '/v1/changes', { auth: newAuth })).body.records).toHaveLength(1);
    expect((await world.call('GET', `/v1/pairings/${invite.body.token}`)).status).toBe(404);
    const row = await recoveryRow();
    expect(row).toEqual({
      recovery_hash: null,
      recovery_wrapped_data_key: null,
      recovery_created_at: null,
    });
    // The used code works no more.
    expect((await start(world, { email: EMAIL, recoveryKey: RECOVERY_KEY })).status).toBe(400);
    expect((await complete(world, { authKey: OTHER_AUTH_KEY })).status).toBe(400);
    expect((await world.call('GET', '/v1/account', { auth: newAuth })).status).toBe(200);
  });

  it('keeps createdAt, so other devices see the same account', async () => {
    const world = createWorld();
    const oldAuth = await accountWithCode(world);
    const before = await world.call('GET', '/v1/account', { auth: oldAuth });

    world.clock.now += DAY;
    await complete(world);

    const after = await world.call('GET', '/v1/account', { auth: basic(EMAIL, NEW_AUTH_KEY) });
    expect(after.body.createdAt).toBe(before.body.createdAt);
  });

  it('changes nothing for a wrong code or a bad new key', async () => {
    const world = createWorld();
    const oldAuth = await accountWithCode(world);

    for (const bad of [
      { recoveryKey: OTHER_RECOVERY_KEY },
      { email: OTHER_EMAIL },
      { authKey: 'short' },
      { wrappedDataKey: '' },
      { kdf: 'argon2id' },
    ]) {
      const result = await complete(world, bad);
      expect(result.status, JSON.stringify(bad)).toBe(400);
      expect(result.body).toEqual({ error: 'invalid_recovery' });
    }

    expect((await world.call('GET', '/v1/account', { auth: oldAuth })).status).toBe(200);
    expect((await recoveryRow())!.recovery_hash).toBe(await sha256Hex(RECOVERY_KEY));
  });

  it('only works with the newest code', async () => {
    const world = createWorld();
    const auth = await accountWithCode(world);
    await world.call('PUT', '/v1/account/recovery', {
      auth,
      body: { recoveryKey: OTHER_RECOVERY_KEY, wrappedDataKey: 'bmV3ZXI' },
    });

    expect((await start(world, { email: EMAIL, recoveryKey: RECOVERY_KEY })).status).toBe(400);
    const newest = await start(world, { email: EMAIL, recoveryKey: OTHER_RECOVERY_KEY });
    expect(newest.body).toEqual({ wrappedDataKey: 'bmV3ZXI' });
  });

  it('only accepts POST', async () => {
    const world = createWorld();

    expect((await world.call('GET', '/v1/accounts/recovery')).status).toBe(405);
    expect((await world.call('PUT', '/v1/accounts/recovery/complete')).status).toBe(405);
  });
});
