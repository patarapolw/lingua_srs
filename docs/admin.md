# Sync server administration

Operator tasks for the Cloudflare Worker and its D1 database (see [sync.md](sync.md)). Run these from `worker/`. The database name is the `database_name` in `worker/wrangler.jsonc` (`lingua-srs-sync` below). Add `--remote` to act on the deployed database; without it, wrangler uses the local development database.

Passwords are never stored on the server, so an admin cannot read or reset them. The server keeps only a hash of the derived auth key.

## Look up an account

```
npx wrangler d1 execute lingua-srs-sync --remote --command "SELECT email, verified_at, created_at FROM accounts WHERE email='user@example.com'"
```

- No row: the account was never created.
- `verified_at` is `null`: the account is unconfirmed. Signing in fails with "email confirmation" (HTTP 403), and the app asks for the emailed code. An unconfirmed signup older than 7 days is removed the next time anyone creates an account.
- `verified_at` has a value: the account is confirmed. A "Sync request failed with invalid credentials" error (HTTP 401) then means the password or email is wrong. The server gives the same answer for an unknown email and a wrong password.

Timestamps are milliseconds since the Unix epoch.

## Delete an account

Other tables reference `accounts (email)` with foreign keys, so deleting the account row alone fails with `FOREIGN KEY constraint failed`. Delete the dependent rows first, in one batch:

```
npx wrangler d1 execute lingua-srs-sync --remote --command "DELETE FROM pairing_invites WHERE email='user@example.com'; DELETE FROM records WHERE email='user@example.com'; DELETE FROM inbox WHERE email='user@example.com'; DELETE FROM usage WHERE scope='w:user@example.com'; DELETE FROM email_codes WHERE email='user@example.com'; DELETE FROM accounts WHERE email='user@example.com'"
```

This is the same set of deletions the Worker performs when a user deletes their own account, and it permanently removes all synced data for that email. Use the lowercase, normalized email.

Users can also delete their own account in the app (Settings, Sync, Delete account). An unconfirmed signup can be removed from the confirmation screen with Delete unconfirmed account.

## Let a user start over

If someone cannot sign in because the password is forgotten, the synced data is encrypted and cannot be recovered without it. Delete the account as above; they can then create a new one with the same email.

## Check and repair the database

`scripts/d1-repair.ts` checks the sync database and reports what it finds. It needs Node 22.18 or later, which runs TypeScript as it is. Run it from `worker/`:

```
npm run check-db -- --remote
```

Without `--remote` it checks the local development database. Nothing is changed unless you add `--repair`. The script then repairs what can be repaired safely and checks again:

```
npm run check-db -- --remote --repair
```

Back up first. Either export the database (`npx wrangler d1 export lingua-srs-sync --remote --output backup.sql`), or note the time and use D1 Time Travel (`npx wrangler d1 time-travel restore lingua-srs-sync --timestamp <time>`) to undo a repair.

Other options:

- `--stats` lists each account's records (how many, how many deleted, total size, last change). Add `--email user@example.com` to see one account's records by kind.
- `--json` prints the report as JSON.
- `--database <name>` and `--config <path>` pick the database (default: the `DB` binding) and wrangler config (default: `wrangler.jsonc`).

The exit code is 1 while an error-level finding remains, so the script can run on a schedule.

### What it checks

The server cannot read synced data: record ids are keyed hashes and their contents are encrypted (see [sync.md](sync.md#records)). So the script cannot see duplicate lessons, missing parts of a split record, or anything else about what a record holds; only the account owner's app can. It checks what sync itself relies on.

| Check | Level | Repair |
| --- | --- | --- |
| `duplicate_seq`: records of one account sharing a `seq`, or with `seq` below 1. Devices pull in `seq` order and remember the last one they saw, so such a record can be skipped for good. | error | Moves all but one of each `seq` to new positions at the end of the account. Devices pull them again and ignore the ones they already have. |
| `bad_envelope`: a record that is not deleted, whose data is not `{"v":1,"n":…,"c":…}`. Devices skip it as unreadable. | error | None. Deleting it would delete that record on every device. |
| `invalid_fields`: a kind, id, deleted flag or `updated_at` the Worker would refuse. | error | None. Look at the rows, and delete them by hand if they are junk. |
| `future_updated_at`: dated more than a day ahead. Such a record wins every conflict until then. | warning | None. Whether to keep it is up to the owner. |
| `oversized_records`: data larger than the Worker accepts (32 KiB). | warning | None. |
| `tombstone_data`: a deleted record that still holds data. | cleanup | Empties it. Devices ignore it either way. |
| `orphan_usage`: write counters of an account that no longer exists. `usage` has no foreign key; the other tables do, and D1 always enforces them. | cleanup | Deletes them. |
| `stale_unconfirmed`: unconfirmed signups older than 7 days. | cleanup | Deletes them, with their codes. The Worker would do this at the next signup. |
| `expired_email_codes`, `expired_pairing_invites`, `old_usage`: rows that can no longer be used. | cleanup | Deletes them. The Worker drops them lazily too. |

The checks live in `scripts/repair.ts` and are tested against a local D1 in `test/repair.test.ts`.
