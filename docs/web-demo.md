# Web demo

The web demo is LinguaSRS in a browser, to try the flashcards and lesson management without installing anything. It is served at <https://patarapolw.github.io/lingua_srs/demo/>.

## What it has

- A first visit starts with sample lessons (`assets/demo/`): a Korean unit of two lessons and a Spanish one. Deleting them does not bring them back.
- Everything else of the apps' lessons and study: the reader and the lesson editor, import of files and ZIP archives, the Vocab and Sentence Pools, study activity, backup and restore.

## What is different

- **No AI features.** The Discussions tab, Ask AI and the AI suggestion buttons are hidden, and Settings has no AI section.
- **No sync and no sign-in.** The demo has no account and no server of its own, so it needs no Worker and no API guarding, and lessons and progress are never sent anywhere. Settings says so in place of its Sync section.
- **Data stays in the browser**, in its local storage for the site: lesson Markdown too, which the apps keep as files. Clearing the site's data deletes it. Use *Back up* to keep a copy; the apps can restore it.
- **Text-to-speech uses the browser's voices** (Web Speech, through flutter_tts), not Google Translate's online voice. Which languages can be spoken depends on the browser and the system.
- **The reader and editor are iframes.** The apps show them in a WebView; on the web, webview_all draws the same page into an iframe, with the same script and messages. YouTube videos are meant to play in that iframe; this has not been tried yet.
- **Images in notes** are shown by the browser in an `<img>` element when their site sends no CORS headers, which most image sites do not. The app cannot read such an image itself, so it is not cached; the browser's own cache keeps it.
- **Importing a folder** is not available; files and ZIP archives are.

The [privacy policy](privacy-policy.md#web-demo) says what the demo sends where.

## Where its data lives

The browser keeps the demo's data per *origin*, the scheme and host of its address, not per path. Every project site on `https://patarapolw.github.io/` shares that origin, so their pages can read and clear the demo's storage, and another Flutter web app there would use the same preference keys (`flutter.` + the key). An address of its own (a custom domain for this repository's Pages site, or another host) keeps it apart.

## Building and running it

```bash
flutter run -d chrome
flutter build web --release --no-web-resources-cdn --base-href /lingua_srs/demo/
```

`--no-web-resources-cdn` bundles CanvasKit instead of loading it from Google's CDN. A first visit downloads about 11 MB, 3.7 MB compressed: mostly CanvasKit and the compiled app. `lib/services/web_demo.dart` decides what is left out, from `kIsWeb`; tests turn it on with `WebDemo.debugEnabled`.

## Testing it

- `test/web_demo_test.dart` runs with the other tests, on the VM, with `WebDemo.debugEnabled` on.
- `flutter test --platform chrome test/web_smoke_test.dart` runs in Chrome, where `kIsWeb` is true. It opens the pages that once threw on the web. Plain `flutter test` skips it. Browser tests serve no assets, so it leaves out the sample lessons.
- CI's `web` job runs the smoke test and builds the demo on every pull request.

## Deploying it

`.github/workflows/pages.yml` builds the demo on pushes to `main` that change the app and publishes it to GitHub Pages under `demo/`. The docs site (#273) is meant to share the Pages site: build it in the same workflow into the root of `_site/`, next to `demo/`. Until then the root page only links to the demo. A repository's Pages site has one source, so the docs cannot use *Deploy from a branch* next to this workflow: VitePress builds here as it is, and Jekyll would be built here with `actions/jekyll-build-pages`.

Pages must be turned on once, in the repository's *Settings → Pages*, with *GitHub Actions* as the source.
