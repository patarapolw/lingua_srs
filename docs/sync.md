# Sync and dictionary import (design)

How devices sync, and how a separately developed dictionary app sends content to LinguaSRS. For how to use it, see [Using sync](sync-guide.md). Every account lives on one hosted Cloudflare Worker backed by D1, and data is end-to-end encrypted: the server only stores ciphertext. See issue #2. This also covers the content-import half of #45.

Implemented so far: the Worker (`worker/`), account creation and email confirmation, sign-in, password changes, one-time device pairing, account deletion, and password-derived account keys. Records describes what will sync; building, encrypting, pulling, pushing and applying records is implemented (`SyncEngine`, `SyncApplier`), and the app syncs on its own while signed in (see When the app syncs). A device that already has data merges it with the account's on its first sync (see Joining an account with data).

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

Sign-in details, the account's unlocked data key and the DeepSeek key go in the OS keychain through `flutter_secure_storage`, not in preferences.

- **Linux**: building needs `libsecret-1-dev` (`libsecret-devel` on Fedora), and running needs a Secret Service keyring, such as GNOME Keyring or KWallet, unlocked in the session. A locked or missing keyring does not crash the app.
- **macOS**: the app uses the login keychain, so it needs no `keychain-access-groups` entitlement and no provisioning profile, and an ad-hoc signed build can store credentials. The sandbox entitlements include `com.apple.security.network.client`, without which every outgoing request fails.
- **Windows**: nothing to set up. They are not in Credential Manager: they go in `flutter_secure_storage.dat` in the app's data folder (`%APPDATA%\cc.polv\lingua.srs`), next to the preferences, encrypted with DPAPI for the signed-in Windows user. A copy of that folder includes them, but only the same Windows user can decrypt them.
- **Android, iOS**: nothing to set up.

`integration_test/platform_test.dart` stores and reads a secret and makes an HTTPS request on a real build. The Desktop workflow runs it on macOS and Linux (with GNOME Keyring under `dbus-run-session`) whenever platform code changes.

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

The server stores only `SHA-256(authKey)`, not the auth key itself.

Records are encrypted with a random 256-bit **data key** created with the account. The server keeps it wrapped: `AES-256-GCM(wrapKey, dataKey)`. A new device signs in, downloads the wrapped key and unwraps it. Because the password only wraps the data key, **changing the password re-wraps one key and re-encrypts nothing**. Each record is `AES-256-GCM(dataKey, data)` with a random nonce and the record's `kind` and `id` as associated data, so a record cannot be swapped for another.

The server can still see the email, each record's `kind` and `id`, `updatedAt`, whether it is deleted, and sizes. A record's `id` is a keyed hash, so it does not reveal the word or lesson behind it (see Record ids). Everything inside `data` is hidden.

If the password is forgotten and no device is signed in, the data cannot be recovered. A recovery code (the data key) shown at account creation, planned in #2, would allow it. The email can be used to reset the account, but not to bring the data back.

## Password rules

These are this app's choices. They are checked only when an account is created or the password is changed, never at sign-in, so an account made under older rules can always sign in. The app uses the [`password_rules`](https://pub.dev/packages/password_rules) package's `PasswordRules.nist()` preset, plus a breach check:

- 15–64 characters, counted as the characters a person sees (grapheme clusters). Spaces and any Unicode are allowed, and no particular kinds of characters are required.
- Not one of the package's 1,000 most common passwords, ignoring case.
- Not in Have I Been Pwned's list of breached passwords. Only the first five characters of the password's SHA-1 are sent. If that service cannot be reached, the account is not created or the password is not changed.
- No scheduled password changes.

The password and confirmation fields each have their own show/hide button. The app can also generate a passphrase of six random words from a 2,048-word list, checked against the same rules, and fill both fields with it. Password-manager autofill works.

## Other sign-in methods

Only the email and password sign in and derive the keys. PINs, SMS or email codes and biometrics are not used for either. An authenticator-app code may be added later as a second factor.

