# Lesson Format

Lessons are Markdown files with YAML frontmatter (or plain YAML). Write them in the app via **Add Lessons**, or import files, folders and ZIP archives. To write them on a computer with a live preview, see [Editing lessons outside the app](#editing-lessons-outside-the-app).

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

Each entry needs a target-language field (such as `ko`) and a translation field (such as `en`). `tts`, `audio`, `notes`, `disambiguation`, `id` and `examples` are optional, and so are the reading and character-form fields under [Readings and character forms](#readings-and-character-forms).

- **`tts`** is alternate text for text-to-speech, used when there is no `audio` file (or its *Use this recording* box is unticked), for example to spell out a number. It also works on entries in `examples`. The older names `ko_text` (`<language>_text`) and `target_text` are still read, and export writes `tts`.
  - **Locale prefix.** Start the `tts` text with a locale and a colon, with no space after the colon, to have it spoken by another voice than the lesson's language: `tts: "zh-TW:垃圾"` is said by a Taiwanese Mandarin voice, `tts: "ko:세 개"` by a Korean one. The locale is a 2–3 letter language with an optional script or region (`zh`, `zh-TW`, `zh-Hant`), with no text in front of it. A colon followed by whitespace is always text, and so is anything before the colon that is not a locale (`10:30`). The prefix is kept as part of the text in the editor, and is not spoken. A prefix with no text after it (`tts: "zh-TW:"`) says the word or sentence itself in that locale. A prefix whose language is unknown (`xx:`) is ignored: the rest, or the word or sentence, is spoken in the lesson's language, and the `tts` text is kept as written. The prefix only picks the voice: how the characters are read is up to that voice, so to force a reading, respell it (`tts: "樂色"` for lè sè). On Android, the editors' *Spoken in …* button picks the prefix from the languages the phone can speak.
  - **Marks that are not read out.** Text-to-speech (of the `tts` text, or of the word or sentence while it is blank) leaves out asides in brackets, with the space before them: `(…)`, `（…）`, `[…]`, `［…］` and `【…】`, so `먹다 (to eat)` is said as `먹다`. A markdown link keeps its text. A `/`, `／`, `|` or `｜` between alternatives, and an arrow (`→`, `←`, `↔`, `⇒`), is said as a short pause: `은/는` as `은, 는`, not "은 slash 는". A slash between digits (`1/2`, `3/14`) is kept, for the voice to read as a number or date. Bold, cloze blanks and the marks `#`, `*`, `_`, `~` and `` ` `` are never spoken. To have a mark read out, or an aside said, write it out in `tts`.
- **Notes** are Markdown (`**bold**`, `*italic*`), written as one string or a list of strings (one paragraph each). Notes on an example are imported as sentence notes, shown on the card back, and editable from the Sentence Pool. Per-card back notes are edited in the vocabulary editor. A notes field is a small *Add … note* button while it is empty, shows the rendered Markdown once it has text (with an *Edit* button), and has a *Preview* button while being edited. Online images in notes are saved on disk the first time they are shown (`image_cache/`, next to the audio cache), so they show again offline and after a restart. Every Markdown editor (notes fields and the lesson editor) converts copied HTML, such as a web page or a Google Docs selection, to Markdown when you paste. Copied text without formatting pastes as it is.
- **Emphasis** is required in the target-language sentence of every example: wrap the word being studied in `**bold**`, or the import fails. The error lists every file (a path inside a zip, or under the chosen folder) with every such sentence in it, so they can be fixed in one pass; other files still import. The app uses it for cloze cards. A sentence can have several emphasized segments, and every one becomes a blank. The translation may be emphasized too, but need not be. Sentences and their translations are shown as plain text apart from `**bold**`, so other Markdown (such as `*italic*`) appears as typed; only notes are rendered as Markdown.
- **Shared sentences.** The Sentence Pool holds each sentence once, as plain text, even when several words list it as an example. The `**` emphasis belongs to the word: two words can mark different parts of the same sentence. Edit the text from the Sentence Pool or from a word's example editor (which warns that the text changes for every word that uses the sentence, and requires `**` in the sentence); edit the emphasis from the word. When the text of a shared sentence changes, each word keeps its emphasis wherever the surrounding text is unchanged, and otherwise it is suggested again from the word.
- **`disambiguation`** shows an extra cue on the card front. Cards with the same front prompt are flagged even when their example sentences differ.
- **`id`** makes entries explicitly share SRS progress (including across part-of-speech groups) or forces separate identities. Without an `id`, entries with the same target form and meaning share progress; different meanings get separate generated IDs. So an entry is identified by its `id`, or without one by its word and translation together; see [Importing a file again](#importing-a-file-again) for what happens when either is edited.

## Readings and character forms

A word can say how it is read and how else it is written. These fields are optional, are shown on the answer side of the word's cards (never on the front), and can be edited in the vocabulary editor. They do not get review cards of their own.

Mandarin Chinese: `pinyin` (or `reading`), `simplified` and `traditional`.

```yaml
target: zh-CN
vocabulary:
  nouns:
    - zh: "学生"
      pinyin: "xuésheng"
      simplified: "学生"
      traditional: "學生"
      en: "student"
```

Korean: `hanja`, for a Sino-Korean word.

```yaml
vocabulary:
  nouns:
    - ko: "학생"
      hanja: "學生"
      en: "student"
```

- **Importing the file again** treats these like the word and its translation: one edited in the app stays while the file's entry is as it was, and one changed in the file is taken. Writing the app's words back to a folder writes them too, under the key the entry already uses.
- **`pinyin`** and **`reading`** are the same field: how the word is read. `reading` suits any language whose writing does not show it, such as kana for a Japanese word. When an entry has both, the first one is used. Export writes `pinyin` in a Chinese lesson and `reading` in any other.
- **`simplified`** and **`traditional`** record both forms of a Chinese word, whichever one the lesson is written in. The card shows the form that differs from the word itself: a `zh: 学生` card shows *Traditional: 學生*.
- **`hanja`** is the Hanja of a Korean word, shown as *Hanja: 學生*. Leave it out for a native Korean word.
- **`target:`** names the lesson's language. Entries are keyed by the language alone (`zh:`, not `zh-TW:`), so write the region or script on `target:` (`zh-CN`, `zh-TW`, `zh-Hant`); it is kept, and picks the text-to-speech voice (Taiwanese for `zh-TW` and `zh-Hant`, mainland otherwise). Without `target:`, the language is taken from the entry key (`zh`).

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

A `## Vocabulary` section in the body is left out when the lesson is imported, from that heading up to the next `## ` heading: the words are in the frontmatter, and the app lists them under **View Vocabulary**. The section is not stored, so the reader does not show it and an export does not write it back. It is kept when it is the last `## ` section of the file, or when its heading is written any other way (`## Vocabulary list`, `### Vocabulary`).

The reader renders `<AudioButton src="...">` and `<TTS>...</TTS>` controls, and `<YouTube id="...">` embeds (also `list` or `src` attributes). Spoiler spans (`<span class="spoiler">...</span>`) are blurred until hovered on desktop or tapped on touch devices. Markdown inside a spoiler is rendered: `<span class="spoiler">my **brother**</span>`. Scripts and event attributes (`onclick="..."`), and capitalised tags the reader does not know (`<VocabQuiz />`), are left out.

The reader shows the lesson as a web page, so HTML in the Markdown is rendered by the browser engine of the device, not by the app: `<ins>`, `<u>`, `<mark>`, `<sup>`, `<sub>`, `<del>`, `<s>`, `<em>`, `<strong>`, `<br>` (also inside a table cell), `<div>`, `<ul>`, `<table>`, `<img>` and the rest work as they do on the web. Markdown works inside a block once a blank line separates it from the HTML tag, as on GitHub. Styles are the reader's own, and `<style>`, `<script>` and `<iframe>` are removed.

A `<details>` block folds part of a lesson away until its `<summary>` is tapped. Markdown works inside it, headings included; `<details open>` starts unfolded, and a block can sit inside another:

```html
<details>
<summary>Examples</summary>

- 저는 **학생**이에요
- 저는 **선생님**이에요

</details>
```

A YouTube video shows its thumbnail and title; tap it to start the embedded player. If the video cannot play,
use **Open on YouTube** to open the video or playlist outside the player.

The reader shows the whole lesson as one page, so long lessons scroll smoothly, and the text can be selected across sections. The comments `<!-- chunk -->`, `<!-- chunk:start -->` and `<!-- chunk:end -->`, which earlier versions used to cut a lesson into pieces, are no longer needed; they render as nothing, like any HTML comment.

### Links between lessons and to sections

Link to another lesson, or to a section, by its name in double brackets. The link reads as what it names, so the source stays readable as plain text:

```markdown
See [[Lesson 26]] for the vocabulary.
The past tense is in [[Unit 2::Lesson 26#Past tense]].
Review [[#Greetings]] before you start.
[[Lesson 26#Past tense|the past-tense table]]
```

- **`[[Lesson 26]]`** opens the lesson titled *Lesson 26*. When two lessons share a title, add folders in front with `::` (`[[Unit 2::Lesson 26]]`), the same way lesson names are written; otherwise the one nearest in the folder tree to the lesson with the link opens. Case does not matter.
- **`#Heading`** after a lesson name opens that lesson at the heading. On its own (`[[#Greetings]]`) it scrolls to the heading in the same lesson. Write the heading's text as it reads; case and punctuation do not matter, so `[[#Hello, World!]]` and `[[#hello-world]]` find the same heading.
- **`|label`** sets the text shown. Without it, the link shows its target, with `›` between parts: `Unit 2 › Lesson 26 › Past tense`.
- Plain Markdown links to a heading in the same lesson work too: `[greetings](#greetings)` or `[greetings](<#Greetings>)`.

A link to a lesson or heading that does not exist says so when tapped. Brackets inside code (`` `[[...]]` ``) are left as they are.

#### Links to `.md` files

A lesson folder can also be written and previewed outside the app (see [Editing lessons outside the app](#editing-lessons-outside-the-app)), and the same links work in both. Links between lesson files, the way VitePress, Obsidian, VS Code and GitHub write them, open the lesson they point to:

```markdown
[Lesson 26](../unit-2/lesson-26.md#past-tense)
[Lesson 26](../unit-2/lesson-26#past-tense)
[Unit 2](../unit-2/)
[Intro](/intro.md)
```

- **Forms:** a link may name the file (`lesson-26.md`), the page VitePress makes of it (`lesson-26.html`, or `lesson-26` with no extension), or a folder (`unit-2/`), which opens its `index.md`. Links to other files, such as `worksheet.pdf`, and links with a scheme (`https:`) are left alone.
- **Virtual path:** every lesson has one, made of folders and a file name.
  - A lesson imported from a folder or ZIP keeps the names of its file and folders as they were on disk (`/unit-2/past_tense/lesson-26.md`), while the app shows the folders renamed (*Unit 2 › Past Tense*).
  - Any other lesson uses its app folders and its title (`/Unit 2/Lesson 26.md`), with characters a file name cannot hold (`/`, `:`, `?`, …) made `_`.
  - When you move a lesson to another folder, its virtual folder follows the app folders.
- **Seeing it:** the lesson's Markdown editor (**Edit Markdown** in the reader) shows its virtual path, and its link button copies a Markdown link to the lesson to paste into another one.
- **Following a link:** it starts from the folder of the lesson it is in. `..` goes up a folder, and a leading `/` starts at the top: the folder that was picked, or the ZIP's top level, which is the same place as in the VitePress preview when you pick the folder VitePress serves. Folder and file names compare ignoring case and punctuation, so `unit-2/lesson-26` also finds a lesson in the folder *Unit 2*. If no lesson is at that path, for example when only part of a course was imported, the nearest lesson with that file name or title opens.
- **Korean names** are kept as whole syllables. macOS can store a name such as `한국어` as separate jamo, which looks the same but would not match, so the app composes it when the lesson is imported, loaded or synced.
- **Export** writes each lesson to its virtual path, so links still work after exporting and importing again.
- **Older lessons:** a lesson imported before file and folder names were kept takes them the next time you import its folder or ZIP, even if its file has not changed and is skipped. It takes them when the file is the only lesson in that app folder it matches by name; until then it uses its title and app folders. Virtual paths follow the real files: there is nothing to rename by hand.
- **Editor vs app:** `[[...]]` links are understood by the app, and by Obsidian for file names, but not by VitePress, VS Code or GitHub. In files you also preview there, use links like the ones above. Heading ids in braces (`{#past-polite}`, below) work in the app and in VitePress.

#### Heading ids and repeated headings

When a heading's text repeats, its anchor gets `-1`, `-2`, … in order, as on GitHub: under `## Present` and `## Past`, two `### Polite` headings are `#polite` and `#polite-1`. To give a heading an anchor of its own, end it with an id in braces, as in markdown-it-attrs:

```markdown
## Past

### Polite {#past-polite}
```

`{#past-polite}` is not shown, and `[[#past-polite|polite past]]` or `[polite past](#past-polite)` links to that heading (from another lesson, `[[Lesson 26#past-polite]]`). Classes and other attributes (`{#id .note lang=ko}`) are allowed and ignored. A link looks for a heading with that id or anchor first, then for one with that text, then for one with the same letters and digits, so an anchor copied from another tool (VitePress writes `1. Intro` as `#_1-intro`) finds its heading too.

## Editing lessons outside the app

Lessons are plain Markdown files, so a folder of them can be written in any editor and then imported. [VitePress](https://vitepress.dev) is used here as an editing tool: its dev server shows each lesson as a page while you write it, and updates the page when the file is saved. The app does not need it, and nothing has to be published; the app reads the same `.md` files, not the pages VitePress builds.

```bash
npx vitepress dev lessons   # preview the folder `lessons` in a browser
```

- **Write** in the folder VitePress serves, then bring the lessons into the app with **Pick Folder**, or a ZIP of the folder on Android (see [Importing](#importing)). Importing again after more edits updates the lessons in place and skips unchanged files.
- **The file is the source for the lesson text; words are edited in the app.** Importing a file again replaces the lesson's text with the file's, and leaves alone the words, translations and examples you edited in the app. The app can write those edits into the file's frontmatter, so the folder stays a full copy; see [Importing a file again](#importing-a-file-again).
- **Links** written as [links to `.md` files](#links-to-md-files) open the same lesson and heading in the preview and in the app. A link starting with `/` does too when the folder you import is the one VitePress serves.
- **Headings** take `{#id}` in both (see [Heading ids and repeated headings](#heading-ids-and-repeated-headings)).
- **Frontmatter** (`vocabulary:` and the rest) is read by the app only; VitePress does not show it.
- **A `## Vocabulary` section** is shown by VitePress and left out by the app (see [Markdown frontmatter](#markdown-frontmatter)), so it can hold a word list for the preview alone.
- **App-only syntax:** `[[...]]` links and the `<!-- chunk -->` comments (no longer needed) mean nothing to VitePress. `<AudioButton>`, `<TTS>` and `<YouTube>` are rendered by the app's reader; VitePress shows them once its theme has components with those names. [vitepress.md](vitepress.md) has a theme that adds them.
- **Edits made to the lesson text in the app** (**Edit Markdown**) stay in the app until you export, and are replaced the next time the file is imported with changes. Export writes each lesson back to its virtual path, so an exported ZIP unpacks over the original folder.

Obsidian, VS Code's Markdown preview and GitHub work for the same files, without VitePress's `{#id}` headings.

## Importing

The import button stays disabled until the input can be previewed. Fix any displayed parse errors, review the preview, then import.

- **Pick File** loads a YAML/YML/TXT/Markdown file, or a ZIP archive (the way to batch-import on Android, where directory import is restricted). On desktop you can also drag `.md`, `.yaml`/`.yml` and `.zip` files onto the import screen.
- **Pick Folder** scans Markdown files recursively. Multiple folders can be selected together on macOS; other platforms select one at a time. Nested folder and archive paths preserve lesson hierarchy.
- Folder and ZIP results start unchecked; select lessons individually or use **Check all** / **Uncheck all**.
- Only files with a `vocabulary:` key in their frontmatter are imported; other Markdown is ignored.
- A folder or ZIP is not looked into under `node_modules`, `__MACOSX`, or any folder whose name starts with a dot (`.vitepress`, `.git`); files whose names start with a dot are left out too. So the folder a VitePress or Git project lives in can be picked as it is. The folder you pick is always looked into, whatever its name.
- A file in a ZIP that is not UTF-8 text is listed as an error, and the rest of the ZIP is still read.
- Re-importing updates matching lessons and vocabulary in place, keeping SRS progress and any entries not present in the import. A lesson matches when it is at the same virtual path (see [Links to `.md` files](#links-to-md-files)): the same file in the same folder, or, for a lesson with no file, the same title. [Importing a file again](#importing-a-file-again) says what is taken from the file.
- **One name per folder.** No two lessons in a folder share a name (ignoring case). When an import brings a lesson whose name is taken in its folder by a lesson at another path, you are asked which one is primary; the other is overwritten by it:
  - **Saved lesson**: the imported file is skipped.
  - **Imported file**: the saved lesson takes the file's name, text and words; its words keep their study progress, and words not in the file stay.
  - **Keep both**: the imported lesson is named with a suffix, `Lesson 1 (2)`, and keeps that name when its file is imported again.

  Overwriting never deletes words: the dialog warns how many words of the saved lesson are not in the file, and they stay in the lesson with their study progress. Delete them from the lesson's vocabulary if you no longer want them. *Do the same for any other clash in this import* answers the rest at once. A lesson saved before file names were kept takes the file's name whichever lesson is primary, so the next import of that file updates it without asking; one whose title starts with the same `Lesson <number>` as the file's is asked about too, as such lessons used to be merged.
- Lessons that share a name or a file in a folder can still arrive by sync or from a backup, such as one file imported on two devices before they synced.
  - **Same file, nothing lost by merging:** lessons in the same folder from the same file are merged into one when the app starts or syncs, if their text is the same or one of them has none. Words only one has are kept, with their study progress, and AI chats are joined, oldest message first.
  - **Anything else:** the lesson list shows a banner: same file with different text, or the same name. **Sort out** asks which lesson of each pair is primary, and says what would be lost. Overwriting removes the other lesson, after moving any words only it has to the primary one (with their study progress) and joining its AI chat into the primary one's. **Keep both** renames the second lesson if the names match; if the two share a file, the second one lets go of it, so the next import of the file updates the first.
- Folder and ZIP import skip Markdown files that have not changed since you last imported them, and report how many they skipped. A file whose lesson is no longer saved (it was deleted, here or on another device, or moved to another folder in the app) is offered again even when it has not changed. A ZIP's files are recognised by their path inside the ZIP, so this works however the ZIP is named or wherever it is picked from (Android copies a picked file somewhere new every time).

### Importing a file again

A lesson file is where the lesson's text is written; its words are expected to be edited in the app. So importing a file again takes the text from the file, and for each word only what was changed in the file since the last import. The app remembers what the file said about each word, and compares.

- **Text:** the file's text replaces the lesson's.
- **A word edited in the app** (its word, translation, part of speech, or which examples it has) stays as edited, when its entry in the file is as it was.
- **An entry edited in the file** updates its word, when the word was not edited in the app. If both were edited, the app's edit stays.
- **Examples** are compared one by one: an example added to the entry is added to the word, one removed from the entry is removed from the word, and one marked another way (`**...**`) is marked that way. Examples you added or edited in the app stay.
- **`audio`, `notes`, `disambiguation` and `tts`** typed in the app stay; the file's value is kept as an alternate.
- **An entry removed from the file** leaves its word in the lesson, with its progress. Delete the word in the app if you no longer want it.
- **Which word an entry is:** the one with its `id`; without an `id`, the one with the same word and translation, now or when the file was last imported. So an entry still finds a word you renamed in the app.
- **Correcting an entry in the file** keeps it the same word, with its progress, when the app can tell what it used to be: the same word with a new translation, or the same translation with a typo fixed in the word (one character in three at most), and no other entry or word that could be meant. Anything else is a new word, and the old one stays: change the word and the translation at once, or replace a word with a synonym, and you get a second word. An entry with an `id` can be changed freely.
- **A lesson imported before the app kept what its file said** has nothing to compare with the first time. A word still stays as edited when its entry reads as it did, which the app can tell for entries without an `id`, also when the word shares its progress with the same word in another lesson. An entry with an `id` follows the file once more. Examples are not removed that time: the file's are added to the word's.

### Writing the app's words back to the files

After **Pick Folder**, tick **Write words from the app back to the files** to bring the folder up to date with the app. It says how many unchanged files no longer match. The files you import are written too, after they are merged, and with nothing to import the button reads **Update N Files**.

- **What is written:** words and translations edited in the app; `audio`, `notes`, `disambiguation` and `tts` typed in the app; examples added, removed or marked another way; and words added in the app, at the end of their section (a new section is made if there is none). A word the file already has an entry for, with its `id` or with its word and translation, is not added again, even when the lesson in the app holds it twice.
- **What is not touched:** the lesson text, other frontmatter keys (`title`, `outline`, …), comments, and entries that did not change.
- **Small diffs, for a folder kept in Git.** Nothing is written unless the box is ticked, and then only to files whose words differ from the app's. A changed value changes its line; an example added or removed adds or removes its own lines; a new word is added after the last entry of its section. Quotes, comments, key order and line endings elsewhere stay as they are. New entries and examples are written with their values in double quotes. Writing twice changes nothing the second time, and importing a file the app wrote changes nothing in the app.
- **What is not written, so that files do not change back and forth:** a difference in letter case or spacing only in an example sentence (sentences are shared between lessons, and two files may write one differently); `audio`, `notes`, `disambiguation` and `tts` that came from another lesson's file; and a marking removed from an example in the app.
- **Nothing is removed from a file except examples you removed from a word.** A word deleted in the app stays in the file, and is added again if that file is imported after a change. A word that came from a file and is no longer in it is not put back.
- **A file edited after the folder was scanned** is skipped. A file that cannot be updated safely is left as it is and listed: the app reads its own result back before it writes.
- **Only folders, so only on a computer.** A ZIP, and a file picked or dropped by itself, cannot be written to, and Android cannot pick a folder. Words edited on a phone reach the folder through sync: once the computer has synced, import the folder there with the box ticked. An exported ZIP is not a substitute for a folder kept in Git: export writes every file again in its own layout.

### Adding vocabulary to an existing lesson

Open the lesson and choose **Add → Add from YAML**. The **Add Vocabulary** screen opens for that lesson. Write only the new entries, as plain YAML starting with `vocabulary:`; they are added to the lesson, and its other vocabulary, its text and SRS progress are left untouched. Markdown (a `---` frontmatter block and lesson text) is refused there, since importing it would replace the lesson's text; to change the text, edit the lesson. The lesson name cannot be changed, and files and folders cannot be picked or dropped there: use **Add Lessons** for whole lessons. The same screen opens from *Edit and add to lesson* in a lesson's AI chat.

```yaml
vocabulary:
  nouns:
    - ko: "새 단어"
      en: "new word"
```

For a single word, choose **Add → Add manually** instead; it asks only for the Korean, English and part of speech. Everything else can be filled in later by editing the word.
