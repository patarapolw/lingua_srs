# Previewing lessons with VitePress

[VitePress](https://vitepress.dev) can be used as an editing tool for lessons: its dev server shows each lesson as a page while you write it on a computer. The app does not need it and nothing has to be published; see [Editing lessons outside the app](lesson-format.md#editing-lessons-outside-the-app) for how the two fit together.

Out of the box, VitePress does not know the tags the app's reader renders. The theme in [`vitepress-theme/`](vitepress-theme) adds them to the preview, each made to show what the app shows:

| In a lesson | In the app, and in the preview with this theme |
| --- | --- |
| `<AudioButton src="..." />` | A button that plays the file. |
| `<TTS>안녕하세요</TTS>` | The text, then a button that speaks it. Markdown inside is rendered (`<TTS>**안녕**하세요</TTS>`) and left out of what is spoken. |
| `<YouTube id="..." />` | A player. Also takes `list` for a playlist, and `src` with a video id or any YouTube link. Quotes can be left out: `<YouTube id=wMRfpE9JdUo />`. |
| `<span class="spoiler">...</span>` | Blurred until hovered or tapped. Other classes can be there too (`class="md spoiler"`). |
| `<VocabQuiz />`, `<SentenceQuiz />` | Nothing. The app leaves out every other capitalised tag as well; the theme covers these two, so add a line to `index.js` for any other you use. |

## Setting up

In the folder that holds your lessons (here `lessons/`):

```bash
npm add -D vitepress
mkdir -p lessons/.vitepress
cp -r path/to/lingua_srs/docs/vitepress-theme lessons/.vitepress/theme
npx vitepress dev lessons
```

VitePress loads `.vitepress/theme/index.js` by itself. If you already have a theme, copy the `.vue` files and `lesson.css` next to it, and add the `app.component(...)` lines and the CSS import from [`index.js`](vitepress-theme/index.js) to your own.

The app imports only Markdown files with `vocabulary:` frontmatter, so `.vitepress/` can stay in the folder you import.

## Differences from the app

- **The `## Vocabulary` section** is shown in the preview and left out by the app; see [Markdown frontmatter](lesson-format.md#markdown-frontmatter). Tags used only there never reach the app.
- **Close every tag.** The app accepts `<AudioButton src="...">` and `<YouTube id="...">` left open; VitePress stops with an error on them. Write `<AudioButton src="..." />`, which both accept.
- **Audio paths.** A full URL plays in both. In the preview, a path starting with `/` is a file in the `public/` folder of the folder VitePress serves.
- **Speech** uses the voices the browser has, in Korean unless the tag has `lang="..."`. It sounds different from the app, and is silent in a browser with no voice for the language.
- **YouTube** is the regular embedded player on `youtube-nocookie.com`. The app shows a thumbnail first, and offers **Open on YouTube**.
- **`[[...]]` links and `<!-- chunk -->` comments** are for the app only; see [Editing lessons outside the app](lesson-format.md#editing-lessons-outside-the-app).

Some HTML that VitePress renders is not rendered by the app yet:

- **Markdown inside a spoiler** is shown as typed: `<span class="spoiler">my **brother**</span>` reveals `my **brother**`.
- **`<br>` in a table cell** ends the line, so the table is shown as plain text.
- **`<ins>`, `<mark>`, `<sup>` and other inline HTML** are shown as typed, tags included. `<del>` is the exception: it is struck through.
