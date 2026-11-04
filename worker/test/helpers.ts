import { env } from 'cloudflare:workers';
import { beforeEach } from 'vitest';
import { createHandler } from '../src/index';
import type { Deps, Env, Mail } from '../src/types';

export const MINUTE = 60_000;
export const DAY = 24 * 60 * MINUTE;
/** 2026-11-03 12:00 UTC */
export const START = Date.UTC(2026, 10, 3, 12, 0, 0);

export const EMAIL = 'reader@example.com';
export const OTHER_EMAIL = 'other@example.com';
export const AUTH_KEY = 'A'.repeat(43);
export const OTHER_AUTH_KEY = 'B'.repeat(43);

export interface Result {
  status: number;
  body: any;
  headers: Headers;
}

export interface World {
  clock: { now: number };
  mails: Mail[];
  call(method: string, path: string, options?: { body?: unknown; auth?: string }): Promise<Result>;
}

export function basic(email: string, authKey: string): string {
  return `Basic ${btoa(`${email}:${authKey}`)}`;
}

export function accountBody(email = EMAIL, authKey = AUTH_KEY) {
  return {
    email,
    authKey,
    wrappedDataKey: 'd3JhcHBlZC1kYXRhLWtleQ',
    kdf: { alg: 'argon2id', memoryKiB: 65536, passes: 3, lanes: 1 },
  };
}

/** A Worker with its own fake clock and outbox. [settings] override the environment. */
export function createWorld(settings: Partial<Env> = {}, options: { mailFails?: boolean } = {}): World {
  const clock = { now: START };
  const mails: Mail[] = [];
  const deps: Deps = {
    sendMail: async (mail) => {
      if (options.mailFails) throw new Error('provider down');
      mails.push(mail);
    },
    now: () => clock.now,
  };
  const handle = createHandler(deps);
  // Define the overrides on a child object. Assigning them (Object.assign)
  // could write through to the shared bindings and leak into other tests.
  const testEnv = Object.create(
    env,
    Object.fromEntries(
      Object.entries(settings).map(([key, value]) => [key, { value, enumerable: true }]),
    ),
  ) as Env;
  return {
    clock,
    mails,
    async call(method, path, options = {}) {
      const headers: Record<string, string> = {};
      if (options.auth) headers.Authorization = options.auth;
      if (options.body !== undefined) headers['Content-Type'] = 'application/json';
      const response = await handle(
        new Request(`https://sync.test${path}`, {
          method,
          headers,
          body: options.body === undefined ? undefined : JSON.stringify(options.body),
        }),
        testEnv,
      );
      const text = await response.text();
      return {
        status: response.status,
        body: text ? JSON.parse(text) : null,
        headers: response.headers,
      };
    },
  };
}

/** The code in the most recent email, as the 8 digits a person would type. */
export function lastCode(world: World): string {
  const text = world.mails[world.mails.length - 1].text;
  const match = /(\d{4}) (\d{4})/.exec(text);
  if (!match) throw new Error(`no code in: ${text}`);
  return match[1] + match[2];
}

export async function signUp(world: World, email = EMAIL, authKey = AUTH_KEY): Promise<Result> {
  return world.call('POST', '/v1/accounts', { body: accountBody(email, authKey) });
}

/** Signs up and confirms, so the account can be used. */
export async function createConfirmedAccount(
  world: World,
  email = EMAIL,
  authKey = AUTH_KEY,
): Promise<string> {
  await signUp(world, email, authKey);
  const result = await world.call('POST', '/v1/accounts/confirm', {
    body: { email, authKey, code: lastCode(world) },
  });
  if (result.status !== 200) throw new Error(`could not confirm: ${JSON.stringify(result.body)}`);
  return basic(email, authKey);
}

export function clearDatabase() {
  beforeEach(async () => {
    await env.DB.batch(
      ['usage', 'email_codes', 'records', 'inbox', 'pairing_invites', 'accounts'].map((table) =>
        env.DB.prepare(`DELETE FROM ${table}`),
      ),
    );
  });
}