## Creating an account

1. The app checks the password policy, derives the keys from the password (see Keys), creates a random data key, wraps it with the password-derived key, and sends `{email, authKey, wrappedDataKey, kdf}` to `POST /v1/accounts`.
2. The Worker stores the account as **unconfirmed** and emails an **8 digit code** (valid for 30 minutes). The answer is always `202`, whether or not the email already has an account, so it cannot be used to find out who is registered.
3. The app asks for the code and sends `{email, authKey, code}` to `POST /v1/accounts/confirm`. After pasting the code, tap **Confirm email**; a password-manager save prompt does not confirm the account. Only then can the account be used. The policy is enforced by the app because the password itself never leaves the device; the Worker only receives derived keys.

The code is typed into the app that started the signup, rather than clicked as a link, so confirming needs both the emailed code and that signup's credentials. A link would confirm whatever credentials were last submitted for the email, including someone else's. A repeated signup replaces the pending credentials. Five wrong codes cancel the code. A repeated signup within 10 minutes reuses the code already sent instead of sending another email. A signup nobody confirms is forgotten after 7 days.

To change a password, a signed-in device checks the new password policy, downloads the wrapped data key, unwraps it with the current password, wraps the same key with the new password, and sends the new authentication key and wrapped key to `PUT /v1/account`. No records are re-encrypted. The device replaces its saved sign-in only after the Worker accepts the change.

To delete an account, choose *Delete account* in Settings and confirm. This permanently deletes the server account, its encrypted records, inbox, and outstanding pairing invites. Local lessons and progress on that device are not deleted.

### Other devices after a deletion or a password change

A device that was signed in to the account finds out at its next sync, or when *Check sign-in* is used: the server answers `401`. It gives the same answer for an account that was deleted and for a password that was changed on another device, because it never says whether an email has an account, so the app cannot tell which happened. It says that the server no longer accepts this sign-in and that the lessons are still on the device. *Check sign-in* in Settings asks on demand. The app never signs a device out by itself: the person chooses to sign out and sign in again with the new password, or to create a new account.

When the sync engine exists it must handle a rejected sign-in the same way: stop syncing, keep the local data, and say so. It must also notice an account that was **re-created**. Signing in is deterministic (the keys come from the email and password), so if an account is deleted and a new one is created with the same email and password, a device that was signed in to the old one would be accepted by the new one. The new account has a different data key and its own change numbers. The engine therefore has to compare an identity of the account every time it connects, and when it differs, stop and ask instead of carrying on with the old data key and pull cursor. That identity is `createdAt` from `GET /account`: the time the signup started, fixed once the email is confirmed, kept through password changes, and different for a re-created account. `SyncClient.getAccount` returns it, as `null` from an older Worker that does not send it.

## Worker API

Routes live under `/v1`. Except for the first two, they need `Authorization: Basic base64(email:authKey)`; a wrong email or key is always `401 invalid_credentials`. An unconfirmed account gets `403 email_not_confirmed` on normal account operations, but can use `DELETE /account` with its correct credentials to delete the pending account and code. Bodies are JSON, errors are `{"error": "<code>"}`, and nothing is cached.

| Route | Purpose |
| --- | --- |
| `POST /accounts` | Starts an account, see above. `400 invalid_account`, `429 signups_paused`, `502 email_failed`. |
| `POST /accounts/confirm` | Body `{email, authKey, code}`. Returns `{status: "verified"}`; every failure is `400 invalid_code`. |
| `GET /account` | Returns `{wrappedDataKey, kdf, createdAt}`. `createdAt` (milliseconds) identifies the account, see below. |
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

## Records

What the app stores on the server, one record per piece of data. Building the records, noticing changes (see Change tracking), encrypting, splitting and decrypting them (`SyncRecordCipher`), pulling and pushing them (see Sync engine), applying them to the app's data (see Applying pulled records), and running syncs (see When the app syncs) are implemented.

### What syncs

Everything a backup contains syncs, except what only makes sense on one device:

