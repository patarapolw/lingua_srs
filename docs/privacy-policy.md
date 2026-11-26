# LinguaSRS privacy policy

Effective date: 18 November 2026

This policy explains what the LinguaSRS app and its optional sync server do with your data. It covers the app on every platform it is released for (Android through Google Play, and the Windows and Linux builds on GitHub Releases), the [web demo](#web-demo) and the hosted sync server.

In short: your lessons and progress stay on your device. Nothing leaves it unless you use a feature that needs the internet, such as sync, AI chats, online voices or lessons that load media from the web. The app has no ads, no analytics and no crash reporting. If you use sync, the server stores your email address and your data in a form only your devices can decrypt.

## Who is responsible

LinguaSRS is run by patarapolw, who can be reached at [polv@polv.cc](mailto:polv@polv.cc).

Contact this address with questions about this policy or to ask for your data to be deleted.

## Data that stays on your device

The app keeps these on your device only:

- **Lessons and study data**: lessons and their Markdown, words, sentences, notes, study progress and review history, merge history, the questions you typed in AI chats, and your settings.
- **AI chats**: the conversations you have with the AI, saved so you can come back to them.
- **Audio and image caches**: copies of audio and images downloaded for your lessons, so they play and show offline.
- **Your DeepSeek API key, sync sign-in and the sync encryption keys**: kept in the device's secure storage (the system keychain or its equivalent).

They stay until you delete them in the app, clear the app's data, or uninstall it. On Windows and Linux, uninstalling or deleting the app may leave its data folder behind; delete that folder to remove everything.

### Backups you make

*Settings → Backup and restore* saves a backup file wherever you choose. It contains your lessons, progress, AI chats and settings. It does not contain the DeepSeek API key, the sync sign-in or the caches. The file is not encrypted, so keep it somewhere safe.

### Android device backup

If backup is turned on in your Android settings, Android copies your lessons, progress, AI chats and settings to your Google account backup, and to a new phone when you transfer your data to it. That backup is handled by Google under your Google account, not by us. Your DeepSeek key, sync sign-in and sync keys are never included: they stay on the device. The audio and image caches are not included either.

To move to a new phone without Android's backup, or if it did not bring your lessons (Google limits each app's backup to 25 MB, so a large collection may be left out), save a backup file on the old phone and restore it on the new one, or sign in to sync on the new phone. However your data arrives, enter the DeepSeek key again on the new phone, and sign in to sync again if you use it.

## What we collect

We only receive data if you use **sync**, which is optional. Without a sync account, we receive nothing from the app.

### Sync account

When you create a sync account, the server stores:

- **Your email address.** It identifies your account and is used to send you a confirmation code. We do not use it for marketing or send you other email.
- **Values derived from your password, not the password itself.** Your password never leaves your device. The server stores a hash of a key derived from it, so nobody, the operator included, can read or reset your password.
- **Your encrypted data key**, locked with your password (and, if you made one, a second copy locked with your recovery code). Only your devices can unlock it.
- **The account's dates**: when it was created and confirmed, and when the current recovery code was made.

### Your synced data

While you are signed in, the app syncs your lessons, words, sentences, progress, study activity, AI chats, typed questions, lesson order and some settings. Everything is encrypted on your device before it is sent (end-to-end encryption), with a key that never leaves your devices. The server stores it, but cannot read it.

What the server can see:

- how many items your account has, and how large each one is;
- the type of each item (for example "lesson" or "card"), but not what is in it;
- when each item was last changed, by your device's clock, and whether it was deleted;
- the order in which changes arrived.

From these, the server can tell roughly when and how much you use the app. It cannot see the words you study, your lessons, your answers or your chats. Item names are scrambled with your key, so they do not reveal content either.

When you delete something that has synced, the server keeps a small marker that it was deleted (its type, scrambled name and date, with the content removed), so your other devices delete it too.

### Other sync data

- **Usage counters**: the server counts how many items each account writes per day, to keep the free service within its limits. Only the current day's count is kept. It also counts confirmation emails sent per day across all accounts, with no personal data.
- **Confirmation codes**: stored as a hash and valid for 30 minutes.
- **Pairing links**: when you pair another device, the server keeps the encrypted pairing data for up to 10 minutes or until it is used, whichever comes first.
- **Recovery code**: the server keeps a hash of a key derived from your recovery code and a copy of your data key locked by it. It never sees the code itself.
- **Unconfirmed signups**: if you start creating an account and never enter the confirmation code, the signup is deleted after 7 days.

### IP addresses and server logs

The sync server runs on Cloudflare. Like any web host, Cloudflare receives your IP address and basic request details whenever your device contacts the server, and uses them to deliver the service and protect it from abuse, for example by limiting how many requests one address can make. The sync server itself does not store IP addresses. Cloudflare may keep logs under its own practices and the operator's account settings.

## Third parties

Some features send data directly from your device to another company. Each one has its own privacy policy.

### Cloudflare (sync hosting)

