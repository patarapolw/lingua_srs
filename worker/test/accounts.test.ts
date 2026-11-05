import { env } from 'cloudflare:workers';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { createMailSender } from '../src/mail';
import type { Env } from '../src/types';
import {
  AUTH_KEY,
  DAY,
  EMAIL,
  MINUTE,
  OTHER_AUTH_KEY,
  OTHER_EMAIL,
  accountBody,
  basic,
  clearDatabase,
  createConfirmedAccount,
  createWorld,
  lastCode,
  signUp,
} from './helpers';

clearDatabase();

async function confirm(world: ReturnType<typeof createWorld>, code: string, authKey = AUTH_KEY) {
  return world.call('POST', '/v1/accounts/confirm', { body: { email: EMAIL, authKey, code } });
}

describe('creating an account', () => {
  it('emails an 8 digit code and answers 202', async () => {
    const world = createWorld();

    const result = await signUp(world);

    expect(result.status).toBe(202);
    expect(result.body).toEqual({ status: 'confirmation_sent' });
    expect(world.mails).toHaveLength(1);
    expect(world.mails[0].to).toBe(EMAIL);
    expect(lastCode(world)).toMatch(/^\d{8}$/);
  });

  it('stores only a hash of the auth key', async () => {
    const world = createWorld();
    await signUp(world);

    const row = await env.DB.prepare('SELECT * FROM accounts').first<Record<string, unknown>>();

    expect(row).not.toBeNull();
    expect(JSON.stringify(row)).not.toContain(AUTH_KEY);
    expect(row!.verified_at).toBeNull();
  });

  it('lowercases the email', async () => {
    const world = createWorld();

    await world.call('POST', '/v1/accounts', { body: accountBody('Reader@Example.COM') });

    expect(world.mails[0].to).toBe(EMAIL);
  });

  it('rejects an unusable email, auth key, wrapped key or kdf', async () => {
    const world = createWorld();
    const good = accountBody();
    for (const bad of [
      { ...good, email: 'nope' },
      { ...good, authKey: 'short' },
      { ...good, wrappedDataKey: '' },
      { ...good, wrappedDataKey: 'has spaces' },
      { ...good, kdf: 'argon2id' },
      { ...good, kdf: {} },
    ]) {
      const result = await world.call('POST', '/v1/accounts', { body: bad });
      expect(result.status, JSON.stringify(bad)).toBe(400);
    }
    expect(world.mails).toHaveLength(0);
  });

  it('answers the same for an email that already has an account, and sends nothing', async () => {
    const world = createWorld();
    const auth = await createConfirmedAccount(world);
    world.mails.length = 0;

    const result = await signUp(world, EMAIL, OTHER_AUTH_KEY);

    expect(result.status).toBe(202);
    expect(result.body).toEqual({ status: 'confirmation_sent' });
    expect(world.mails).toHaveLength(0);
    expect((await world.call('GET', '/v1/account', { auth })).status).toBe(200);
    expect(
      (await world.call('GET', '/v1/account', { auth: basic(EMAIL, OTHER_AUTH_KEY) })).status,
    ).toBe(401);
  });

  it('reports a failed email as 502 and keeps the signup so it can be retried', async () => {
    vi.spyOn(console, 'error').mockImplementation(() => {});
    const failing = createWorld({}, { mailFails: true });

    const result = await signUp(failing);

    expect(result.status).toBe(502);
    expect(result.body).toEqual({ error: 'email_failed' });
    const row = await env.DB.prepare('SELECT COUNT(*) AS n FROM accounts').first<{ n: number }>();
    expect(row!.n).toBe(1);

    const working = createWorld();
    working.clock.now = failing.clock.now;
    expect((await signUp(working)).status).toBe(202);
    expect(working.mails).toHaveLength(0); // the code from the failed attempt is reused
    vi.restoreAllMocks();
  });

  it('does not repeat the email for a signup repeated within 10 minutes', async () => {
    const world = createWorld();
    await signUp(world);
    const first = lastCode(world);

    world.clock.now += 5 * MINUTE;
    await signUp(world);

    expect(world.mails).toHaveLength(1);
    expect((await confirm(world, first)).status).toBe(200);
  });

  it('sends a new code after 10 minutes, and the old one stops working', async () => {
    const world = createWorld();
    await signUp(world);
    const first = lastCode(world);

    world.clock.now += 11 * MINUTE;
    await signUp(world);
    const second = lastCode(world);

    expect(world.mails).toHaveLength(2);
    expect(second).not.toBe(first);
    expect((await confirm(world, first)).status).toBe(400);
    expect((await confirm(world, second)).status).toBe(200);
  });

  it('forgets signups nobody confirmed after 7 days', async () => {
    const world = createWorld();
    await signUp(world);

    world.clock.now += 8 * DAY;
    await signUp(world, OTHER_EMAIL);

    const rows = await env.DB.prepare('SELECT email FROM accounts').all<{ email: string }>();
    expect(rows.results.map((row) => row.email)).toEqual([OTHER_EMAIL]);
  });

  it('stops sending after the daily email limit and starts again the next day', async () => {
    const world = createWorld({ MAX_EMAILS_PER_DAY: '2' });
    await signUp(world, 'a@example.com');
    await signUp(world, 'b@example.com');

    const blocked = await signUp(world, 'c@example.com');
    expect(blocked.status).toBe(429);
    expect(blocked.body).toEqual({ error: 'signups_paused' });
    expect(Number(blocked.headers.get('Retry-After'))).toBeGreaterThan(0);
    expect(world.mails).toHaveLength(2);

    world.clock.now += DAY;
    expect((await signUp(world, 'c@example.com')).status).toBe(202);
    expect(world.mails).toHaveLength(3);
  });
});