- **Syncs:** lessons and their Markdown, vocabulary entries, word details and SRS progress, the Sentence Pool, merge history, saved AI discussions, the lesson tree's order, study activity, and the study settings listed below.
- **Stays on the device:** the DeepSeek key and the sync sign-in (secrets), which folders are expanded, the fingerprints of imported Markdown files (they are keyed by a path on this device), the audio and image caches, and one-off migration flags.

### Kinds

| Kind | One record per | Contents | Conflicts |
| --- | --- | --- | --- |
| `lesson` | lesson | Title, unit, languages, and the vocabulary entries as `VocabItem.toJson()` writes them, without the shared fields (details and cards). | Newest wins. |
| `lesson_md` | lesson with Markdown | The lesson's Markdown. | Newest wins. |
| `vocab` | vocab id | The `SharedVocab` details (audio, TTS text, notes, disambiguation, their provenance and alternates), and each card's settings: enabled, suspended, front hint, back notes, card id. | Newest wins. |
| `card` | SRS card | Scheduling only: interval, repetitions, ease, due date, status, lapses and the review and mistake dates, plus the vocab id and direction. | Newest wins. |
| `sentence` | sentence | `Sentence.toJson()`. | Newest wins. |
| `merge` | merge record | `VocabMergeRecord.toJson()`. Undoing a merge deletes its record. | Newest wins. |
| `discussion` | saved AI discussion | Its messages. | Merged: the union of both sides' messages, by time. |
| `activity` | device and day | That device's review count for the day, the same reviews counted per rating (`ratings`, such as `{"good": 3, "again": 1}`), how many of them started a new card (`newCards`), and its review times while they still count toward the rolling 24-hour limits. Days counted before ratings and new cards were recorded, and records from older app versions, have no `ratings` or `newCards`, so a day's ratings can add up to less than its count. | None: only that device writes it. |
| `lesson_order` | account (one record) | The lesson tree's manual order. | Newest wins. |
| `settings` | account (one record) | Review limits per 24 hours, autoplay, and the pronunciation lines shown. | Newest wins. |

Why it is split this way:

- **SRS progress is apart from everything else.** A review rewrites one `card` record (about 300 bytes), not a lesson. Editing a card's back note on one device while reviewing it on another does not lose either change, because the note is in `vocab` and the schedule is in `card`.
- **Shared things are stored once.** Entries with the same vocab id share details and progress in the app, so they share one `vocab` record and its two `card` records, however many lessons contain the word.
- **Activity is never in conflict.** Each device writes only its own `activity` records, and the totals are the sums across devices, so two devices studying offline on the same day both count. The heatmap and the rolling review and new-card limits read these sums, so studying on two devices does not double the daily limit.
- **A discussion is merged, not replaced.** Asking the AI about the same word on two devices would otherwise keep only one side's messages.

Two devices reviewing the same card offline: the later review wins, and the earlier one is lost from the schedule but still counted in activity. This app accepts that, because it is simpler than replaying both reviews.

### Record ids

The server sees each record's kind and id, so an id must not give away content. A generated vocab id is `auto-` and an unkeyed SHA-256 of the language, word and meaning, so anyone could test it against a dictionary. An explicit `id` from a lesson file can be a plain word.

So the record id is a keyed hash of the local id: `base64url(HMAC-SHA256(idKey, kind + ":" + localId))`, 43 characters, with `idKey = HKDF(dataKey, "record-id")`. Only devices with the data key can compute it. The local id is kept inside the encrypted data, so a pulled record maps back to it. An `activity` record's local id is `<device id>:<YYYY-MM-DD>`, where the device id is random, made once per install, and kept with the sync sign-in. The single records use `lesson_order` and `settings` as their local ids.

### Encrypted envelope

A record's `data` is:

```
{"v": 1, "n": "<nonce, base64url>", "c": "<ciphertext, base64url>"}
```

