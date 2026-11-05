# Sync and dictionary import (design)

How devices sync, and how a separately developed dictionary app sends content to LinguaSRS. Every account lives on one hosted Cloudflare Worker backed by D1, and data is end-to-end encrypted: the server only stores ciphertext. See issue #2. This also covers the content-import half of #45.

Implemented so far: the Worker (`worker/`), account creation and email confirmation, sign-in, password changes, one-time device pairing, account deletion, and password-derived account keys. Record encryption and the sync engine are follow-up work.

## Server address

The address of the hosted Worker is not in git. It is read at build time from the `SYNC_ENDPOINT` setting:

```
cp env.example.json env.json    # env.json is git-ignored
flutter run --dart-define-from-file=env.json
flutter build apk --dart-define-from-file=env.json
```

In VS Code, run the `lingua_srs (sync server)` launch configurations, and use the `(sync server)` tasks to build. In Android Studio or IntelliJ, run the shared `lingua_srs (sync server)` configuration, which passes the flag as *Additional run args*. Both need `env.json` to exist; the plain configurations work without it, and then the app has no Sync section. The **Build** menu in Android Studio does not pass the flag, so build from the terminal or a task. The flag also reads a `.env` file, and either format works; JSON is used here because it is strict, and every editor understands it. Either way the values are compiled into the app, so only put things in it that you could print on the app's own screen.

The address ends up inside the shipped app, so it is configuration and not a secret; keeping it out of git stops forks and test builds from pointing at the hosted server. A build without it has no Sync section in Settings. `http://` is only accepted for a local Worker (`localhost`, `127.0.0.1`, `10.0.2.2`).

## Where credentials are kept

Sign-in details and the DeepSeek key go in the OS keychain through `flutter_secure_storage`, not in preferences.

- **Linux**: building needs `libsecret-1-dev` (`libsecret-devel` on Fedora), and running needs a Secret Service keyring, such as GNOME Keyring or KWallet, unlocked in the session. A locked or missing keyring does not crash the app.
- **macOS**: the app uses the login keychain, so it needs no `keychain-access-groups` entitlement and no provisioning profile, and an ad-hoc signed build can store credentials. The sandbox entitlements include `com.apple.security.network.client`, without which every outgoing request fails.
- **Android, iOS, Windows**: nothing to set up.

## Accounts

An account is an **email** (its unique identifier, lowercase) and a **password** the user chooses. A device signs in by:

- typing the email and password,
- choosing *Use copied link* after copying a one-time pairing link from a signed-in device, which works on a desktop that cannot scan a QR code and asks to confirm first,
- scanning the one-time pairing link's QR code on a mobile device opens the app, which asks to confirm and then signs in.

```
linguasrs://pair?token=<one-time-token>#<encryption-key>
```

The link contains no plaintext password. The device encrypts the pairing credentials with a random key in the URL fragment; the Worker stores only the encrypted payload and a hash of the one-time token. The link expires after 10 minutes and can be redeemed only once. It is still a bearer credential granting access to the account, so only share it with a device you control. Copy it to the clipboard for desktop sign-in, or scan the QR code on mobile. Pairing credentials are stored in the device's secure storage and are never included in a backup.

Before a pairing link signs a device in, the app shows the email and the server and asks. A link can come from anywhere (a message, a web page, a poster with a QR code), and signing in to someone else's account would sync this device's lessons into it. A release build also follows pairing links only to the built-in server, so a link cannot move the device onto another one; debug and profile builds allow a local Worker. A link that carries a password itself is not accepted.

An email or a password can contain any characters, including spaces, emoji and characters from any script. The same text typed on different devices can be different characters (an accent typed as one character or as a letter and a combining mark, full-width letters and digits), and equivalent spellings must give the same account and the same keys. So the email is trimmed, put in Unicode form NFKC, lowercased and put in NFKC again, in the app and in the Worker alike, and the password is put in NFKC before key derivation. The saved password stays exactly as typed, with its spaces, and plain ASCII is unchanged, so accounts with an ASCII password are not affected. The one thing that cannot be kept is half of a surrogate pair (an invalid character with no UTF-8 form), which is refused instead of being silently changed. A text field cannot hold a newline, so one pasted into the password field is dropped. The tests build their awkward characters at random from a seed instead of writing them out, so they cover more than anyone thought of, and a failure can be replayed from its seed. A password may even start with a byte order mark (U+FEFF); the saved sign-in link is read with a decoder of its own, because the standard one would drop that character.

## Keys