describe('confirming an account', () => {
  it('needs the code and the credentials, and unlocks the account', async () => {
    const world = createWorld();
    await signUp(world);
    const auth = basic(EMAIL, AUTH_KEY);

    const before = await world.call('GET', '/v1/account', { auth });
    expect(before.status).toBe(403);
    expect(before.body).toEqual({ error: 'email_not_confirmed' });

    const result = await confirm(world, lastCode(world));
    expect(result.status).toBe(200);
    expect(result.body).toEqual({ status: 'verified' });
    expect((await world.call('GET', '/v1/account', { auth })).status).toBe(200);
  });

  it('accepts the code with a space or dash, as it is shown in the email', async () => {
    const world = createWorld();
    await signUp(world);
    const code = lastCode(world);

    expect((await confirm(world, `${code.slice(0, 4)} ${code.slice(4)}`)).status).toBe(200);
  });

  it('gives up on the code after 5 wrong tries, even if the right one comes next', async () => {
    const world = createWorld();
    await signUp(world);
    const right = lastCode(world);
    const wrong = right === '00000000' ? '11111111' : '00000000';

    for (let attempt = 0; attempt < 5; attempt++) {
      expect((await confirm(world, wrong)).status).toBe(400);
    }

    expect((await confirm(world, right)).status).toBe(400);
  });

  it('expires the code after 30 minutes', async () => {
    const world = createWorld();
    await signUp(world);
    const code = lastCode(world);

    world.clock.now += 31 * MINUTE;

    expect((await confirm(world, code)).status).toBe(400);
  });

  it('refuses the right code with the wrong credentials', async () => {
    const world = createWorld();
    await signUp(world);

    expect((await confirm(world, lastCode(world), OTHER_AUTH_KEY)).status).toBe(400);
  });

  it('cannot be hijacked: replacing a pending signup does not let it be confirmed with the old code', async () => {
    const world = createWorld();
    await signUp(world, EMAIL, AUTH_KEY); // the real owner
    const ownersCode = lastCode(world);
    await signUp(world, EMAIL, OTHER_AUTH_KEY); // someone else, with their own password

    // The owner enters the code, but their credentials were replaced.
    expect((await confirm(world, ownersCode, AUTH_KEY)).status).toBe(400);
    // The other person never saw the code, so they cannot finish either.
    expect((await confirm(world, '12345678', OTHER_AUTH_KEY)).status).toBe(400);

    // The owner signs up again with their own password and finishes.
    await signUp(world, EMAIL, AUTH_KEY);
    expect((await confirm(world, ownersCode, AUTH_KEY)).status).toBe(200);
    expect((await world.call('GET', '/v1/account', { auth: basic(EMAIL, AUTH_KEY) })).status).toBe(200);
    expect(
      (await world.call('GET', '/v1/account', { auth: basic(EMAIL, OTHER_AUTH_KEY) })).status,
    ).toBe(401);
  });

  it('cannot confirm an account twice, or one that does not exist', async () => {
    const world = createWorld();
    await signUp(world);
    const code = lastCode(world);
    await confirm(world, code);

    expect((await confirm(world, code)).status).toBe(400);
    const stranger = await world.call('POST', '/v1/accounts/confirm', {
      body: { email: OTHER_EMAIL, authKey: AUTH_KEY, code },
    });
    expect(stranger.status).toBe(400);
    expect(stranger.body).toEqual({ error: 'invalid_code' });
  });
});

