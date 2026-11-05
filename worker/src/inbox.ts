import { Deps, Env, HttpError } from './types';
import { checkWriteQuota, writeUsageStatements } from './quota';
import { intSetting, json, readJson } from './util';

const MAX_ITEMS = 100;
const MAX_TEXT_BYTES = 64 * 1024;

export async function listInbox(email: string, env: Env): Promise<Response> {
  const { results } = await env.DB.prepare(
    'SELECT id, text, created_at FROM inbox WHERE email = ?1 ORDER BY created_at, id LIMIT ?2',
  )
    .bind(email, MAX_ITEMS)
    .all<{ id: string; text: string; created_at: number }>();
  return json({
    items: results.map((row) => ({ id: row.id, text: row.text, createdAt: row.created_at })),
  });
}

export async function addToInbox(request: Request, email: string, env: Env, deps: Deps): Promise<Response> {
  const body = await readJson(request, MAX_TEXT_BYTES + 1024);
  if (
    typeof body.text !== 'string' ||
    body.text.length === 0 ||
    new TextEncoder().encode(body.text).length > MAX_TEXT_BYTES
  ) {
    throw new HttpError(400, 'invalid_item');
  }
  const now = deps.now();
  await checkWriteQuota(env, email, 1, intSetting(env.MAX_WRITES_PER_DAY, 2000), now);
  const count = await env.DB.prepare('SELECT COUNT(*) AS n FROM inbox WHERE email = ?1')
    .bind(email)
    .first<{ n: number }>();
  if ((count?.n ?? 0) >= MAX_ITEMS) throw new HttpError(429, 'inbox_full');

  const id = crypto.randomUUID();
  await env.DB.batch([
    env.DB.prepare('INSERT INTO inbox (id, email, text, created_at) VALUES (?1, ?2, ?3, ?4)').bind(
      id,
      email,
      body.text,
      now,
    ),
    ...writeUsageStatements(env, email, 1, now),
  ]);
  return json({ id }, 201);
}

/** Removing an item that is already gone is not an error. */
export async function removeFromInbox(id: string, email: string, env: Env): Promise<Response> {
  await env.DB.prepare('DELETE FROM inbox WHERE id = ?1 AND email = ?2').bind(id, email).run();
  return new Response(null, { status: 204 });
}