The password never leaves the device. Everything the server sees is derived from it on the device:

```
master  = Argon2id(password, salt = "linguasrs:" + email)
authKey = HKDF(master, "auth")      sent as the Basic credential email:authKey
wrapKey = HKDF(master, "wrap")      never leaves the device
```

The app computes Argon2id with the pure Dart implementation off the UI isolate, so key derivation does not depend on loading a platform-native library.

The server stores `SHA-256(authKey)`. Stealing the database therefore gives an attacker nothing to replay, only a stretched value to guess passwords against, which Argon2id makes expensive.

Records are encrypted with a random 256-bit **data key** created with the account. The server keeps it wrapped: `AES-256-GCM(wrapKey, dataKey)`. A new device signs in, downloads the wrapped key and unwraps it. Because the password only wraps the data key, **changing the password re-wraps one key and re-encrypts nothing**. Each record is `AES-256-GCM(dataKey, data)` with a random nonce and the record's `kind` and `id` as associated data, so a record cannot be swapped for another.

The server can still see the email, each record's `kind` and `id`, `updatedAt`, whether it is deleted, and sizes. Everything inside `data` is hidden.

If the password is forgotten and no device is signed in, the data cannot be recovered; that is the cost of end-to-end encryption. A printable recovery code (the data key) shown at account creation would fix that and is worth adding. The email can prove ownership and allow the account to be reset, but it can never bring the data back.

## Password rules

