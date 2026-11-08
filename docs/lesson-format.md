# Lesson Format

Lessons are Markdown files with YAML frontmatter (or plain YAML). Write them in the app via **Add Lessons**, or import files, folders and ZIP archives.

## Lesson name and hierarchy

In **Add Lessons**, enter a lesson name in the single-line **Lesson name** field. Use `::` to separate hierarchy levels:

```text
Unit 2::Lesson 26
```

The first part becomes the parent unit; remaining parts form the lesson title and any deeper hierarchy (`Topic::Subtopic::Lesson A`). A single name such as `Greetings` creates a top-level lesson.

## Vocabulary YAML

Use `vocabulary:` as the root, with part-of-speech keys (such as `nouns` and `verbs`) directly beneath it. Each key contains a list of entries; do not insert another grouping key between a part-of-speech key and its entries.

```yaml
vocabulary:
  nouns:
    - ko: "예시 단어"
      en: "example word"
      audio: "https://example.com/word-audio.mp3"
      notes: "Optional **Markdown** notes"
      examples:
       - ko: "저는 **예시 단어**를 배워요."
         en: "I learn an **example word**."
         notes: "Optional *Markdown* notes for this sentence."
       - ko: "**다른** 문장입니다."
         audio: "https://example.com/sentence-audio.mp3"
         en: "This is **another** sentence."
  verbs:
    - ko: "만들다"
      en: "to make"
      notes:
        - "First paragraph of **Markdown** notes."
        - "Second paragraph."
  numbers:
    - ko: "3개"
      tts: "세 개"
      en: "three items"
```

Each entry needs a target-language field (such as `ko`) and a translation field (such as `en`). `tts`, `audio`, `notes`, `disambiguation`, `id` and `examples` are optional.

- **`tts`** is alternate text for text-to-speech, used when there is no `audio` file (or its *Use this recording* box is unticked), for example to spell out a number. It also works on entries in `examples`. The older names `ko_text` (`<language>_text`) and `target_text` are still read, and export writes `tts`.
  - **Locale prefix.** Start the `tts` text with a locale and a colon, with no space after the colon, to have it spoken by another voice than the lesson's language: `tts: "zh-TW:垃圾"` is said by a Taiwanese Mandarin voice, `tts: "ko:세 개"` by a Korean one. The locale is a 2–3 letter language with an optional script or region (`zh`, `zh-TW`, `zh-Hant`), with no text in front of it. A colon followed by whitespace is always text, and so is anything before the colon that is not a locale (`10:30`). The prefix is kept as part of the text in the editor, and is not spoken. A prefix with no text after it (`tts: "zh-TW:"`) says the word or sentence itself in that locale. A prefix whose language is unknown (`xx:`) is ignored: the rest, or the word or sentence, is spoken in the lesson's language, and the `tts` text is kept as written. The prefix only picks the voice: how the characters are read is up to that voice, so to force a reading, respell it (`tts: "樂色"` for lè sè). On Android, the editors' *Spoken in …* button picks the prefix from the languages the phone can speak.
  - **Marks that are not read out.** Text-to-speech (of the `tts` text, or of the word or sentence while it is blank) leaves out asides in brackets, with the space before them: `(…)`, `（…）`, `[…]`, `［…］` and `【…】`, so `먹다 (to eat)` is said as `먹다`. A markdown link keeps its text. A `/`, `／`, `|` or `｜` between alternatives, and an arrow (`→`, `←`, `↔`, `⇒`), is said as a short pause: `은/는` as `은, 는`, not "은 slash 는". A slash between digits (`1/2`, `3/14`) is kept, for the voice to read as a number or date. Bold, cloze blanks and the marks `#`, `*`, `_`, `~` and `` ` `` are never spoken. To have a mark read out, or an aside said, write it out in `tts`.
- **Notes** are Markdown (`**bold**`, `*italic*`), written as one string or a list of strings (one paragraph each). Notes on an example are imported as sentence notes, shown on the card back, and editable from the Sentence Pool. Per-card back notes are edited in the vocabulary editor. A notes field is a small *Add … note* button while it is empty, shows the rendered Markdown once it has text (with an *Edit* button), and has a *Preview* button while being edited. Online images in notes are saved on disk the first time they are shown (`image_cache/`, next to the audio cache), so they show again offline and after a restart. Every Markdown editor (notes fields and the lesson editor) converts copied HTML, such as a web page or a Google Docs selection, to Markdown when you paste. Copied text without formatting pastes as it is.
- **Emphasis** is required in the target-language sentence of every example: wrap the word being studied in `**bold**`, or the import fails. The error lists every file (a path inside a zip, or under the chosen folder) with every such sentence in it, so they can be fixed in one pass; other files still import. The app uses it for cloze cards. A sentence can have several emphasized segments, and every one becomes a blank. The translation may be emphasized too, but need not be. Sentences and their translations are shown as plain text apart from `**bold**`, so other Markdown (such as `*italic*`) appears as typed; only notes are rendered as Markdown.
- **Shared sentences.** The Sentence Pool holds each sentence once, as plain text, even when several words list it as an example. The `**` emphasis belongs to the word: two words can mark different parts of the same sentence. Edit the text from the Sentence Pool or from a word's example editor (which warns that the text changes for every word that uses the sentence, and requires `**` in the sentence); edit the emphasis from the word. When the text of a shared sentence changes, each word keeps its emphasis wherever the surrounding text is unchanged, and otherwise it is suggested again from the word.
- **`disambiguation`** shows an extra cue on the card front. Cards with the same front prompt are flagged even when their example sentences differ.
- **`id`** makes entries explicitly share SRS progress (including across part-of-speech groups) or forces separate identities. Without an `id`, entries with the same target form and meaning share progress; different meanings get separate generated IDs.

## Markdown frontmatter

Markdown imports must have YAML frontmatter containing a `vocabulary:` key. It can be empty, and the Markdown body is optional. The first heading supplies the lesson title unless a name is supplied separately:

```markdown
---
vocabulary:
---