The ciphertext is `AES-256-GCM(dataKey, gzip(JSON))`, with a random 96-bit nonce and `kind + "\0" + record id` as associated data, so the server cannot move a record to another kind or id. The JSON holds `localId`, `schema` (this kind's format version, starting at 1) and the contents.

A device that pulls a record with a `schema` newer than it understands keeps the record as it came and does not overwrite it, and asks for the app to be updated. Otherwise an old version would push back a record with the fields it does not know dropped.

### The data key on the device

A device unlocks the data key once per sign-in: it derives the keys from the password, downloads the wrapped key with `GET /account`, and unwraps it. The unlocked key is kept in the keychain with the server, the email and the account's `createdAt`, so a sync does not derive keys from the password every time. Signing in, signing out or changing the sign-in removes it, so it is unlocked again for the new sign-in.

### Large records

The Worker refuses `data` over 32 KB, which leaves about 24 KB of compressed content, roughly 80–100 KB of Markdown or JSON. Lesson Markdown, a long discussion, or a lesson with several hundred words can be bigger. Such a record is split:

- Parts are stored as records of the same kind, with local ids made of the record's local id, a NUL character and the part number from 1. No id contains NUL, so a part cannot have the same id as another record. Each part holds a slice of up to 16 KB of the compressed bytes.
- The record itself then holds `parts` (the count) and `sha256` (of the whole compressed content) instead of the contents.
- Parts are pushed before the record that lists them. A device assembles the content only when every part is present and the hash matches; until then it keeps its own copy.
- Parts that are no longer needed (after the content shrinks) are deleted.

### Deleting

Deleting a lesson, sentence, merge record, discussion or Markdown pushes a tombstone for it, and for its parts.

`vocab` and `card` records are never deleted because a lesson was removed. Whether a word is still used depends on every lesson on every device, and one device deleting the last lesson that it knows of while another imports the word again would lose that word's progress. An unused `vocab` or `card` record costs a few hundred bytes, and it brings the progress back if the word is imported again. Pruning them can come later, once every device is known to be in sync.

### Change tracking

The device notices changes by comparing contents instead of marking each edit, so no edit path can be missed. `SyncSnapshot` builds every record from the app's state, and `SyncChangeTracker` keeps a hash of each one. A record whose hash changed gets `updatedAt` set to the time the change was noticed and becomes pending. A record that is gone becomes a pending deletion, except `vocab` and `card` records. The first run after signing in sees every record as new, which is how data from before sync gets pushed. If the device clock has been set back, the new `updatedAt` is still later than the last one.

The tracker also keeps the pull cursor and a random device id, which names this device's `activity` records. It is stored on the device only (`lingua_srs_sync_state`), never in a backup, and a restore leaves it alone. Signing out forgets the records and the cursor but keeps the device id, so signing in again does not count this device's activity twice. Restoring a backup on a signed-in device is seen as edits: records missing from the backup become deletions.

Changes are checked by `AppProvider.trackSyncChanges`. The sync engine calls it before each sync, and calls after edits come with scheduling (steps 4 and 6 in #2).

### Sync engine

`SyncEngine.sync` runs one sync of an account:

1. `GET /account`. A `createdAt` different from the one the data key was unlocked with means the account was re-created: it stops, changes nothing, and reports it. A `401` stops the same way.
2. Notes local changes (Change tracking).
3. Pulls everything after the stored cursor and decrypts it. Parts are kept until their head arrives. A record that cannot be decrypted or put together is skipped and counted.
4. Decides each pulled record:
   - its own push coming back, or a version it already has: nothing to do;
   - written by a newer app (a newer `schema`): left alone here and never pushed over, and reported;
   - changed on this device too: the newer `updatedAt` wins, except AI discussions, whose messages are merged and pushed, and a sentence this device edited that another device deleted, whose edit is kept and pushed with a newer `updatedAt` (another device deletes a sentence when it merges duplicates, #90);
   - otherwise applied.
5. Applies the pulled records through a `SyncRecordStore`, notes what they now hash to so they are not pushed back, and saves the cursor.
6. Pushes what is still pending: whole records, or parts followed by their head, deletions as tombstones, and tombstones for parts a record no longer needs.

### Applying pulled records

`SyncApplier` is the reverse of `SyncSnapshot`, and `AppProvider` is the engine's store: it applies a batch, saves only what changed, and updates the screens.

- A word's details (`vocab`) and its cards' progress (`card`) are changed in place, so every lesson with that word and any open study screen see the change. A lesson pulled with new words gets their details and progress from the same batch. A `vocab` or `card` record for a word that no lesson on this device uses is dropped.
- A pulled lesson keeps this device's Markdown until a `lesson_md` record changes it.
- Other devices' `activity` records are kept apart from this device's counts (`lingua_srs_sync_remote_activity`). The activity calendar and the rolling 24-hour review limit add them up; the new-card limit already counts every device, because it comes from the cards' first-review dates.
- Merge history keeps the newest 20 records, as on one device.

### When the app syncs

While a device is signed in, the app syncs on its own (`SyncScheduler`, in `main.dart`):

- when it starts, or right after signing in;
- when it comes back to the foreground;
- 20 seconds after the last change in the app, if a record actually changed. Each change restarts the wait, so a study session syncs once it pauses, not after every card;
- again on its own after a sync that could not reach the server, or that the server failed (5xx): after 30 seconds, then waiting twice as long each time, up to 5 minutes, until a sync goes through. A rejected sign-in or a re-created account is not retried.

*Sync now* in Settings syncs at once. Settings also shows when this device last synced and, if the last sync stopped or was incomplete, why: no connection, a sign-in the server no longer accepts, a re-created account, records from a newer version of the app, or records that could not be read. None of these change the data on the device, and the app keeps working offline.

A sync unlocks the data key only when it has none for this sign-in. The key is kept with the auth key, so later syncs do not derive keys from the password. Signing out or into another account clears the sync state and the last sync time; a new password for the same account keeps them.

### Joining an account with data

Signing in on a device that already has lessons and progress merges them with what the account has, on that device's first sync:

- **Stamps.** Until a device has pulled once, a record it sees for the first time is stamped with when it last really changed, not with the time of signing in: a card's last review, or a discussion's latest message. Anything else is stamped 0, so the account's copy wins. Edits made after that are stamped as usual.
- **Words.** A word imported on both devices without an explicit `id` has the same generated id on both, so it is one `vocab` record, but its cards have different ids. The card reviewed more recently keeps its progress, under the account's card id, and it is pushed back if it came from this device.
- **Lessons.** Each device gives a lesson its own id. On the first sync, a local lesson with the same title (ignoring case) and folder as a pulled lesson is merged into the pulled one, keeping the words only this device has. Its Markdown keeps the account's text and adds, at the end, each block (text between blank lines) that only this device has. Lessons that only one side has stay as they are. After the first sync, lessons with the same name are kept apart.
- **Anything the app keeps of its own** instead of a pulled copy, such as a newer card or a merged lesson, is pushed back with a newer `updatedAt`, so the other devices get it too.

The same sentence imported separately on two devices arrives as two records with different ids. As soon as a sync applies it, the app merges sentences with the same text into one and points the words at it, as it does at startup. Every device keeps the same copy (the one with a recording, then the smallest id), so the copy removed on one device is the one removed on the others too. Choosing by list order instead made each device keep its own copy and delete the other's, losing the sentence everywhere (#90). A pulled sentence's text also gets each word's emphasis fitted to it, as an edit on this device would, in case the lesson record holding that emphasis is older.

### Write budget

A review writes one `card` record. The engine merges repeated changes to a record into one push, and writes a day's `activity` record once per push rather than once per review. The Worker allows 2,000 record writes per account per day, which covers several hundred reviews a day even when each one is pushed on its own.

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

- Resetting a forgotten password (confirmed by email, which starts a fresh account because the data cannot be decrypted without the old password), and an authenticator-app second factor.
- Limiting failed sign-ins per address, see above.