Applied only **when an account is created or the password is changed**, never at sign-in, so an account made under an older rule can always sign in. The app uses the published [`password_rules`](https://pub.dev/packages/password_rules) package, configured with the policy below:

- **15–64 user-perceived characters**, counted with Unicode grapheme clusters, using the package's NIST preset. The cryptographic derivation itself has no maximum, but the app enforces the package's 64-character policy limit. Spaces and any Unicode are allowed; there are no character-composition requirements.
- **No required numbers or special characters.** Composition requirements would rule out useful word-based passphrases without replacing the need for length, randomness, and blocklist checks.
- **Reject common passwords** using the package's `CommonPasswordsRule`, which blocks the 1,000 most common leaked passwords case-insensitively.
- **Reject breached passwords** using an additional Have I Been Pwned k-anonymity range query; only the first five characters of the password's SHA-1 are sent. Account creation and password changes stop if the breach-list service is unavailable.
- **Visibility:** Password and confirmation fields have independent show/hide controls, so revealing one does not reveal the other.
- **No scheduled changes.** Forced rotation makes people pick small variations of the old password. Change it after a suspected leak, or if the password was reused elsewhere that was breached.
- Offer a generated passphrase of six independently and uniformly selected words from a 2048-word list. Six random words have about 66 bits of selection entropy before blocklist exclusions (five would have about 55 bits), and even the longest possible six words stay inside the 64 character limit. This is not the same as choosing a familiar phrase or selecting the words yourself: predictable word choices make dictionary attacks much easier. The generated phrase is checked against the local policy and breached-password list before being copied into both password and confirmation fields. These checks do not make a manually chosen phrase random. A password manager helps and autofill is supported, but nothing requires one.

The package's `PasswordRules.nist()` preset supplies the 15-character minimum, 64-character maximum, and common-password blocklist used by Sync.

## Other factors, deliberately not used

- **PIN**: only 10^n possibilities, so it is trivial to guess offline from anything derived from it, and easy to watch being typed. It is acceptable only as a local app lock where the device limits attempts. It must never derive the sync or encryption keys.
- **SMS or email codes**: SMS can be intercepted or taken over by moving the number to another SIM, and an emailed code is only as safe as the mailbox. Neither can produce the data key. Email is used to confirm ownership and to start an account reset.
- **Biometrics**: not secrets, cannot be changed once leaked, and leaks of fingerprint data have happened. At most they unlock a key kept in the device's own secure storage. The biometric itself is never sent anywhere.
- **Later**: an authenticator-app (TOTP) code or a passkey as a second factor at the server. It protects the account from being locked or deleted, not the data, which the password already protects.

## Creating an account

1. The app checks the password policy, derives the keys from the password (see Keys), creates a random data key, wraps it with the password-derived key, and sends `{email, authKey, wrappedDataKey, kdf}` to `POST /v1/accounts`.
2. The Worker stores the account as **unconfirmed** and emails an **8 digit code** (valid for 30 minutes). The answer is always `202`, whether or not the email already has an account, so it cannot be used to find out who is registered.
3. The app asks for the code and sends `{email, authKey, code}` to `POST /v1/accounts/confirm`. After pasting the code, tap **Confirm email**; a password-manager save prompt does not confirm the account. Only then can the account be used. The policy is enforced by the app because the password itself never leaves the device; the Worker only receives derived keys.

The code is typed into the app that started the signup, instead of being a link to click, on purpose. A link would confirm whatever credentials were last submitted for that email, so someone could start a signup with your email and their own password, and you would activate it by clicking. With a code, confirming needs both the emailed code and the credentials of the signup, and a repeated signup replaces the pending credentials, so an attacker can at worst be a nuisance. Five wrong codes cancel the code. A repeated signup within 10 minutes reuses the code already sent instead of sending another email. A signup nobody confirms is forgotten after 7 days.

To change a password, a signed-in device checks the new password policy, downloads the wrapped data key, unwraps it with the current password, wraps the same key with the new password, and sends the new authentication key and wrapped key to `PUT /v1/account`. No records are re-encrypted. The device replaces its saved sign-in only after the Worker accepts the change.

To delete an account, choose *Delete account* in Settings and confirm. This permanently deletes the server account, its encrypted records, inbox, and outstanding pairing invites. Local lessons and progress on that device are not deleted.

### Other devices after a deletion or a password change

Nothing contacts the server in the background yet, so a device that was signed in to the account keeps showing it as signed in, with its lessons and progress untouched, until something uses the server. Then the server answers `401`. It gives the same answer for an account that was deleted and for a password that was changed on another device, because it never says whether an email has an account, so the app cannot tell which happened. It says that the server no longer accepts this sign-in and that the lessons are still on the device. *Check sign-in* in Settings asks on demand. The app never signs a device out by itself: the person chooses to sign out and sign in again with the new password, or to create a new account.

When the sync engine exists it must handle a rejected sign-in the same way: stop syncing, keep the local data, and say so. It must also notice an account that was **re-created**. Signing in is deterministic (the keys come from the email and password), so if an account is deleted and a new one is created with the same email and password, a device that was signed in to the old one would be accepted by the new one. The new account has a different data key and its own change numbers. The engine therefore has to compare an identity of the account (for example its creation time, returned by `GET /account`) every time it connects, and when it differs, stop and ask instead of carrying on with the old data key and pull cursor.

## Worker API

Routes live under `/v1`. Except for the first two, they need `Authorization: Basic base64(email:authKey)`; a wrong email or key is always `401 invalid_credentials`. An unconfirmed account gets `403 email_not_confirmed` on normal account operations, but can use `DELETE /account` with its correct credentials to delete the pending account and code. Bodies are JSON, errors are `{"error": "<code>"}`, and nothing is cached.

| Route | Purpose |
| --- | --- |
| `POST /accounts` | Starts an account, see above. `400 invalid_account`, `429 signups_paused`, `502 email_failed`. |
| `POST /accounts/confirm` | Body `{email, authKey, code}`. Returns `{status: "verified"}`; every failure is `400 invalid_code`. |
| `GET /account` | Returns `{wrappedDataKey, kdf}`. |
| `PUT /account` | Changes the password with `{authKey, wrappedDataKey, kdf?}`; the data is untouched. |
| `DELETE /account` | Deletes the account and everything in it. Also available to an unconfirmed account with the correct credentials. |
| `POST /account/pairing` | Creates a short-lived one-time pairing invite and returns its token. The body contains only the encrypted pairing payload. |
| `GET /pairings/{token}` | Redeems and consumes an invite, returning its encrypted payload. No authentication: the 256 bit token is the secret. |
| `GET /changes?since=N&limit=M` | Records changed after cursor `N` (default 0), oldest change first, at most 500. Returns `{records, cursor, hasMore}`. |
| `POST /changes` | Body `{records: [...]}`, 1 to 100 records. Returns `{accepted: n}`. |
| `GET /inbox` | Returns `{items: [{id, text, createdAt}]}`, at most 100. |
| `POST /inbox` | Body `{text}`, up to 64 KB. Returns `201 {id}`; `429 inbox_full` at 100 items. |
| `DELETE /inbox/{id}` | Removes an item once imported or dismissed. Removing a missing item is not an error. |

A record is `{kind, id, updatedAt, deleted, data}`. `kind` is lowercase letters, digits and `_`; `id` is up to 128 characters; `data` is the encrypted envelope, an object of up to 32 KB that the server never looks inside. `updatedAt` is milliseconds on the device clock, and a date more than a day ahead is refused, because it would win every conflict for good. A deleted record stays as a tombstone and its `data` is dropped.

### Conflicts

The record with the newest `updatedAt` wins. An older or equal copy is ignored and not counted in `accepted`, so repeating a push is harmless. Every stored change gets the account's next `seq`, and that is the pull cursor, so a device never misses a change however its clock drifts.

### Dictionary inbox

The dictionary app signs in with the same email and password, like another device, so it can encrypt what it posts. The text is in the [lesson format](lesson-format.md) (a new lesson, or a lesson name plus the new vocab to add). LinguaSRS decrypts and lists the inbox, shows the existing import preview and validation, and only then imports. All parsing stays in `YamlParserService`.

## Staying inside the free plans

Cloudflare's free plans have no bill: past their daily limits requests simply fail, so the worst case is that sync pauses until the next UTC day while every app keeps working offline. The Worker adds its own limits so one account, or a flood of signups, cannot use everything up. They are settings in `wrangler.jsonc`:

- `MAX_EMAILS_PER_DAY` (default 50): confirmation emails sent across all accounts. Keep it under your email provider's free limit (Resend's free plan allows 100 a day). When it is reached, signups answer `429 signups_paused` until the next UTC day.
- `MAX_WRITES_PER_DAY` (default 2000): records and inbox items one account can write per UTC day, answered with `429 quota_exceeded` and a `Retry-After`. Reading is not limited.
- A record is at most 32 KB, a push 100 records and 1 MB, an inbox item 64 KB.

