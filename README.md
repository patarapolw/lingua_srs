# LinguaSRS - Adaptive Language Learning SRS App

A Flutter application targeting **Desktop (Windows, macOS, Linux)** and **Mobile (Android, iOS)** for language learning with an Anki/SM-2 Spaced Repetition System (SRS).

---

## 🌟 Key Features

1. **YAML/Markdown Lesson Architecture**:
   - Create lessons from the **Import Lessons** screen (**Add Lessons** in the section header) with a lesson-name field and a Markdown editor. Both start empty; the editor shows a placeholder example of Markdown with YAML frontmatter and an optional Markdown body.
   - Use `::` in the lesson name to separate hierarchy levels. For example, `Unit 2::Lesson 26` groups the lesson under `Unit 2`; `Topic::Subtopic::Lesson A` creates a deeper hierarchy.
   - Import Markdown/YAML files or ZIP archives with one picker, or drag `.md`, `.yaml`/`.yml`, and `.zip` files onto the desktop import screen. Markdown containing only YAML frontmatter imports the same as equivalent plain YAML. Import folder(s) with a separate action. Multiple folders can be selected together on macOS; other platforms select one folder at a time. Nested folder and archive paths preserve lesson hierarchy.
   - Importing ZIP archives provides a batch-import option on Android, where directory import is restricted. Choose which Markdown lessons to import (all unchecked initially, with **Check all** and **Uncheck all** controls).
   - YAML and Markdown frontmatter are parsed in a background isolate with parse errors and an import preview. Folder import parsing also runs off the UI isolate.
   - Unit and nested folder groups in the library are expanded by default; expansion states and sibling order are saved across view changes and app restarts. Drag lessons and folders to reorder them, or use their menus to move them between folders. `::`-separated lesson paths create nested folders. Vocabulary frontmatter uses `vocabulary:` as the root, with part-of-speech keys directly beneath it and vocabulary entries listed under each key. Re-importing updates matching lessons and vocabulary in place while retaining SRS progress and entries not present in the import.
   - Imported vocabulary with the same target form and meaning shares SRS progress across part-of-speech groups. Different meanings receive separate generated IDs; an optional `id` on a vocabulary entry can explicitly control sharing.
   - Importing Markdown lessons keeps the document body for reading from the lesson list; it can be edited and saved at any time. The reader renders the whole lesson as a single document in a WebView, and **View Vocabulary** remains a separate view.

2. **Language Support**:
   - Currently only Korean to English is supported: use `ko:` for the target text and `en:` for the translation in vocabulary entries and examples.
   - Other language pairs are not supported yet.

3. **Intelligent Flashcard Visibility Rules**:
   - **Target ➔ Native (KO ➔ EN)**: Hidden by default for verbs and adjectives; enabled by default for other parts of speech (e.g., nouns).
   - **Native ➔ Target (EN ➔ KO)**: Enabled by default for verbs and adjectives; hidden by default for other cards.
   - **Individual Overrides**: Both directions can be freely toggled on or off per vocabulary item.
   - **Reset Progress**: Reset SRS progress for an entire lesson or an individual vocabulary item without changing card visibility.
   - Delete a part-of-speech group and its vocabulary, or delete an individual vocabulary entry. Deleting an entry resets SRS progress for any other entries sharing its ID.
   - Detects enabled cards with the same front prompt (without comparing their example sentences) and lets you add a disambiguation cue displayed on the card front.
   - Each card direction has editable Markdown notes displayed on its back.

4. **Front-of-Card Random Sentence with Cloze Deletion**:
   - Each card dynamically selects a **random example sentence** from the vocabulary's pool to display on the front.
   - For **KO ➔ EN** cards: Displays the target word and the Korean example sentence.
   - For **EN ➔ KO** cards: Displays the English translation prompt and the random sentence with **Cloze Deletion** (e.g. `저는 (___)를 위해 문을 열었어요`), handling bold tags and Korean verb/adjective stems.
   - The user can flip back and forth between front and back anytime (via `Space`, `Enter`, `F`, or tapping the card).

5. **Sentence Pooling**:
   - Sentences from all lessons are indexed into a central **Sentence Pool**.
   - Browse, search, edit notes on, and link any sentence from the pool to any vocabulary item.
   - The sentence picker opens with the selected vocabulary as its search query. Korean-aware local tokenization handles Hangul subwords, common particles, and frequent verb/adjective endings without downloading a large model.
   - Create new sentences directly in the pool or while editing a vocabulary item.

6. **Instant Audio Streaming with Offline Caching**:
   - **Stream-on-First-Play**: Audio starts streaming immediately on the very first play with zero wait time.
   - **Background Caching**: Simultaneously downloads and stores the `.mp3` bytes in the app's sandbox cache directory (`audio_cache/`).
   - On Windows, the cache parent directory uses the app's company and product metadata (`%LOCALAPPDATA%\cc.polv\lingua.srs\audio_cache`).
   - **Instant Offline Playback**: Subsequent plays of that vocabulary or sentence play directly from the local disk file with **zero network latency** and 100% offline availability.
   - **Pre-buffering**: Automatically pre-buffers upcoming cards in the background so cards play instantaneously without delays.

