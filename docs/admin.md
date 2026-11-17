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

If someone cannot sign in because the password is forgotten, the synced data is encrypted and cannot be recovered without the password or the account's recovery code. If they have the code, they can recover the account themselves: **Settings → Sync → Forgot password? Use recovery code** in the app (see [sync-guide.md](sync-guide.md#forgot-your-password)). Without it, delete the account as above; they can then create a new one with the same email.

To see whether an account has a recovery code, and when it was made:

```
npx wrangler d1 execute lingua-srs-sync --remote --command "SELECT recovery_created_at FROM accounts WHERE email='user@example.com'"
```

`null` means the account has no code: none was made, or the last one was used to recover the account and no new one was saved. The server keeps only a hash of a key derived from the code and the data key wrapped by the code, so an admin cannot see or reset the code either.

## Update the Worker

Apply new database migrations before deploying Worker code that uses them:

```
npm run migrate        # applies migrations/ to the remote database
npm run deploy
```

`0003_recovery_codes.sql` adds the recovery code columns to `accounts`. Until it is applied, creating a recovery code fails with a server error, and the app says to try again from Settings. Recovering an account with a code uses the same columns and needs no further migration.

## Serve sync from your own domain

The Worker does not count failed sign-ins or recovery attempts: counting them would spend D1 writes (see "Staying inside the free plans" in [sync.md](sync.md#staying-inside-the-free-plans)). A Cloudflare rate limiting rule does it instead (#130). Such rules only apply to traffic through a domain on your Cloudflare account, not to the `workers.dev` address, so the Worker has to move to your own domain first, and the `workers.dev` address has to be turned off. Do the steps in this order. `sync.example.com` stands for your hostname; it goes in the git-ignored `wrangler.jsonc` and `env.json`, never in git.

Every request with credentials checks the password, so a guess can be made on any authenticated path, not only `GET /v1/account` (signing in). The paths an attacker can guess on are:

- `/v1/account`, `/v1/account/pairing`, `/v1/account/recovery`, `/v1/changes`, `/v1/inbox` and `/v1/inbox/<id>`: the password-derived key, in the `Authorization` header.
- `/v1/accounts/recovery` and `/v1/accounts/recovery/complete`: a recovery code.
- `/v1/accounts` and `/v1/accounts/confirm`: signups and the emailed confirmation code.
- `/v1/pairings/<token>`: a pairing token.

That is every path the Worker answers, so the rule covers all of `/v1/`.

### 1. Add the custom domain

The domain's DNS must be on Cloudflare, in the same account as the Worker. Pick a hostname one level below the domain, such as `sync.example.com`. Cloudflare's free Universal SSL certificate covers the domain and one level of subdomain only, so `a.b.example.com` is not covered by it and would need a paid certificate.

Either add it in the dashboard (**Workers & Pages** → the Worker → **Settings** → **Domains & Routes** → **Add** → **Custom domain**), or uncomment `routes` in `wrangler.jsonc` and put your hostname in:

```jsonc
"routes": [
  { "pattern": "sync.example.com", "custom_domain": true }
],
```

and run `npm run deploy`. Keep `workers_dev` set to `true` for now. Cloudflare creates the DNS record and requests the certificate. Wait until the dashboard shows the certificate as active (**SSL/TLS** → **Edge Certificates** for the domain, where the certificate lists the hostname, or its wildcard, with status Active) before going on. This can take a few minutes. Then check that the Worker answers there:

```
curl -s https://sync.example.com/v1/account
```

It should print `{"error":"invalid_credentials"}`.

### 2. Add a rate limiting rule

In the dashboard, open the domain, then **Security** → **WAF** → **Rate limiting rules** → **Create rule**:

- **If incoming requests match:** Hostname equals `sync.example.com` and URI Path starts with `/v1/`. The Worker answers nothing else, so if your plan does not offer that path operator, matching the hostname alone does the same.
- **With the same characteristics:** IP.
- **When rate exceeds:** a number of requests in a period (below).
- **Then take action:** Block, for a mitigation timeout (below).

What a plan includes (how many rules, which periods, timeouts and matching operators) differs between plans and changes; check Cloudflare's [rate limiting rules documentation](https://developers.cloudflare.com/waf/rate-limiting-rules/) for yours. As a starting point only, these values are suggestions, not tested limits:

- One rule on all of `/v1/`: 20 requests per 10 seconds per IP, blocked for 10 seconds (or the shortest timeout offered). A sync usually makes a few requests. A first sync of a large library makes more: it pulls 500 records a request and pushes up to 100 records or packs a request (see [sync.md](sync.md#packs)). The limit slows guessing to about two a second per address; raise it if first syncs get blocked.
- If your plan allows a second rule: a stricter one on the paths that have no regular use, 5 requests per 10 seconds per IP on URI Path starting with `/v1/accounts` (signup, confirmation and both recovery steps; it does not match `/v1/account`, which syncing uses) and on `/v1/pairings/`.

People behind one shared address (an office, a school, mobile carrier NAT) count as one IP. A blocked request gets HTTP 429 from Cloudflare instead of the Worker's answer; the app reports that sync failed and tries again at its next sync. If legitimate users are blocked, look at **Security** → **Events** and raise the numbers.

The rule only sees requests to `sync.example.com`. Until step 4, anyone can still reach the Worker on its `workers.dev` address without a limit.

### 3. Rebuild the app with the new address, and update every device

Set `SYNC_ENDPOINT` in `env.json` to `https://sync.example.com` and build every platform again (see [sync.md](sync.md#server-address)). Ship the new builds and update every device you care about before step 4: both addresses reach the same Worker and database until then, so updated and not yet updated devices keep syncing with each other.

What happens on a device that is already signed in:

- **Updated build:** the saved sign-in does not store the server address when it is the build's own, so the device uses the new address on its own. It stays signed in, unlocks its keys once more with the saved password on the next sync, and carries on where it left off. Nothing to do.
- **Old build, after step 4:** it still uses the `workers.dev` address, so every sync fails. Its data stays on the device, and it syncs again once the app is updated.
- **Pairing links** name the server. A link made on an old build names the `workers.dev` address, and an updated build refuses it ("This pairing link is for a different sync server"). Make new pairing links on an updated device. Pairing links expire 10 minutes after they are made anyway.

### 4. Turn off the workers.dev address

Set `"workers_dev": false` in `wrangler.jsonc` and run `npm run deploy`. Keep `"preview_urls": false`.

### 5. Check that it works

From a computer you can afford to have blocked for a moment, send more requests than the limit allows:

```
for i in $(seq 1 30); do curl -s -o /dev/null -w "%{http_code}\n" https://sync.example.com/v1/account; done
```

The first ones answer `401` (no credentials); once the limit is passed they answer `429`. The blocked requests show up under **Security** → **Events**.

Then check that the old address no longer reaches the Worker (use your Worker's name and `workers.dev` subdomain, as `wrangler deploy` printed it before step 4):

```
curl -s https://lingua-srs-sync.<your-subdomain>.workers.dev/v1/account
```

It should no longer print `{"error":"invalid_credentials"}`. Last, sync from an updated device and check that Settings shows a recent sync.

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

- `--stats` lists each account's records (how many, how many deleted, how many packs, total size, last change) and its writes today against the daily limit. Add `--email user@example.com` to see one account's records by kind.
- `--write-limit <n>` is the Worker's `MAX_WRITES_PER_DAY`, if you changed it from 2000.
- `--json` prints the report as JSON.
- `--database <name>` and `--config <path>` pick the database (default: the `DB` binding) and wrangler config (default: `wrangler.jsonc`).

The exit code is 1 while an error-level finding remains, so the script can run on a schedule.

### What it checks

The server cannot read synced data: record ids are keyed hashes and their contents are encrypted (see [sync.md](sync.md#records)). So the script cannot see duplicate lessons, missing parts of a split record, or anything else about what a record holds; only the account owner's app can. It checks what sync itself relies on.

| Check | Level | Repair |
| --- | --- | --- |
| `write_limit_reached`: accounts that have written as many records today as `MAX_WRITES_PER_DAY` allows. Their pushes stop with `429 quota_exceeded` until midnight UTC; the app keeps what got through and sends the rest then. | warning | None. To let an account finish today, delete today's counter (below). |
| `duplicate_seq`: records of one account sharing a `seq`, or with `seq` below 1. Devices pull in `seq` order and remember the last one they saw, so such a record can be skipped for good. | error | Moves all but one of each `seq` to new positions at the end of the account. Devices pull them again and ignore the ones they already have. |
| `bad_envelope`: a record that is not deleted, whose data is not `{"v":1,"n":…,"c":…}`. Devices skip it as unreadable. | error | None. Deleting it would delete that record on every device. |
| `invalid_fields`: a kind, id, deleted flag or `updated_at` the Worker would refuse. | error | None. Look at the rows, and delete them by hand if they are junk. |
| `future_updated_at`: dated more than a day ahead. Such a record wins every conflict until then. | warning | None. Whether to keep it is up to the owner. |
| `oversized_records`: data larger than the Worker accepts (32 KiB). | warning | None. |
| `tombstone_data`: a deleted record that still holds data. | cleanup | Empties it. Devices ignore it either way. |
| `orphan_usage`: write counters of an account that no longer exists. `usage` has no foreign key; the other tables do, and D1 always enforces them. | cleanup | Deletes them. |
| `stale_unconfirmed`: unconfirmed signups older than 7 days. | cleanup | Deletes them, with their codes. The Worker would do this at the next signup. |
| `expired_email_codes`, `expired_pairing_invites`, `old_usage`: rows that can no longer be used. | cleanup | Deletes them. The Worker drops them lazily too. |

Records of kind `pack` each hold many records: a large push, such as a first sync, sends them so a whole library fits the daily limit (see [sync.md](sync.md#packs)). The app never changes or deletes a pack, so packs stay on the server after their records change. That is expected; `--stats` counts them.

### Let an account finish syncing today

The daily write limit keeps the free plan. To let one account past it today, delete today's counter (UTC date):

```
npx wrangler d1 execute lingua-srs-sync --remote --command "DELETE FROM usage WHERE scope='w:user@example.com' AND day='2026-11-09'"
```

The account can then write `MAX_WRITES_PER_DAY` more records today.

The checks live in `scripts/repair.ts` and are tested against a local D1 in `test/repair.test.ts`.
