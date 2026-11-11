# Previewing lessons with VitePress

[VitePress](https://vitepress.dev) can be used as an editing tool for lessons: its dev server shows each lesson as a page while you write it on a computer. The app does not need it and nothing has to be published; see [Editing lessons outside the app](lesson-format.md#editing-lessons-outside-the-app) for how the two fit together.

Out of the box, VitePress does not know the tags the app's reader renders. The theme in [`vitepress-theme/`](vitepress-theme) adds them to the preview, each made to show what the app shows:

| In a lesson | In the app, and in the preview with this theme |
| --- | --- |
| `<AudioButton src="..." />` | A button that plays the file. |
| `<TTS>안녕하세요</TTS>` | The text, then a button that speaks it. Markdown inside is rendered (`<TTS>**안녕**하세요</TTS>`) and left out of what is spoken. |
| `<YouTube id="..." />` | A player. Also takes `list` for a playlist, and `src` with a video id or any YouTube link. Quotes can be left out: `<YouTube id=wMRfpE9JdUo />`. |
| `<details>` with a `<summary>` | A block that is closed until its summary is tapped, or open from the start with `<details open>`. Plain HTML, so VitePress shows it without the theme. |
| `<span class="spoiler">...</span>` | Blurred until hovered or tapped. Other classes can be there too (`class="md spoiler"`). |
| `<VocabQuiz />`, `<Nothing />` | Nothing. The app leaves out every other capitalised tag as well. |

## Setting up

In the folder that holds your lessons (here `lessons/`):

```bash
npm add -D vitepress
mkdir -p lessons/.vitepress
cp -r path/to/lingua_srs/docs/vitepress-theme lessons/.vitepress/theme
npx vitepress dev lessons
```

VitePress loads `.vitepress/theme/index.js` by itself. If you already have a theme, copy the `components/` folder and `lesson.css` next to it, and add the `app.component(...)` lines and the CSS import from [`index.js`](vitepress-theme/index.js) to your own.

The app does not look into `.vitepress/`, `node_modules/` or `.git/`, and imports only Markdown files with `vocabulary:` frontmatter, so the folder can be imported as it is, also when `package.json` and `node_modules/` are inside it.

Words edited in the app can be written back into the files' frontmatter when the folder is imported again; VitePress does not show the frontmatter, so the preview does not change. See [Writing the app's words back to the files](lesson-format.md#writing-the-apps-words-back-to-the-files).

## Differences from the app

- **The `## Vocabulary` section** is shown in the preview and left out by the app; see [Markdown frontmatter](lesson-format.md#markdown-frontmatter). Tags used only there never reach the app.
- **Close every tag.** The app accepts `<AudioButton src="...">` and `<YouTube id="...">` left open; VitePress stops with an error on them. Write `<AudioButton src="..." />`, which both accept.
- **Audio paths.** A full URL plays in both. In the preview, a path starting with `/` is a file in the `public/` folder of the folder VitePress serves.
- **Speech** uses the voices the browser has, in Korean unless the tag has `lang="..."`. It sounds different from the app, and is silent in a browser with no voice for the language.
- **YouTube** is the regular embedded player. The app shows a thumbnail with the video's title first, and offers **Open on YouTube**.
- **`<details>`** needs a blank line after `<summary>...</summary>` and before `</details>` for VitePress to render the Markdown inside. The app renders it either way.
- **`[[...]]` links** (and the old `<!-- chunk -->` comments) are for the app only; see [Editing lessons outside the app](lesson-format.md#editing-lessons-outside-the-app).