7. **Text-to-Speech**:
   - **Android** uses an installed offline system TTS voice. Install the desired language voice in Android text-to-speech settings; generated TTS is not sent to an online service or prefetched.
   - **Windows and other platforms** use online streamed TTS with local caching. Windows does not fall back to SAPI.

8. **Keyboard Navigation & Anki-Style Hotkeys**:
   - `Space`: Flip between Front ↔ Back.
   - `Enter`: On Front: Reveals answer. On Back: Submits **Good** (Rating 3)!
   - `Backspace`: Submits **Again** (Rating 1).
   - `1`, `2`, `3`, `4`: Again, Hard, Good, Easy.
   - `←` (Left Arrow) / `→` (Right Arrow): Navigate Back / Forward through answered cards (cannot browse forward beyond unanswered cards).
   - `Z` / `Ctrl+Z`: **Undo** the last card rating and restore its exact previous SRS state.
   - `R` / `S`: Replay Vocab / Sentence audio.
   - `E`: Edit card on the go.

9. **Adaptive Desktop & Mobile UI**:
   - **Desktop**: Navigation Rail sidebar, wide-screen flashcard canvas, complete hotkey bar, undo & navigation controls.
   - **Mobile**: Responsive bottom navigation, touch-friendly card taps, swipeable sheet editors.

10. **Recent Mistakes & Adaptive Queueing**:
   - **Top-Level "Recent Mistakes" Review**: Directly review active mistakes across all lessons (or per lesson) from the Daily Review Queue card, which shows a **Recent Mistakes** button with a live count only while mistakes exist.
   - **Interleaved Re-queuing**: Cards rated *Again* are automatically re-inserted a few cards ahead in the active session for delayed retrieval practice.
   - **Intelligent Session Completion**: Looping continues as long as multiple unmastered cards remain, and concludes when at most 1 *Again*'d card is left to avoid immediate zero-delay 1-card echo loops.
   - **Color-Coded Review Progress Bar**: Displays live Wrong (Red) and Right (Green) breakdown indicators directly on the top progress bar and AppBar during study sessions.
   - **24-Hour Review Window Limit**: Caps daily review volume to a rolling 24-hour limit (default: 100 cards), customizable or set to unlimited in **Settings** (gear icon). The dashboard shows cards due today (or, when none are due, how many are due tomorrow), plus the number of reviews in the last 24 hours once it is above zero.
   - **Sub-24h Repetition for Difficult Cards**: Cards marked *Again* are scheduled to repeat after a sensible 1-hour minimum delay (rather than waiting an entire day), while early *Hard* reviews repeat in 12 hours.
   - **POS-Category Shuffling**: Cards within each lesson are shuffled and interleaved across parts of speech (nouns, verbs, adjectives, etc.) rather than displaying oldest-inserted cards first, while continuing to prioritize oldest-inserted lessons first.
11. **AI-Assisted Quiz Discussions**:
   - Configure a DeepSeek API key in **Settings** (gear icon), then ask questions about the current vocabulary and example sentence during a quiz. Answers stream into the chat and render as Markdown.
   - Start with suggested questions about etymology/Hanja, key sentence vocabulary, everyday usage, and examples; get suggested follow-ups during the discussion.
   - Press Enter to send a chat message and Shift+Enter or Ctrl+Enter to add a new line.
   - Discussions are saved locally per vocabulary and sentence, restored when revisiting that card, and can be deleted from the discussion view.
   - The **Recent Discussions** tab lists every saved discussion, most recently active first, with the vocabulary, its example sentence, and the latest question. Tap one to reopen it. Discussions saved before timestamps were added are listed last.

---

## 🚀 Running the App

### Run on Desktop (Windows)
```bash
cd lingua_srs
flutter run -d windows
```

### Run on Mobile (Android / iOS)
```bash
flutter run -d <android-device-id-or-emulator>
```

### Run Unit Tests
```bash
flutter test
```

---

## 📂 Project Structure

