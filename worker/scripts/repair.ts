// Checks of the sync database, and repairs for what can be repaired safely.
// Used by scripts/d1-repair.ts (see docs/admin.md) and by test/repair.test.ts.
//
// The server cannot read records: their ids are keyed hashes and their data
// is encrypted (docs/sync.md, "Records"). So nothing here looks at what a
// record holds, such as duplicate lessons or a split record's parts; only a
// device with the data key can. These checks are about what sync itself
// relies on: the pull cursor, the shape of each row, and rows left behind.
// Rows of a deleted account need no check where a foreign key covers them:
// D1 always enforces foreign keys. `usage` has none, so it is checked.
//
// Every statement is plain SQL with its values written in, so the same text
// runs through a D1 binding and through `wrangler d1 execute --command`.
// Only numbers the script computes and strings read from the database are
// written in, the latter quoted with `sqlString`.

/** Runs SQL against D1. */
export interface SqlRunner {
  /** The rows a query returns. */
  all(sql: string): Promise<Record<string, unknown>[]>;
  /** Runs a statement; returns how many rows it changed. */
  run(sql: string): Promise<number>;
}

/** How much a finding matters. */
export type Severity = 'error' | 'warning' | 'cleanup';

export interface Finding {
  check: string;
  severity: Severity;
  title: string;
  /** What it means and what to do about it. */
  advice: string;
  count: number;
  /** Up to [SAMPLE_LIMIT] of the rows found. */
  samples: Record<string, unknown>[];
  /** Whether `repair` fixes it. */
  repairable: boolean;
}

export interface Repair {
  check: string;
  changed: number;
}

interface Check {
  id: string;
  severity: Severity;
  title: string;
  advice: string;
  /** Selects the rows found: a whole SELECT, without LIMIT. */
  select(now: number): string;
  /** Repairs them; returns rows changed. Absent when only a person can decide. */
  repair?(sql: SqlRunner, now: number): Promise<number>;
}

export const SAMPLE_LIMIT = 5;

const DAY_MS = 24 * 60 * 60 * 1000;
/** As in src/accounts.ts: unconfirmed signups older than this are dropped. */
const UNCONFIRMED_TTL_MS = 7 * DAY_MS;
/** As in src/changes.ts. */
const MAX_CLOCK_AHEAD_MS = DAY_MS;
const MAX_RECORD_BYTES = 32 * 1024;

/** [value] as an SQL string literal. */
export function sqlString(value: unknown): string {
  return `'${String(value).replaceAll("'", "''")}'`;
}

function utcDay(now: number): string {
  return new Date(now).toISOString().slice(0, 10);
}

