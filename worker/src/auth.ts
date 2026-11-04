import { Env, HttpError } from './types';
import { isAuthKey, normalizeEmail, sha256Hex, timingSafeEqual } from './util';

const UNKNOWN_HASH = '0'.repeat(64);

function decodeBase64Utf8(value: string): string {
  const binary = atob(value);
  return new TextDecoder().decode(Uint8Array.from(binary, (char) => char.charCodeAt(0)));
}

/**
 * Checks the Basic credentials (email and the key derived from the password)
 * and returns the account's email. An unknown email and a wrong key look the
 * same, and take the same work.
 */
export async function authenticate(
  request: Request,
  env: Env,
  options: { allowUnconfirmed?: boolean } = {},
): Promise<string> {
  const header = /^Basic\s+(\S+)$/i.exec(request.headers.get('Authorization') ?? '');
  if (!header) throw new HttpError(401, 'invalid_credentials');

  let decoded: string;
  try {
    decoded = decodeBase64Utf8(header[1]);
  } catch {
    throw new HttpError(401, 'invalid_credentials');
  }
  const split = decoded.indexOf(':');
  const email = normalizeEmail(decoded.slice(0, Math.max(split, 0)));
  const authKey = decoded.slice(split + 1);
  if (split < 0 || !email || !isAuthKey(authKey)) throw new HttpError(401, 'invalid_credentials');

  const account = await env.DB.prepare('SELECT auth_hash, verified_at FROM accounts WHERE email = ?1')
    .bind(email)
    .first<{ auth_hash: string; verified_at: number | null }>();
  const matches = timingSafeEqual(await sha256Hex(authKey), account?.auth_hash ?? UNKNOWN_HASH);
  if (!account || !matches) throw new HttpError(401, 'invalid_credentials');
  if (account.verified_at === null && !options.allowUnconfirmed) {
    throw new HttpError(403, 'email_not_confirmed');
  }
  return email;
}
