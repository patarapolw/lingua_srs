// Checks the sync database, and repairs it with --repair. See docs/admin.md.
//
//   node scripts/d1-repair.ts [--remote] [--repair] [--stats] [--email <email>]
//                             [--database <name>] [--config <wrangler config>] [--json]
//
// Runs from worker/ with Node 22.18 or later (which runs TypeScript as is).
// Every query goes through `wrangler d1 execute`, so it uses wrangler's login
// and the database in wrangler.jsonc: the local development one, or with
// --remote the deployed one.

import { execFileSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { parseArgs } from 'node:util';
import {
  accountStats,
  checkDatabase,
  DEFAULT_WRITE_LIMIT,
  kindStats,
  repairDatabase,
  type Finding,
  type SqlRunner,
} from './repair.ts';

const USAGE = `Usage: node scripts/d1-repair.ts [options]

Checks the sync database and reports what it finds. Nothing is changed
without --repair.

  --remote           The deployed database (default: the local one)
  --repair           Repair what can be repaired safely, then check again
  --stats            Records and size per account
  --email <email>    With --stats: one account, by kind
  --write-limit <n>  The Worker's MAX_WRITES_PER_DAY (default: 2000)
  --database <name>  Database name or binding (default: DB)
  --config <path>    Wrangler config (default: wrangler.jsonc)
  --json             Print the report as JSON
  --help             Show this
`;

const { values } = parseArgs({
  options: {
    remote: { type: 'boolean', default: false },
    repair: { type: 'boolean', default: false },
    stats: { type: 'boolean', default: false },
    email: { type: 'string' },
    'write-limit': { type: 'string' },
    database: { type: 'string', default: 'DB' },
    config: { type: 'string' },
    json: { type: 'boolean', default: false },
    help: { type: 'boolean', default: false },
  },
});
if (values.help) {
  process.stdout.write(USAGE);
  process.exit(0);
}

const writeLimit = Number(values['write-limit'] ?? DEFAULT_WRITE_LIMIT);
if (!Number.isSafeInteger(writeLimit) || writeLimit < 1) {
  process.stderr.write(`--write-limit must be a whole number above 0\n\n${USAGE}`);
  process.exit(2);
}

const require = createRequire(import.meta.url);
const wranglerPackage = require.resolve('wrangler/package.json');
const wranglerBin = join(dirname(wranglerPackage), require(wranglerPackage).bin.wrangler);

interface WranglerResult {
  results?: Record<string, unknown>[];
  meta?: { changes?: number };
}

/** Runs SQL with `wrangler d1 execute --json`: one result per statement. */
function execute(sql: string): WranglerResult[] {
  const args = [wranglerBin, 'd1', 'execute', values.database!, '--json', '--command', sql];
  args.push(values.remote ? '--remote' : '--local');
  if (values.config) args.push('--config', values.config);
  let output: string;
  try {
    output = execFileSync(process.execPath, args, {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
      maxBuffer: 64 * 1024 * 1024,
    });
  } catch (error) {
    const failed = error as { stdout?: string; stderr?: string; message: string };
    throw new Error(`wrangler failed for: ${sql}\n${failed.stderr || failed.stdout || failed.message}`);
  }
  // Anything wrangler prints before the JSON (such as a notice) is skipped.
  return JSON.parse(output.slice(output.indexOf('['))) as WranglerResult[];
}

const sql: SqlRunner = {
  all: async (query) => execute(query)[0]?.results ?? [],
  // Local wrangler leaves `changes` out of its JSON, so ask SQLite in the
  // same command.
  run: async (query) => {
    const [result, counted] = execute(`${query}; SELECT changes() AS changed`);
    const changed = counted?.results?.[0]?.changed;
    return typeof changed === 'number' ? changed : (result?.meta?.changes ?? 0);
  },
};

function time(value: unknown): string {
  return typeof value === 'number' ? new Date(value).toISOString() : String(value);
}

function printFindings(findings: Finding[]): void {
  if (findings.length === 0) {
    console.log('No problems found.');
    return;
  }
  for (const finding of findings) {
    const fix = finding.repairable ? 'repairable' : 'not repaired automatically';
    console.log(`\n[${finding.severity}] ${finding.title}: ${finding.count} (${finding.check}, ${fix})`);
    console.log(`  ${finding.advice}`);
    for (const sample of finding.samples) console.log(`  - ${JSON.stringify(sample)}`);
    if (finding.count > finding.samples.length) {
      console.log(`  … and ${finding.count - finding.samples.length} more`);
    }
  }
}

async function main(): Promise<void> {
  const target = `${values.database} (${values.remote ? 'remote' : 'local'})`;
  const now = Date.now();
  const report: Record<string, unknown> = { database: target, checkedAt: new Date(now).toISOString() };

  if (values.stats) {
    const accounts = await accountStats(sql, now, values.email);
    report.accounts = accounts;
    if (values.email !== undefined) report.kinds = await kindStats(sql, values.email);
    if (!values.json) {
      console.log(`Accounts in ${target}:`);
      for (const account of accounts) {
        console.log(
          `  ${account.email}: ${account.records} records (${account.deleted} deleted), ` +
            `${account.packs} packs, ${account.bytes} bytes, seq ${account.max_seq ?? '-'}, ` +
            `${account.writes_today}/${writeLimit} writes today, ` +
            `last change ${account.last_updated_at === null ? '-' : time(account.last_updated_at)}, ` +
            (account.verified_at === null ? 'unconfirmed' : `confirmed ${time(account.verified_at)}`),
        );
      }
      for (const kind of (report.kinds as Record<string, unknown>[] | undefined) ?? []) {
        console.log(`    ${kind.kind}: ${kind.records} (${kind.deleted} deleted), ${kind.bytes} bytes`);
      }
      console.log();
    }
  }

  const findings = await checkDatabase(sql, now, { writeLimit });
  report.findings = findings;
  if (!values.json) {
    console.log(`Checked ${target}.`);
    printFindings(findings);
  }

  if (values.repair) {
    const repairs = await repairDatabase(sql, findings, now);
    const after = await checkDatabase(sql, Date.now(), { writeLimit });
    report.repairs = repairs;
    report.afterRepair = after;
    if (!values.json) {
      console.log('\nRepaired:');
      if (repairs.length === 0) console.log('  nothing to repair');
      for (const repair of repairs) console.log(`  ${repair.check}: ${repair.changed} rows changed`);
      console.log('\nChecked again:');
      printFindings(after);
    }
  } else if (!values.json && findings.some((finding) => finding.repairable)) {
    console.log('\nRun again with --repair to repair what is marked repairable.');
  }

  if (values.json) console.log(JSON.stringify(report, null, 2));
  const remaining = (report.afterRepair as Finding[] | undefined) ?? findings;
  process.exitCode = remaining.some((finding) => finding.severity === 'error') ? 1 : 0;
}

main().catch((error: unknown) => {
  console.error(error instanceof Error ? error.message : error);
  process.exitCode = 2;
});