Hosts the sync server and its database. Receives your IP address and stores the sync data described above. The database service keeps a short history for restoring it after a mistake, so deleted data can stay in that history for a limited time before it expires. [Cloudflare privacy policy](https://www.cloudflare.com/privacypolicy/)

### Resend (confirmation emails)

Sends the email with your confirmation code. Resend receives your email address and the email's content (the code). [Resend privacy policy](https://resend.com/legal/privacy-policy)

### Have I Been Pwned (password check)

When you create a sync account or choose a new password, the app checks it against a list of passwords exposed in data breaches. Only the first 5 characters of a hash of the password are sent, which is not enough to identify the password. Your email is not sent. [Have I Been Pwned privacy policy](https://haveibeenpwned.com/Privacy)

### DeepSeek (AI features, optional)

The AI features only work after you enter your own DeepSeek API key, and they can be switched off in Settings. When you use them, your device sends the request straight to DeepSeek with your key. We never see it. Depending on the feature, the request contains:

- **AI chat about a card**: the word, its meanings and notes, the example sentence, your questions, the earlier messages in that chat, and your custom AI instructions.
- **AI chat about a lesson**: the lesson's text and vocabulary, your questions, earlier messages and custom AI instructions.
- **Suggested questions, hints and duplicate suggestions**: the words and meanings involved (for duplicates across your whole collection, a list of your words with their meanings and parts of speech).

DeepSeek's use of this data is governed by its own terms and your agreement with it. [DeepSeek privacy policy](https://cdn.deepseek.com/policies/en-US/deepseek-privacy-policy.html)

### Text-to-speech

- **Android**: words and sentences are spoken by your phone's text-to-speech engine. With an installed offline voice, nothing leaves the device. If only a network voice is available, the engine (for example Google's) sends the text to its provider. That is handled by the engine you chose in your Android settings.
- **Windows, Linux and other platforms**, except the web demo: the app gets speech from Google Translate's online text-to-speech service. It sends the text being spoken (the word or sentence, with brackets and formatting removed) and its language. During a review it also fetches the speech for the next few cards in advance. The audio is then cached on your device. [Google privacy policy](https://policies.google.com/privacy)
- **Web demo**: your browser's voices; see [Web demo](#web-demo).

### Media in lessons

Lessons can contain links to audio, images and YouTube videos. When the app plays or shows them, your device downloads them from the website they are on, which receives your IP address and the request, as with any web page. For YouTube videos, the app uses the privacy-enhanced player (youtube-nocookie.com), loads thumbnails from YouTube, and asks YouTube for the video title. Links you tap in a lesson open in your browser. [YouTube is covered by Google's privacy policy](https://policies.google.com/privacy)

Which websites are contacted depends on the lessons you import or write.

## Web demo

The web demo at <https://patarapolw.github.io/lingua_srs/demo/> is the app in a browser, without AI features and without sync. It has no account and no server of its own, and sends your lessons and progress nowhere.

- **Your data stays in the browser.** Lessons, progress and settings are kept in the browser's storage for the demo's site, on your device. Clearing the site's data in the browser deletes them. *Back up* saves a file where the browser saves downloads.
- **Hosting.** GitHub Pages serves the demo's files. Like any web host, GitHub receives your IP address and request details when your browser loads them. [GitHub privacy statement](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement)
- **Text-to-speech** uses your browser's voices (the Web Speech API), not Google Translate. Some browsers offer online voices that send the text to their provider, such as Google's voices in Chrome. That is handled by your browser.
- **Fonts.** To show characters such as Korean, Chinese or Japanese, the demo downloads fonts from Google Fonts (fonts.gstatic.com), which receives your IP address. [Google privacy policy](https://policies.google.com/privacy)
- **Media in lessons** is loaded as described under [Media in lessons](#media-in-lessons).

## No ads, analytics or tracking

The app contains no advertising, no analytics and no crash reporting. It does not track you across apps or websites, and it does not sell or share your data for advertising.

## How long data is kept

- **On your device**: until you delete it, clear the app's data or uninstall the app.
- **Sync account and synced data**: until you delete the account, or the operator deletes it at your request. Accounts are not deleted for inactivity.
- **Unconfirmed signups**: 7 days.
- **Confirmation codes**: 30 minutes. **Pairing links**: 10 minutes, or until used.
- **Usage counters**: the current day.
- **Copies kept by others**: Cloudflare's database history and any database backup the operator makes expire or are deleted on their own schedule. Resend and Cloudflare keep their own logs under their policies.

## Delete your account and data

### In the app

1. Open **Settings → Sync**.
2. Choose **Delete account** and confirm.

This permanently deletes, from the server, your account, your email address, all your synced data, your recovery code and any pending pairing links. It cannot be undone. Your lessons and progress on each device are not touched; delete them there if you want (see below).

If you started a signup but did not confirm it, choose **Delete unconfirmed account** on the confirmation screen, or wait: it is deleted after 7 days.

### Without the app

If you no longer have the app or cannot sign in, email [polv@polv.cc](mailto:polv@polv.cc) from the email address of the account and ask for it to be deleted. The operator deletes the same data as **Delete account** does. The operator cannot read your synced data, so a deleted account's data cannot be recovered or sent to you.

### Data on your device

- Delete single AI chats in the app, or turn off AI features in Settings.
- Remove the DeepSeek key next to the key field in Settings.
- **Sign out** in **Settings → Sync** removes the sync sign-in from that device.
- To remove everything, clear the app's data or uninstall the app (on Windows and Linux, also delete the app's data folder).
- In the web demo, clear the site's data in your browser.

## Security

- Synced data is end-to-end encrypted with AES-256-GCM. The keys are made on your devices, and the key that unlocks your data never leaves them unencrypted. The server stores only encrypted data.
- Your password is never sent. Your devices derive keys from it, and the server keeps only a hash of one of them.
- Connections to the sync server use HTTPS.
- On the device, the DeepSeek key, sync sign-in and keys are kept in the system's secure storage.
- If you forget your password and have no recovery code, nobody can decrypt your synced data, the operator included.

No system is perfectly secure. Keep your password and recovery code private, and only use pairing links with your own devices.

## Children

LinguaSRS is not directed at children, and we do not knowingly collect data from children. If you believe a child has created a sync account, contact us and we will delete it.

## Changes to this policy

If this policy changes, the new version is published at the same address with a new effective date at the top.

## Contact

Email [polv@polv.cc](mailto:polv@polv.cc).