describe('signing in', () => {
  it('rejects missing, malformed and wrong credentials the same way', async () => {
    const world = createWorld();
    await createConfirmedAccount(world);
    const attempts = [
      undefined,
      'Bearer token',
      'Basic !!!',
      basic(EMAIL, OTHER_AUTH_KEY),
      basic(OTHER_EMAIL, AUTH_KEY),
      basic('not an email', AUTH_KEY),
      basic(EMAIL, 'short'),
    ];
    for (const auth of attempts) {
      const result = await world.call('GET', '/v1/account', { auth });
      expect(result.status, String(auth)).toBe(401);
      expect(result.body).toEqual({ error: 'invalid_credentials' });
    }
  });

  it('accepts the email in any case', async () => {
    const world = createWorld();
    await createConfirmedAccount(world);

    const result = await world.call('GET', '/v1/account', {
      auth: basic('READER@Example.com', AUTH_KEY),
    });

    expect(result.status).toBe(200);
  });
});

describe('the account', () => {
  it('returns the wrapped data key and the kdf settings', async () => {
    const world = createWorld();
    const auth = await createConfirmedAccount(world);

    const result = await world.call('GET', '/v1/account', { auth });

    expect(result.body).toEqual({
      wrappedDataKey: accountBody().wrappedDataKey,
      kdf: accountBody().kdf,
    });
  });

  it('changes the password without touching the data', async () => {
    const world = createWorld();
    const auth = await createConfirmedAccount(world);
    await world.call('POST', '/v1/changes', {
      auth,
      body: { records: [{ kind: 'lesson', id: 'a', updatedAt: 1, deleted: false, data: { n: 1 } }] },
    });
    const invite = await world.call('POST', '/v1/account/pairing', {
      auth,
      body: { payload: 'encrypted' },
    });

    const change = await world.call('PUT', '/v1/account', {
      auth,
      body: { authKey: OTHER_AUTH_KEY, wrappedDataKey: 'bmV3LXdyYXBwZWQta2V5' },
    });

    expect(change.status).toBe(200);
    expect((await world.call('GET', '/v1/account', { auth })).status).toBe(401);
    const newAuth = basic(EMAIL, OTHER_AUTH_KEY);
    const account = await world.call('GET', '/v1/account', { auth: newAuth });
    expect(account.body.wrappedDataKey).toBe('bmV3LXdyYXBwZWQta2V5');
    expect(account.body.kdf).toEqual(accountBody().kdf);
    expect((await world.call('GET', '/v1/changes', { auth: newAuth })).body.records).toHaveLength(1);
    expect(
      (await world.call('GET', `/v1/pairings/${invite.body.token}`)).status,
    ).toBe(404);
  });

  it('is deleted together with its data', async () => {
    const world = createWorld();
    const auth = await createConfirmedAccount(world);
    await world.call('POST', '/v1/changes', {
      auth,
      body: { records: [{ kind: 'lesson', id: 'a', updatedAt: 1, deleted: false, data: {} }] },
    });
    await world.call('POST', '/v1/inbox', { auth, body: { text: 'cipher' } });
    await world.call('POST', '/v1/account/pairing', {
      auth,
      body: { payload: 'encrypted' },
    });

    const result = await world.call('DELETE', '/v1/account', { auth });

    expect(result.status).toBe(204);
    expect((await world.call('GET', '/v1/account', { auth })).status).toBe(401);
    for (const table of [
      'accounts',
      'records',
      'inbox',
      'email_codes',
      'pairing_invites',
    ]) {
      const row = await env.DB.prepare(`SELECT COUNT(*) AS n FROM ${table}`).first<{ n: number }>();
      expect(row!.n, table).toBe(0);
    }
    const usage = await env.DB.prepare("SELECT COUNT(*) AS n FROM usage WHERE scope LIKE 'w:%'").first<{
      n: number;
    }>();
    expect(usage!.n).toBe(0);
  });

  it('allows an unconfirmed account to be deleted with its credentials', async () => {
    const world = createWorld();
    await signUp(world);
    const auth = basic(EMAIL, AUTH_KEY);

    expect((await world.call('GET', '/v1/account', { auth })).status).toBe(403);
    expect(
      (
        await world.call('POST', '/v1/account/pairing', {
          auth,
          body: { payload: 'encrypted' },
        })
      ).status,
    ).toBe(403);
    expect(
      (await world.call('DELETE', '/v1/account', {
        auth: basic(EMAIL, OTHER_AUTH_KEY),
      })).status,
    ).toBe(401);

    const result = await world.call('DELETE', '/v1/account', { auth });

    expect(result.status).toBe(204);
    for (const table of ['accounts', 'email_codes']) {
      const row = await env.DB.prepare(`SELECT COUNT(*) AS n FROM ${table}`).first<{ n: number }>();
      expect(row!.n, table).toBe(0);
    }
  });
});

