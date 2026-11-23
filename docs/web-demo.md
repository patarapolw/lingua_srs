# Web demo

The web demo is LinguaSRS in a browser, to try the flashcards and lesson management without installing anything. It is served at <https://patarapolw.github.io/lingua_srs/demo/>.

## What it has

- A first visit starts with sample lessons (`assets/demo/`): a Korean unit of two lessons and a Spanish one. Deleting them does not bring them back.
- Everything else of the apps' lessons and study: the reader and the lesson editor, import of files and ZIP archives, the Vocab and Sentence Pools, study activity, backup and restore.

## What is different

- **No AI features.** The Discussions tab, Ask AI and the AI suggestion buttons are hidden, and Settings has no AI section.
- **No sync and no sign-in.** The demo has no account and no server of its own, so it needs no Worker and no API guarding, and nothing is sent to a server. Settings says so in place of its Sync section.
- **Data stays in the browser**, in its local storage for the site: lesson Markdown too, which the apps keep as files. Clearing the site's data deletes it. Use *Back up* to keep a copy; the apps can restore it.
- **Text-to-speech uses the browser's voices** (Web Speech, through flutter_tts), not Google Translate's online voice. Which languages can be spoken depends on the browser and the system.
- **The reader and editor are iframes.** The apps show them in a WebView; on the web, webview_all draws the same page into an iframe, with the same script and messages. YouTube videos play in the iframe.
- **Importing a folder** is not available; files and ZIP archives are.

The [privacy policy](privacy-policy.md#web-demo) says what the demo sends where.

## Building and running it

```bash
flutter run -d chrome
flutter build web --release --no-web-resources-cdn --base-href /lingua_srs/demo/
```

`--no-web-resources-cdn` bundles CanvasKit instead of loading it from Google's CDN. `lib/services/web_demo.dart` decides what is left out, from `kIsWeb`; tests turn it on with `WebDemo.debugEnabled`.

## Deploying it

`.github/workflows/pages.yml` builds the demo on pushes to `main` that change the app and publishes it to GitHub Pages under `demo/`. The docs site (#273) is meant to share the Pages site: build it in the same workflow into the root of `_site/`, next to `demo/`. Until then the root page only links to the demo.

Pages must be turned on once, in the repository's *Settings → Pages*, with *GitHub Actions* as the source.