# Lesson 1: Example title

Lesson notes go here.
```

Frontmatter-only Markdown imports the same as equivalent plain YAML. The body is kept for reading from the lesson list and can be edited and saved at any time.

The reader renders `<AudioButton src="...">` and `<TTS>...</TTS>` controls, and `<YouTube id="...">` embeds (also `list` or `src` attributes). Spoiler spans (`<span class="spoiler">...</span>`) are blurred until hovered on desktop or tapped on touch devices.

Tap a YouTube thumbnail to start its embedded player. If the video cannot play,
use **Open on YouTube** to open the video or playlist outside the player.

The reader renders the lesson natively, a chunk at a time, so long lessons stay responsive. A chunk starts at every heading, and a long section is also cut at a blank line (never inside a code block, list or table). If a lesson splits badly, add HTML comments, which render as nothing anywhere:

```markdown
Text before.

<!-- chunk -->

Text that always starts a new chunk.

<!-- chunk:start -->

Everything up to the end marker stays in one chunk, however long.

<!-- chunk:end -->
```

## Importing

The import button stays disabled until the input can be previewed. Fix any displayed parse errors, review the preview, then import.

- **Pick File** loads a YAML/YML/TXT/Markdown file, or a ZIP archive (the way to batch-import on Android, where directory import is restricted). On desktop you can also drag `.md`, `.yaml`/`.yml` and `.zip` files onto the import screen.
- **Pick Folder** scans Markdown files recursively. Multiple folders can be selected together on macOS; other platforms select one at a time. Nested folder and archive paths preserve lesson hierarchy.
- Folder and ZIP results start unchecked; select lessons individually or use **Check all** / **Uncheck all**.
- Only files with a `vocabulary:` key in their frontmatter are imported; other Markdown is ignored.
- Re-importing updates matching lessons and vocabulary in place, keeping SRS progress and any entries not present in the import.
- Folder import skips Markdown files that have not changed since you last imported them, and reports how many it skipped.

### Adding vocabulary to an existing lesson

Open the lesson and choose **Add → Add from YAML**. The **Add Vocabulary** screen opens for that lesson. Write only the new entries, as plain YAML starting with `vocabulary:`; they are added to the lesson, and its other vocabulary, its text and SRS progress are left untouched. Markdown (a `---` frontmatter block and lesson text) is refused there, since importing it would replace the lesson's text; to change the text, edit the lesson. The lesson name cannot be changed, and files and folders cannot be picked or dropped there: use **Add Lessons** for whole lessons. The same screen opens from *Edit and add to lesson* in a lesson's AI chat.

```yaml
vocabulary:
  nouns:
    - ko: "새 단어"
      en: "new word"
```

For a single word, choose **Add → Add manually** instead; it asks only for the Korean, English and part of speech. Everything else can be filled in later by editing the word.
