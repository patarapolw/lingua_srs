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
