import { Deps, Env, HttpError } from './types';
import { confirmationMail } from './mail';
import {
  intSetting,
  isAuthKey,
  json,
  normalizeEmail,
  randomCode,
  randomToken,
  readJson,
  secondsUntilNextUtcDay,
  sha256Hex,
  timingSafeEqual,
  utcDay,
} from './util';

const MINUTE = 60 * 1000;
const CODE_TTL_MS = 30 * MINUTE;
/** A signup that is repeated sooner than this reuses the code already sent. */
const RESEND_GAP_MS = 10 * MINUTE;
/** A signup nobody confirmed is forgotten after this long. */
const UNCONFIRMED_TTL_MS = 7 * 24 * 60 * MINUTE;
const MAX_CODE_ATTEMPTS = 5;
const PAIRING_INVITE_TTL_MS = 10 * MINUTE;
const UNKNOWN_HASH = '0'.repeat(64);

function validWrappedKey(value: unknown): value is string {
  return typeof value === 'string' && /^[A-Za-z0-9+/_=-]{1,1024}$/.test(value);
}

function validKdf(value: unknown): value is Record<string, unknown> {
  return (
    typeof value === 'object' &&
    value !== null &&
    !Array.isArray(value) &&
    typeof (value as { alg?: unknown }).alg === 'string' &&
    JSON.stringify(value).length <= 1024
  );
}

/**
 * Starts an account. The answer is always the same, so it never says whether
 * the email already has an account. A repeated signup for an unconfirmed
 * email replaces its credentials: whoever confirms it must know the code that
 * was emailed AND the credentials, so nobody can confirm someone else's email
 * with a password of their own.
 */
export async function createAccount(request: Request, env: Env, deps: Deps): Promise<Response> {
  const body = await readJson(request, 8 * 1024);
  const email = normalizeEmail(body.email);
  if (!email || !isAuthKey(body.authKey) || !validWrappedKey(body.wrappedDataKey) || !validKdf(body.kdf)) {
    throw new HttpError(400, 'invalid_account');
  }
  const now = deps.now();
  const day = utcDay(now);

  await env.DB.batch([
    env.DB.prepare(
      'DELETE FROM email_codes WHERE email IN ' +
        '(SELECT email FROM accounts WHERE verified_at IS NULL AND created_at < ?1)',
    ).bind(now - UNCONFIRMED_TTL_MS),
    env.DB.prepare('DELETE FROM accounts WHERE verified_at IS NULL AND created_at < ?1').bind(
      now - UNCONFIRMED_TTL_MS,
    ),
    env.DB.prepare("DELETE FROM usage WHERE scope = 'emails' AND day < ?1").bind(day),
  ]);

  const sent = await env.DB.prepare("SELECT n FROM usage WHERE scope = 'emails' AND day = ?1")
    .bind(day)
    .first<{ n: number }>();
  if ((sent?.n ?? 0) >= intSetting(env.MAX_EMAILS_PER_DAY, 50)) {
    throw new HttpError(429, 'signups_paused', {
      'Retry-After': String(secondsUntilNextUtcDay(now)),
    });
  }

  const existing = await env.DB.prepare('SELECT verified_at FROM accounts WHERE email = ?1')
    .bind(email)
    .first<{ verified_at: number | null }>();
  const answer = () => json({ status: 'confirmation_sent' }, 202);
  if (existing && existing.verified_at !== null) return answer();

  const authHash = await sha256Hex(body.authKey);
  const kdf = JSON.stringify(body.kdf);
  const lastCode = existing
    ? await env.DB.prepare('SELECT created_at FROM email_codes WHERE email = ?1')
        .bind(email)
        .first<{ created_at: number }>()
    : null;
  const reuseCode = lastCode !== null && now - lastCode.created_at < RESEND_GAP_MS;

  const statements = [
    existing
      ? env.DB.prepare(
          'UPDATE accounts SET auth_hash = ?2, wrapped_data_key = ?3, kdf = ?4, created_at = ?5 WHERE email = ?1',
        ).bind(email, authHash, body.wrappedDataKey, kdf, now)
      : env.DB.prepare(
          'INSERT INTO accounts (email, auth_hash, wrapped_data_key, kdf, created_at) VALUES (?1, ?2, ?3, ?4, ?5)',
        ).bind(email, authHash, body.wrappedDataKey, kdf, now),
  ];
  let code: string | null = null;
  if (!reuseCode) {
    code = randomCode();
    statements.push(
      env.DB.prepare(
        'INSERT OR REPLACE INTO email_codes (email, code_hash, attempts, expires_at, created_at) ' +
          'VALUES (?1, ?2, 0, ?3, ?4)',
      ).bind(email, await sha256Hex(`${email}:${code}`), now + CODE_TTL_MS, now),
      env.DB.prepare(
        "INSERT INTO usage (scope, day, n) VALUES ('emails', ?1, 1) " +
          'ON CONFLICT (scope, day) DO UPDATE SET n = n + 1',
      ).bind(day),
    );
  }
  await env.DB.batch(statements);

  if (code !== null) {
    try {
      await deps.sendMail(confirmationMail(email, code));
    } catch (error) {
      console.error('Could not send the confirmation email', error);
      throw new HttpError(502, 'email_failed');
    }
  }
  return answer();
}

