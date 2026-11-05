import { HttpError } from './types';

const DAY_MS = 24 * 60 * 60 * 1000;

export function json(body: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store', ...headers },
  });
}

export async function readJson(request: Request, maxBytes: number): Promise<Record<string, unknown>> {
  const declared = Number(request.headers.get('Content-Length') ?? 0);
  if (declared > maxBytes) throw new HttpError(413, 'too_large');
  const text = await request.text();
  if (new TextEncoder().encode(text).length > maxBytes) throw new HttpError(413, 'too_large');
  let value: unknown;
  try {
    value = JSON.parse(text);
  } catch {
    throw new HttpError(400, 'invalid_json');
  }
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    throw new HttpError(400, 'invalid_json');
  }
  return value as Record<string, unknown>;
}

export async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, '0')).join('');
}

export function randomToken(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return [...bytes].map((byte) => byte.toString(16).padStart(2, '0')).join('');
}

/** Compares two strings without stopping at the first difference. */
export function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

const EMAIL = /^[^\s@:]+@[^\s@:]+\.[^\s@:]+$/;

/** A lone surrogate: JSON can carry one, but UTF-8 cannot, so it would not be kept. */
const LONE_SURROGATE = /\p{Surrogate}/u;

/** The email as the account key (trimmed, lowercase), or null if unusable. */
export function normalizeEmail(value: unknown): string | null {
  if (typeof value !== 'string') return null;
  // Unicode form NFKC and lowercase, so equivalent spellings (full-width
  // letters, an accent typed as one character or two) are the same account.
  // The app applies the same steps in the same order.
  const email = value.trim().normalize('NFKC').toLowerCase().normalize('NFKC');
  return email.length <= 254 && EMAIL.test(email) && !LONE_SURROGATE.test(email) ? email : null;
}

/** A key derived on the device, as unpadded base64url. */
export function isAuthKey(value: unknown): value is string {
  return typeof value === 'string' && /^[A-Za-z0-9_-]{32,128}$/.test(value);
}

/** A uniformly random 8 digit code. */
export function randomCode(): string {
  const buffer = new Uint32Array(1);
  const limit = 2 ** 32 - (2 ** 32 % 100_000_000);
  do {
    crypto.getRandomValues(buffer);
  } while (buffer[0] >= limit);
  return String(buffer[0] % 100_000_000).padStart(8, '0');
}

export function utcDay(ms: number): string {
  return new Date(ms).toISOString().slice(0, 10);
}

export function secondsUntilNextUtcDay(ms: number): number {
  return Math.max(1, Math.ceil((Math.floor(ms / DAY_MS) * DAY_MS + DAY_MS - ms) / 1000));
}

/** A whole-number setting from the environment, or [fallback] if unset or invalid. */
export function intSetting(value: string | undefined, fallback: number): number {
  const parsed = Number.parseInt(value ?? '', 10);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : fallback;
}