const CHECKS: Check[] = [
  {
    id: 'duplicate_seq',
    severity: 'error',
    title: 'Records sharing a cursor position (seq), or with none',
    advice:
      'Devices pull records in seq order and remember the last seq they saw, ' +
      'so a record sharing its seq with another can be skipped for good at a ' +
      'page boundary. Repair moves every record but one of each seq (and any ' +
      'record with seq below 1) to a new seq at the end of its account, in ' +
      'seq order, so ' +
      'every device pulls it again. Devices that already have it ignore it, ' +
      'since it has not changed.',
    select: () =>
      'SELECT r.email, r.kind, r.id, r.seq FROM records r WHERE r.seq < 1 OR EXISTS (' +
      'SELECT 1 FROM records o WHERE o.email = r.email AND o.seq = r.seq AND ' +
      '(o.kind < r.kind OR (o.kind = r.kind AND o.id < r.id))) ' +
      'ORDER BY r.email, r.seq, r.kind, r.id',
    repair: async (sql, now) => {
      const rows = await sql.all(CHECKS_BY_ID.duplicate_seq.select(now));
      let changed = 0;
      for (const row of rows) {
        changed += await sql.run(
          'UPDATE records SET seq = (SELECT MAX(seq) FROM records WHERE email = ' +
            `${sqlString(row.email)}) + 1 WHERE email = ${sqlString(row.email)} AND ` +
            `kind = ${sqlString(row.kind)} AND id = ${sqlString(row.id)}`,
        );
      }
      return changed;
    },
  },
  {
    id: 'bad_envelope',
    severity: 'error',
    title: 'Records whose data is not an encrypted envelope',
    advice:
      'A record that is not deleted must hold {"v":1,"n":"…","c":"…"}. Devices ' +
      'skip one they cannot read and count it as unreadable, keeping their own ' +
      'copy. Not repaired: the server cannot know what it held, and deleting ' +
      'it would delete that record on every device. If the account owner sees ' +
      'unreadable records, a device that has the data can push it again after ' +
      'an edit.',
    select: () =>
      'SELECT email, kind, id, seq, substr(data, 1, 80) AS data FROM records WHERE deleted = 0 AND ' +
      "CASE WHEN json_valid(data) THEN json_type(data) IS NOT 'object' OR " +
      "json_extract(data, '$.v') IS NOT 1 OR json_type(data, '$.n') IS NOT 'text' OR " +
      "json_type(data, '$.c') IS NOT 'text' ELSE 1 END",
  },
  {
    id: 'invalid_fields',
    severity: 'error',
    title: 'Records the Worker would not have accepted',
    advice:
      'A kind that is not 1–32 lowercase letters, digits or _ starting with a ' +
      'letter, an id that is not 1–128 characters, a deleted flag other than ' +
      '0 or 1, or a negative updated_at. Devices may fail to pull these. Not ' +
      'repaired: look at the rows, and delete them by hand if they are junk ' +
      '(docs/admin.md).',
    select: () =>
      'SELECT email, kind, id, seq, deleted, updated_at FROM records WHERE ' +
      "length(kind) NOT BETWEEN 1 AND 32 OR kind GLOB '*[^a-z0-9_]*' OR " +
      "substr(kind, 1, 1) NOT GLOB '[a-z]' OR length(id) NOT BETWEEN 1 AND 128 OR " +
      'deleted NOT IN (0, 1) OR updated_at < 0',
  },
  {
    id: 'future_updated_at',
    severity: 'warning',
    title: 'Records dated more than a day ahead',
    advice:
      'The newest updated_at wins a conflict, so such a record beats every ' +
      'edit until that time comes. The Worker refuses these now, so they come ' +
      'from before that or from outside it. Not repaired: whether to keep the ' +
      'record is up to its owner; a device that edits it after the date wins.',
    select: (now) =>
      `SELECT email, kind, id, seq, updated_at FROM records WHERE updated_at > ${now + MAX_CLOCK_AHEAD_MS}`,
  },
  {
    id: 'oversized_records',
    severity: 'warning',
    title: 'Records larger than the Worker accepts',
    advice:
      `Larger than ${MAX_RECORD_BYTES} bytes of data. They still pull, but the ` +
      'app splits large records, so these are not from it. Not repaired.',
    select: () =>
      'SELECT email, kind, id, seq, length(CAST(data AS BLOB)) AS bytes FROM records ' +
      `WHERE length(CAST(data AS BLOB)) > ${MAX_RECORD_BYTES}`,
  },
  {
    id: 'tombstone_data',
    severity: 'cleanup',
    title: 'Deleted records that still hold data',
    advice:
      'A deletion only needs its kind, id and time; devices ignore its data. ' +
      'Repair empties the data, which saves space and changes nothing a ' +
      'device sees.',
    select: () => "SELECT email, kind, id, seq FROM records WHERE deleted = 1 AND data <> '{}'",
    repair: (sql) => sql.run("UPDATE records SET data = '{}' WHERE deleted = 1 AND data <> '{}'"),
  },
  {
    id: 'orphan_usage',
    severity: 'cleanup',
    title: 'Write counters of a deleted account',
    advice:
      'Counters for an account that no longer exists (usage has no foreign ' +
      'key, unlike the other tables). Repair deletes them.',
    select: () =>
      "SELECT scope, day, n FROM usage u WHERE u.scope LIKE 'w:%' AND NOT EXISTS " +
      "(SELECT 1 FROM accounts a WHERE 'w:' || a.email = u.scope)",
    repair: (sql) =>
      sql.run(
        "DELETE FROM usage AS u WHERE u.scope LIKE 'w:%' AND NOT EXISTS " +
          "(SELECT 1 FROM accounts a WHERE 'w:' || a.email = u.scope)",
      ),
  },
  {
    id: 'stale_unconfirmed',
    severity: 'cleanup',
    title: 'Unconfirmed signups older than 7 days',
    advice:
      'The Worker drops these the next time anyone signs up. Repair drops ' +
      'them now, with their confirmation codes. The email can sign up again.',
    select: (now) =>
      'SELECT email, created_at FROM accounts WHERE verified_at IS NULL AND ' +
      `created_at < ${now - UNCONFIRMED_TTL_MS}`,
    repair: async (sql, now) => {
      const stale =
        'SELECT email FROM accounts WHERE verified_at IS NULL AND ' + `created_at < ${now - UNCONFIRMED_TTL_MS}`;
      let changed = 0;
      for (const table of ['email_codes', 'pairing_invites', 'inbox', 'records']) {
        changed += await sql.run(`DELETE FROM ${table} WHERE email IN (${stale})`);
      }
      changed += await sql.run(`DELETE FROM usage WHERE scope IN (SELECT 'w:' || email FROM (${stale}))`);
      return changed + (await sql.run(`DELETE FROM accounts WHERE email IN (${stale})`));
    },
  },
  {
    id: 'expired_email_codes',
    severity: 'cleanup',
    title: 'Expired confirmation codes',
    advice: 'They can no longer confirm anything. Repair deletes them; signing up again sends a new code.',
    select: (now) => `SELECT email, expires_at FROM email_codes WHERE expires_at < ${now}`,
    repair: (sql, now) => sql.run(`DELETE FROM email_codes WHERE expires_at < ${now}`),
  },
  {
    id: 'expired_pairing_invites',
    severity: 'cleanup',
    title: 'Expired pairing invites',
    advice:
      'They can no longer be redeemed. The Worker drops them when the account ' +
      'makes its next invite; repair drops them now.',
    select: (now) => `SELECT email, expires_at FROM pairing_invites WHERE expires_at <= ${now}`,
    repair: (sql, now) => sql.run(`DELETE FROM pairing_invites WHERE expires_at <= ${now}`),
  },
  {
    id: 'old_usage',
    severity: 'cleanup',
    title: 'Usage counters from past days',
    advice:
      'Only today counts towards the daily limits. The Worker drops older days ' +
      'as it writes; repair drops them all.',
    select: (now) => `SELECT scope, day, n FROM usage WHERE day < ${sqlString(utcDay(now))}`,
    repair: (sql, now) => sql.run(`DELETE FROM usage WHERE day < ${sqlString(utcDay(now))}`),
  },
];