describe('device pairing invites', () => {
  it('creates a short-lived, single-use invite without storing the token', async () => {
    const world = createWorld();
    const auth = await createConfirmedAccount(world);
    const payload = 'encrypted credential payload';

    const created = await world.call('POST', '/v1/account/pairing', {
      auth,
      body: { payload },
    });

    expect(created.status).toBe(200);
    expect(created.body.token).toMatch(/^[a-f0-9]{64}$/);
    expect(created.body.expiresAt).toBe(world.clock.now + 10 * MINUTE);
    const row = await env.DB.prepare('SELECT * FROM pairing_invites').first<Record<string, unknown>>();
    expect(row?.token_hash).not.toBe(created.body.token);
    expect(row?.payload).toBe(payload);

    const redeemed = await world.call('GET', `/v1/pairings/${created.body.token}`);
    expect(redeemed.status).toBe(200);
    expect(redeemed.body).toEqual({ payload });
    expect((await world.call('GET', `/v1/pairings/${created.body.token}`)).status).toBe(404);
  });

  it('expires invites and only retains the latest invite per account', async () => {
    const world = createWorld();
    const auth = await createConfirmedAccount(world);
    const first = await world.call('POST', '/v1/account/pairing', {
      auth,
      body: { payload: 'first' },
    });
    const second = await world.call('POST', '/v1/account/pairing', {
      auth,
      body: { payload: 'second' },
    });

    expect((await world.call('GET', `/v1/pairings/${first.body.token}`)).status).toBe(404);
    world.clock.now += 10 * MINUTE;
    expect((await world.call('GET', `/v1/pairings/${second.body.token}`)).status).toBe(404);
  });

  it('rejects unauthenticated or malformed invite creation', async () => {
    const world = createWorld();
    await createConfirmedAccount(world);

    expect(
      (await world.call('POST', '/v1/account/pairing', { body: { payload: 'cipher' } }))
        .status,
    ).toBe(401);
    expect(
      (await world.call('POST', '/v1/account/pairing', {
        auth: basic(EMAIL, AUTH_KEY),
        body: { payload: 'x'.repeat(10_241) },
      })).status,
    ).toBe(400);
  });
});

describe('sending email', () => {
  afterEach(() => vi.restoreAllMocks());

  const mail = { to: EMAIL, subject: 's', text: 't', html: '<p>t</p>' };

  it('posts to Resend with the key and the configured sender', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response('{}', { status: 200 }));
    const send = createMailSender({
      RESEND_API_KEY: 're_test',
      MAIL_FROM: 'LinguaSRS <noreply@example.com>',
    } as Env);

    await send(mail);

    const [url, init] = fetchMock.mock.calls[0];
    expect(url).toBe('https://api.resend.com/emails');
    expect((init!.headers as Record<string, string>).Authorization).toBe('Bearer re_test');
    expect(JSON.parse(init!.body as string)).toEqual({
      from: 'LinguaSRS <noreply@example.com>',
      to: [EMAIL],
      subject: 's',
      text: 't',
      html: '<p>t</p>',
    });

  });

  it('fails when Resend refuses', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response('no', { status: 422 }));
    const send = createMailSender({ RESEND_API_KEY: 're_test' } as Env);

    await expect(send(mail)).rejects.toThrow('422');
  });

  it('fails without a key, unless developing locally', async () => {
    const log = vi.spyOn(console, 'log').mockImplementation(() => {});

    await expect(createMailSender({} as Env)(mail)).rejects.toThrow('RESEND_API_KEY');
    await createMailSender({ DEV_LOG_EMAILS: 'true' } as Env)(mail);

    expect(log).toHaveBeenCalledOnce();
  });
});
