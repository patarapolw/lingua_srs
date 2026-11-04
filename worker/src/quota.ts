import { Env, HttpError } from './types';
import { secondsUntilNextUtcDay, utcDay } from './util';

/** Throws 429 if [count] more writes would pass the account's daily limit. */
export async function checkWriteQuota(
  env: Env,
  email: string,
  count: number,
  limit: number,
  now: number,
): Promise<void> {
  const row = await env.DB.prepare('SELECT n FROM usage WHERE scope = ?1 AND day = ?2')
    .bind(`w:${email}`, utcDay(now))
    .first<{ n: number }>();
  if ((row?.n ?? 0) + count > limit) {
    throw new HttpError(429, 'quota_exceeded', {
      'Retry-After': String(secondsUntilNextUtcDay(now)),
    });
  }
}

/** Statements that record [count] writes today and forget older days. */
export function writeUsageStatements(env: Env, email: string, count: number, now: number) {
  const scope = `w:${email}`;
  const day = utcDay(now);
  return [
    env.DB.prepare(
      'INSERT INTO usage (scope, day, n) VALUES (?1, ?2, ?3) ' +
        'ON CONFLICT (scope, day) DO UPDATE SET n = n + excluded.n',
    ).bind(scope, day, count),
    env.DB.prepare('DELETE FROM usage WHERE scope = ?1 AND day < ?2').bind(scope, day),
  ];
}