```
lingua_srs/
├── lib/
│   ├── main.dart                      # App entry point, MultiProvider, adaptive theming
│   ├── models/
│   │   ├── lesson.dart                # Lesson model with language pair and stats
│   │   ├── vocab_item.dart            # Vocab model with POS, notes, toggles
│   │   ├── sentence.dart              # Sentence model with cloze deletion generator
│   │   ├── srs_card.dart              # SRS state (SM-2 intervals, reps, due date)
│   │   └── ai_discussion_message.dart # Saved AI discussion messages
│   ├── providers/
│   │   └── app_provider.dart          # State management (lessons, queues, review handling)
│   ├── services/
│   │   ├── srs_service.dart           # SM-2 algorithm implementation
│   │   ├── yaml_parser_service.dart   # Markdown/YAML lesson & sentence parser
│   │   ├── audio_service.dart         # Audio playback, TTS and offline caching
│   │   ├── deepseek_service.dart      # DeepSeek chat client for quiz discussions
│   │   ├── korean_text_search.dart    # Korean-aware sentence search tokenizer
│   │   └── storage_service.dart       # Local persistence and debug seed data
│   ├── views/
│   │   ├── study_view.dart            # Flashcard study view with cloze & shortcuts
│   │   ├── lesson_list_view.dart      # Lessons dashboard & due queue counter
│   │   ├── lesson_reader_view.dart    # Lesson Markdown reader & editor
│   │   ├── lesson_detail_view.dart    # Vocab list, POS filters, direction toggles
│   │   ├── sentence_pool_view.dart    # Global & lesson sentence pool browser
│   │   ├── yaml_import_view.dart      # File/folder import, editor, validator & preview
│   │   ├── vocab_edit_dialog.dart     # On-the-go editor for any field
│   │   ├── ai_discussion_dialog.dart  # AI-assisted quiz discussion chat
│   │   ├── recent_ai_discussions_view.dart # Recent Discussions tab
│   │   └── deepseek_settings_dialog.dart # DeepSeek API key settings
│   └── widgets/
│       ├── adaptive_scaffold.dart     # Responsive layout (Rail vs BottomNav)
│       ├── audio_button.dart          # Audio play/stop indicator
│       ├── lesson_hierarchy_view.dart # Lesson folder tree with reordering
│       ├── lesson_html_view.dart      # Lesson Markdown reader (WebView document)
│       ├── markdown_content.dart      # Markdown renderer for notes and chat
│       └── youtube_embed.dart         # YouTube embed for lesson Markdown
└── test/                              # Parser, SRS, storage, import and widget tests
```

---

## 📝 Creating a Lesson from Markdown with YAML frontmatter

Open **Add Lessons** and enter a lesson name in the single-line **Lesson name** field, for example:

```text
Unit 2::Lesson 26
```

The first part becomes the parent unit; remaining parts form the lesson title and any deeper hierarchy. A single name such as `Greetings` creates a top-level lesson. Then enter the vocabulary in the multiline **YAML** field. The field starts empty; its neutral placeholder is an example only and is not imported.

Use `vocabulary:` as the root, with part-of-speech keys (such as `nouns` and `verbs`) directly beneath it. Each key contains a list of vocabulary entries; do not insert another grouping key between a part-of-speech key and its entries. Example:

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
```

Each entry should include a target-language field (such as `ko`) and a translation field (such as `en`). `audio`, `notes`, `disambiguation`, and `examples` are optional. Write vocabulary and sentence notes in Markdown; for example, use `**bold**` or `*italic*` formatting. Notes on individual examples are imported as sentence notes and shown on the review-card back; they can also be edited from the Sentence Pool. Example sentence emphasis uses Markdown `**bold**`; the app uses it for cloze cards. Cards with the same front prompt are flagged even when their example sentences differ; use `disambiguation` to show an extra cue on the card front. Per-card back notes are edited in the vocabulary editor. Add an optional `id` when entries should explicitly share SRS progress or need distinct identities.

The import button remains disabled until Markdown with YAML frontmatter containing `vocabulary:` can be previewed. The vocabulary map may be empty, and the Markdown body is optional. Fix any displayed parse errors, review the lesson and vocabulary preview, then import. Use **Pick File** to load a YAML/YML/TXT/Markdown file, or **Pick Folder** to scan Markdown files recursively. Folder results start unchecked; select individual lessons or choose **Check all**. Only selected lessons are imported. Folder imports use only files with a `vocabulary:` key in their YAML frontmatter; ordinary Markdown body text is retained for lesson reading but is not imported as vocabulary. Re-importing updates matching lessons and vocabulary while preserving SRS progress and keeping unmatched vocabulary.

### Markdown frontmatter format

Markdown imports must have YAML frontmatter containing a `vocabulary:` key. It can be empty and the Markdown body can be omitted. The first Markdown heading supplies the lesson title unless a lesson name is supplied separately:

```markdown
---
vocabulary:
---

# Lesson 1: Example title

Lesson notes go here.
```

Imported lesson Markdown can be edited from its reader view. The reader renders `<AudioButton src="...">` and `<TTS>...</TTS>` controls, and `<YouTube id="...">` embeds (also `list` or `src` attributes). Spoiler spans (`<span class="spoiler">...</span>`) are blurred until hovered on desktop or tapped on touch devices; tapping toggles their visibility.

Under `vocabulary:`, use part-of-speech keys only, with entries directly in each key's list. Entries with the same explicit vocabulary `id` share SRS progress, including across part-of-speech groups. Use different IDs to force separate progress identities when needed. Without an explicit ID, the app shares progress for the same target form and meaning, while different meanings receive separate generated IDs.

## TODO

### Features

- Export lessons/units as ZIP.
- Sync between mobile and desktop, and between devices. Quick connect via QR code. I am probably using Cloudflare D1 worker for this.

### Bugs

- Dragging reorders items within their current parent still doesn't work; use the item menus to move lessons or folders to another parent.

## Thoughts

- Dragging feature might not be important. Consider removing.