/** Finishes a signup. Every failure is the same answer. */
export async function confirmAccount(request: Request, env: Env, deps: Deps): Promise<Response> {
  const body = await readJson(request, 4 * 1024);
  const email = normalizeEmail(body.email);
  const code = typeof body.code === 'string' ? body.code.replace(/[\s-]/g, '') : '';
  if (!email || !isAuthKey(body.authKey) || !/^\d{8}$/.test(code)) {
    throw new HttpError(400, 'invalid_code');
  }
  const now = deps.now();

  const row = await env.DB.prepare(
    'SELECT a.auth_hash, a.verified_at, c.code_hash, c.attempts, c.expires_at ' +
      'FROM accounts a JOIN email_codes c ON c.email = a.email WHERE a.email = ?1',
  )
    .bind(email)
    .first<{
      auth_hash: string;
      verified_at: number | null;
      code_hash: string;
      attempts: number;
      expires_at: number;
    }>();
  const authMatches = timingSafeEqual(await sha256Hex(body.authKey), row?.auth_hash ?? UNKNOWN_HASH);
  if (
    !row ||
    !authMatches ||
    row.verified_at !== null ||
    row.expires_at < now ||
    row.attempts >= MAX_CODE_ATTEMPTS
  ) {
    throw new HttpError(400, 'invalid_code');
  }

  if (!timingSafeEqual(await sha256Hex(`${email}:${code}`), row.code_hash)) {
    await env.DB.prepare(
      row.attempts + 1 >= MAX_CODE_ATTEMPTS
        ? 'DELETE FROM email_codes WHERE email = ?1'
        : 'UPDATE email_codes SET attempts = attempts + 1 WHERE email = ?1',
    )
      .bind(email)
      .run();
    throw new HttpError(400, 'invalid_code');
  }

  await env.DB.batch([
    env.DB.prepare('UPDATE accounts SET verified_at = ?2 WHERE email = ?1').bind(email, now),
    env.DB.prepare('DELETE FROM email_codes WHERE email = ?1').bind(email),
  ]);
  return json({ status: 'verified' });
}

export async function getAccount(email: string, env: Env): Promise<Response> {
  const row = await env.DB.prepare('SELECT wrapped_data_key, kdf FROM accounts WHERE email = ?1')
    .bind(email)
    .first<{ wrapped_data_key: string; kdf: string }>();
  if (!row) throw new HttpError(404, 'not_found');
  return json({ wrappedDataKey: row.wrapped_data_key, kdf: JSON.parse(row.kdf) });
}

/** Changes the password: a new auth key, and the data key wrapped by the new password. */
export async function changePassword(request: Request, email: string, env: Env): Promise<Response> {
  const body = await readJson(request, 8 * 1024);
  if (
    !isAuthKey(body.authKey) ||
    !validWrappedKey(body.wrappedDataKey) ||
    (body.kdf !== undefined && !validKdf(body.kdf))
  ) {
    throw new HttpError(400, 'invalid_account');
  }
  await env.DB.batch([
    env.DB.prepare(
      'UPDATE accounts SET auth_hash = ?2, wrapped_data_key = ?3, kdf = COALESCE(?4, kdf) WHERE email = ?1',
    ).bind(
      email,
      await sha256Hex(body.authKey),
      body.wrappedDataKey,
      body.kdf === undefined ? null : JSON.stringify(body.kdf),
    ),
    env.DB.prepare('DELETE FROM pairing_invites WHERE email = ?1').bind(email),
  ]);
  return json({ status: 'ok' });
}

export async function createPairingInvite(
  request: Request,
  email: string,
  env: Env,
  deps: Deps,
): Promise<Response> {
  const body = await readJson(request, 12 * 1024);
  if (typeof body.payload !== 'string' || body.payload.length > 10 * 1024) {
    throw new HttpError(400, 'invalid_pairing');
  }
  const now = deps.now();
  const token = randomToken();
  await env.DB.batch([
    env.DB.prepare('DELETE FROM pairing_invites WHERE expires_at <= ?1 OR email = ?2')
      .bind(now, email),
    env.DB.prepare(
      'INSERT INTO pairing_invites (token_hash, email, payload, expires_at) VALUES (?1, ?2, ?3, ?4)',
    ).bind(await sha256Hex(token), email, body.payload, now + PAIRING_INVITE_TTL_MS),
  ]);
  return json({ token, expiresAt: now + PAIRING_INVITE_TTL_MS });
}

export async function redeemPairingInvite(
  token: string,
  env: Env,
  deps: Deps,
): Promise<Response> {
  if (!/^[a-f0-9]{64}$/.test(token)) throw new HttpError(404, 'not_found');
  const invite = await env.DB.prepare(
    'DELETE FROM pairing_invites WHERE token_hash = ?1 AND expires_at > ?2 RETURNING payload',
  )
    .bind(await sha256Hex(token), deps.now())
    .first<{ payload: string }>();
  if (!invite) throw new HttpError(404, 'not_found');
  return json({ payload: invite.payload });
}

export async function deleteAccount(email: string, env: Env): Promise<Response> {
  await env.DB.batch([
    env.DB.prepare('DELETE FROM pairing_invites WHERE email = ?1').bind(email),
    env.DB.prepare('DELETE FROM records WHERE email = ?1').bind(email),
    env.DB.prepare('DELETE FROM inbox WHERE email = ?1').bind(email),
    env.DB.prepare('DELETE FROM usage WHERE scope = ?1').bind(`w:${email}`),
    env.DB.prepare('DELETE FROM email_codes WHERE email = ?1').bind(email),
    env.DB.prepare('DELETE FROM accounts WHERE email = ?1').bind(email),
  ]);
  return new Response(null, { status: 204 });
}