const CHECKS_BY_ID: Record<string, Check> = Object.fromEntries(CHECKS.map((check) => [check.id, check]));

/** The ids of every check, in the order they run. */
export const CHECK_IDS = CHECKS.map((check) => check.id);

/** Runs every check at [now] (milliseconds) and returns the ones that found something. */
export async function checkDatabase(sql: SqlRunner, now: number): Promise<Finding[]> {
  const findings: Finding[] = [];
  for (const check of CHECKS) {
    const query = check.select(now);
    const [{ n }] = (await sql.all(`SELECT COUNT(*) AS n FROM (${query})`)) as { n: number }[];
    if (n === 0) continue;
    findings.push({
      check: check.id,
      severity: check.severity,
      title: check.title,
      advice: check.advice,
      count: n,
      samples: await sql.all(`${query} LIMIT ${SAMPLE_LIMIT}`),
      repairable: check.repair !== undefined,
    });
  }
  return findings;
}

/**
 * Repairs what [findings] (from [checkDatabase]) found and can be repaired,
 * at [now]. Run [checkDatabase] again afterwards to see what is left.
 */
export async function repairDatabase(sql: SqlRunner, findings: Finding[], now: number): Promise<Repair[]> {
  const repairs: Repair[] = [];
  for (const finding of findings) {
    const repair = CHECKS_BY_ID[finding.check]?.repair;
    if (!repair) continue;
    repairs.push({ check: finding.check, changed: await repair(sql, now) });
  }
  return repairs;
}

export interface AccountStats {
  email: string;
  verified_at: number | null;
  created_at: number;
  records: number;
  deleted: number;
  max_seq: number | null;
  bytes: number;
  last_updated_at: number | null;
}

/** Record counts and sizes per account, or for [email] alone. */
export async function accountStats(sql: SqlRunner, email?: string): Promise<AccountStats[]> {
  return (await sql.all(
    'SELECT a.email, a.verified_at, a.created_at, COUNT(r.id) AS records, ' +
      'COALESCE(SUM(r.deleted), 0) AS deleted, MAX(r.seq) AS max_seq, ' +
      'COALESCE(SUM(length(CAST(r.data AS BLOB))), 0) AS bytes, MAX(r.updated_at) AS last_updated_at ' +
      'FROM accounts a LEFT JOIN records r ON r.email = a.email ' +
      (email === undefined ? '' : `WHERE a.email = ${sqlString(email)} `) +
      'GROUP BY a.email ORDER BY a.email',
  )) as unknown as AccountStats[];
}

/** Records per kind for [email]: how many, how many deleted, and their size. */
export async function kindStats(sql: SqlRunner, email: string): Promise<Record<string, unknown>[]> {
  return sql.all(
    'SELECT kind, COUNT(*) AS records, SUM(deleted) AS deleted, ' +
      'SUM(length(CAST(data AS BLOB))) AS bytes FROM records ' +
      `WHERE email = ${sqlString(email)} GROUP BY kind ORDER BY kind`,
  );
}