A changed record costs about three D1 row writes (the row and its two indexes), so the free plan's 100,000 writes a day is roughly 30,000 record changes. The app should merge repeated changes to one card into a single record and push in batches.

Not done yet: limiting failed sign-ins per address. Add a Cloudflare rate limiting rule for `/v1/*` in the dashboard (check what your plan includes), because the Worker itself cannot count attempts without spending D1 writes on them. Rules on your own domain apply to traffic through that domain and not to the `workers.dev` address, so serve the Worker from a custom domain and set `workers_dev` to `false` when you add one.

## Running your own

```
cd worker
npm install
cp wrangler.example.jsonc wrangler.jsonc    # git-ignored; put your real values here
npx wrangler d1 create lingua-srs-sync      # copy its database_id into wrangler.jsonc
npm run migrate                             # applies migrations/ to that database
npx wrangler secret put RESEND_API_KEY      # a Resend key, for a domain you verified there
npm run deploy
```

Set `MAIL_FROM` in `wrangler.jsonc` to an address on the domain you verified with Resend. The example config sets `workers_dev` and `preview_urls` so that `wrangler deploy` does not warn: the Worker is served on its `workers.dev` address, and preview URLs, which would expose every uploaded version with the production database attached, are off. Then build the app with `SYNC_ENDPOINT` set to the Worker's address (see Server address). `wrangler.jsonc` and `.dev.vars` are git-ignored, so your database id and address never reach git.

Apply database migrations to the configured D1 database before deploying Worker code that depends on them. If a pairing request fails with a server error after an update, check `npx wrangler d1 migrations list DB --remote` and apply pending migrations with `npm run migrate`; the Worker needs the `pairing_invites` table created by migration `0002_pairing_invites.sql`.

For local development, `cp .dev.vars.example .dev.vars`, run `npm run migrate:local` and `npm run dev`. Confirmation codes are printed to the console instead of being emailed. `npm test` runs the tests against a local D1.

## D1 schema

The ordered migrations in `worker/migrations/` define the schema. In short:

- `accounts`: `email` (key), `auth_hash` (SHA-256 of the auth key), `wrapped_data_key`, `kdf`, `verified_at`, `created_at`.
- `email_codes`: one pending code per email, stored as a hash, with its attempts and expiry.
- `records`: `(email, kind, id)` is the key; `seq`, `updated_at`, `deleted` and the encrypted `data`; indexed by `(email, seq)` for pulling.
- `inbox`: encrypted items waiting to be imported.
- `usage`: the daily counters behind the limits above.
- `pairing_invites`: hashed one-time tokens, encrypted credentials and expiry times.

A stored record is changed by an upsert that only applies when the incoming `updatedAt` is newer, and that gives it the account's next `seq` in the same statement.

## Not covered yet

- Which record kinds exist and how they map to lessons, sentences and SRS cards.
- Resetting a forgotten password (confirmed by email, which starts a fresh account because the data cannot be decrypted without the old password), and an authenticator-app second factor.
- Limiting failed sign-ins per address, see above.
