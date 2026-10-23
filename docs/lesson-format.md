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
       - ko: "다른 문장입니다."
         audio: "https://example.com/sentence-audio.mp3"
         en: "This is another sentence."
  verbs:
    - ko: "만들다"
      en: "to make"
      notes:
        - "First paragraph of **Markdown** notes."
        - "Second paragraph."
  numbers:
    - ko: "3개"
      ko_text: "세 개"
      en: "three items"
```

Each entry needs a target-language field (such as `ko`) and a translation field (such as `en`). `ko_text`, `audio`, `notes`, `disambiguation`, `id` and `examples` are optional.

- **`ko_text`** (`<language>_text` for other languages) is alternate text for text-to-speech, used when there is no `audio` file, for example to spell out a number. It also works on entries in `examples`.
- **Notes** are Markdown (`**bold**`, `*italic*`), written as one string or a list of strings (one paragraph each). Notes on an example are imported as sentence notes, shown on the card back, and editable from the Sentence Pool. Per-card back notes are edited in the vocabulary editor.
- **Emphasis** in example sentences uses `**bold**`; the app uses it for cloze cards. A sentence can have several emphasized segments, and every one becomes a blank. In the app, tap an example in the vocabulary editor to change its emphasis; only the `**` markers can be changed there, because a sentence is identified by its text without emphasis, and it is shared by every word that links to it.
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

## Importing

The import button stays disabled until the input can be previewed. Fix any displayed parse errors, review the preview, then import.

- **Pick File** loads a YAML/YML/TXT/Markdown file, or a ZIP archive (the way to batch-import on Android, where directory import is restricted). On desktop you can also drag `.md`, `.yaml`/`.yml` and `.zip` files onto the import screen.
- **Pick Folder** scans Markdown files recursively. Multiple folders can be selected together on macOS; other platforms select one at a time. Nested folder and archive paths preserve lesson hierarchy.
- Folder and ZIP results start unchecked; select lessons individually or use **Check all** / **Uncheck all**.
- Only files with a `vocabulary:` key in their frontmatter are imported; other Markdown is ignored.
- Re-importing updates matching lessons and vocabulary in place, keeping SRS progress and any entries not present in the import.

### Adding vocabulary to an existing lesson

Open the lesson and choose **Add → Add from YAML**. The import screen opens with the lesson's name filled in. Write only the new entries; importing under an existing lesson's name adds them to it and leaves its other vocabulary and SRS progress untouched.

```yaml
vocabulary:
  nouns:
    - ko: "새 단어"
      en: "new word"
```

For a single word, choose **Add → Add one word** instead; it asks only for the Korean, English and part of speech. Everything else can be filled in later by editing the word.
