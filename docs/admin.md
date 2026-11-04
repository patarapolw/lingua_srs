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
