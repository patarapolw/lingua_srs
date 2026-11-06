# Using sync

Sync keeps lessons and study progress the same on all your devices: phone, tablet and computer. This page is for using it. How it works is in [sync.md](sync.md), and running the server is in [admin.md](admin.md).

## Before you start

Sync needs a build of the app that knows the sync server. Without one, Settings has no Sync section. If you build the app yourself:

```
cp env.example.json env.json    # then put the server address in it
flutter build apk --dart-define-from-file=env.json
```

[sync.md](sync.md#server-address) has the other build commands and editor configurations. To run your own server, see "Running your own" in the same file.

## Create an account

1. Open **Settings**, go to **Sync**, and choose **Create a sync account**.
2. Enter your email and a password of 15 to 64 characters. **Generate passphrase** makes a random six-word one that passes the checks.
3. Choose **Create account**. An email with an 8-digit code arrives.
4. Type the code and choose **Confirm email**. Saving the password in a password manager does not confirm the account.

A code works for 30 minutes, only on the device that signed up last, and stops working after five wrong tries. If it's refused, check the newest email. Creating the account again sends a new code once 10 minutes have passed since the last one; before that, the same code is used.

Keep the password safe. Your data is encrypted with it on your devices, and nobody, the server included, can reset it or read your data without it. If you forget it while no device is signed in, the data on the server is lost. The lessons on your devices stay.

## Add another device

On a device that is already signed in, open **Settings → Sync → Pair another device**. Then, on the new device, either:

- **Phone or tablet:** scan the QR code with the camera app, and choose **Pair** when the app asks.
- **Computer:** on the signed-in device, choose **Copy one-time link** and send it to the computer (for example with a password manager or a note to yourself). On the computer, copy it, open **Settings → Sync** and choose **Use copied link**.

The link works once and for 10 minutes. Anyone who gets it can sign in to your account, so only use it on your own devices. You can also sign in with your email and password (**Sign in**).

If the new device already has lessons, they are merged with the account's on its first sync:

- A lesson with the same title in the same folder becomes one lesson, keeping the words and notes from both.
- For a word you studied on both devices, the progress from the more recent review is kept.
- Everything else is added.

A sentence imported separately on both devices becomes one sentence, with the words from both pointing at it.

## Day to day

While you are signed in, the app syncs by itself:

- when it starts;
- when you come back to it;
- about 20 seconds after you stop making changes, so a study session syncs when you pause.

**Settings → Sync** shows when this device last synced. **Sync now** syncs at once. The app works the same offline, and catches up the next time it can reach the server.

If you change the same thing on two devices before they sync, the later change wins, with two exceptions: AI discussions keep the messages from both devices, and an edited sentence is kept even if another device deleted it.

## What syncs

Lessons and their Markdown, words and progress, the Sentence Pool, merge history, AI discussions, the order of your lessons, and the review limits, autoplay and pronunciation settings. The activity calendar and the daily review limits count reviews from all your devices.

These stay on each device: your DeepSeek key, which folders are open, downloaded audio and images, and the sync sign-in itself.

## When Settings shows a problem

A problem never changes the lessons on the device.

- **Could not reach the sync server.** No connection, or the server is down. It syncs again on its own later.
- **The server no longer accepts this sign-in.** The password was changed on another device, or the account was deleted. Choose **Sign out**, then sign in with the new password, or create a new account.
- **This account was deleted and created again.** Someone deleted the account and made a new one with the same email and password. Sync stops so the two are not mixed. Sign out and sign in again to use the new account.
- **Items were changed by a newer version of the app.** Update the app on this device; those items are left alone until then.
- **Items from the server could not be read.** They are skipped and the rest syncs. If it keeps happening, report it in the [issues](https://github.com/patarapolw/lingua_srs/issues).

**Check sign-in** asks the server whether this device's sign-in still works, without syncing.

## Change the password

On a signed-in device, open **Settings → Sync → Change password**, then **Save new password**. Nothing is encrypted again, so it is quick. Your other devices report that the server no longer accepts their sign-in until you sign them in again with the new password.

## Sign out or delete the account

- **Sign out** removes the sign-in from this device. Its lessons and progress stay.
- **Delete account** removes the account and everything stored on the server, for all devices. The lessons on each device stay. Other devices report that the server no longer accepts their sign-in.
