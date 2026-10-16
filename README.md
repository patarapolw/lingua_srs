# LinguaSRS - Adaptive Language Learning SRS App

A Flutter application targeting **Desktop (Windows, macOS, Linux)** and **Mobile (Android, iOS)** for language learning with an Anki/SM-2 Spaced Repetition System (SRS).

---

## 🌟 Key Features

1. **YAML/Markdown Lesson Architecture**:
   - Create lessons from the **Import Lessons** screen with a separate lesson-name field and YAML editor. The YAML starts empty; a neutral example is shown as hint text.
   - Use `/` in the lesson name to separate hierarchy levels. For example, `Unit 2 / Lesson 26` groups the lesson under `Unit 2`; `Topic / Subtopic / Lesson A` creates a deeper hierarchy.
   - Import a directory recursively; Markdown files are read from their `vocabulary:` frontmatter section and grouped by their parent folder (for example, `unit-2` becomes Unit 2).
   - YAML is checked as you type, with parse errors and an import preview. Import is enabled only when the YAML is valid.
   - Unit titles group lessons in the library; each lesson appears as a subsection. Vocabulary frontmatter can define alphabetically sorted, collapsible sections at any depth. Re-importing updates matching lessons and vocabulary in place while retaining SRS progress and entries not present in the import.
   - Imported vocabulary with the same target form and meaning shares SRS progress across sections. Different meanings receive separate generated IDs; an optional `id` on a vocabulary entry can explicitly control sharing.
   - Pre-loaded with the **Unit 2/Lesson 26** sample dataset (nouns, verbs, adjectives with sentences and audio).

2. **Extensible for Any Language**:
   - Supports Korean (KO ➔ EN, EN ➔ KO) and any other language pair (e.g. Japanese, Chinese, Spanish, French, German).
   - Auto-detects target language keys or uses root `language: ...` and `native: ...` settings.

3. **Intelligent Flashcard Visibility Rules**:
   - **Target ➔ Native (KO ➔ EN)**: Hidden by default for verbs and adjectives; enabled by default for other parts of speech (e.g., nouns).
   - **Native ➔ Target (EN ➔ KO)**: Enabled by default for verbs and adjectives; hidden by default for other cards.
   - **Individual Overrides**: Both directions can be freely toggled on or off per vocabulary item.
   - **Reset Progress**: Reset SRS progress for an entire lesson or an individual vocabulary item without changing card visibility.
   - Delete a section and all nested vocabulary, or delete an individual vocabulary entry. Deleting an entry resets SRS progress for any other entries sharing its ID.

4. **Front-of-Card Random Sentence with Cloze Deletion**:
   - Each card dynamically selects a **random example sentence** from the vocabulary's pool to display on the front.
   - For **KO ➔ EN** cards: Displays the target word and the Korean context sentence.
   - For **EN ➔ KO** cards: Displays the English translation prompt and the random sentence with **Cloze Deletion** (e.g. `저는 (___)를 위해 문을 열었어요`), handling bold tags and Korean verb/adjective stems.
   - The user can flip back and forth between front and back anytime (via `Space`, `Enter`, `F`, or tapping the card).

5. **Sentence Pooling**:
   - Sentences from all lessons are indexed into a central **Sentence Pool**.
   - Browse, search, and link any sentence from the pool to any vocabulary item.
   - The sentence picker opens with the selected vocabulary as its search query. Korean-aware local tokenization handles Hangul subwords, common particles, and frequent verb/adjective endings without downloading a large model.
   - Create new sentences directly in the pool or while editing a vocabulary item.

6. **Instant Audio Streaming with Offline Caching**:
   - **Stream-on-First-Play**: Audio starts streaming immediately on the very first play with zero wait time.
   - **Background Caching**: Simultaneously downloads and stores the `.mp3` bytes in the app's sandbox cache directory (`audio_cache/`), not in My Documents.
   - On Windows, the cache parent directory uses the app's company and product metadata (`%LOCALAPPDATA%\\cc.polv\\lingua.srs\\audio_cache`).
   - Windows preferences from the previous `com.example\\lingua_srs` app directory are migrated on first launch when the new directory is empty or contains only the untouched sample lesson.
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

---

## 🚀 Running the App

### 1. Set as Active Workspace
We recommend setting `C:\Users\HP\.gemini\antigravity\scratch\lingua_srs` as your active workspace in your IDE.

### 2. Run on Desktop (Windows)
```bash
cd lingua_srs
flutter run -d windows
```

### 3. Run on Mobile (Android / iOS)
```bash
flutter run -d <android-device-id-or-emulator>
```

### 4. Run Unit Tests
```bash
flutter test test/unit_test.dart
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
│   │   └── srs_card.dart              # SRS state (SM-2 intervals, reps, due date)
│   ├── providers/
│   │   └── app_provider.dart          # State management (lessons, queues, review handling)
│   ├── services/
│   │   ├── srs_service.dart           # SM-2 algorithm implementation
│   │   ├── yaml_parser_service.dart   # Flexible YAML lesson & sentence parser
│   │   ├── audio_service.dart         # Audio player with sequential autoplay
│   │   └── storage_service.dart       # Local persistence via SharedPreferences
│   ├── views/
│   │   ├── study_view.dart            # Flashcard study view with cloze & shortcuts
│   │   ├── lesson_list_view.dart      # Lessons dashboard & due queue counter
│   │   ├── lesson_detail_view.dart    # Vocab list, POS filters, direction toggles
│   │   ├── sentence_pool_view.dart    # Global & lesson sentence pool browser
│   │   ├── yaml_import_view.dart      # File picker, YAML text editor & validator
│   │   └── vocab_edit_dialog.dart     # On-the-go editor for any field
│   └── widgets/
│       ├── adaptive_scaffold.dart     # Responsive layout (Rail vs BottomNav)
│       ├── audio_button.dart          # Audio play/stop indicator
│       └── markdown_content.dart      # Markdown & HTML renderer
└── test/
    └── unit_test.dart                 # Automated tests for parser, cloze & SM-2
```

---

## 📝 Creating a Lesson from YAML

Open **Add Lessons** and enter a lesson name in the single-line **Lesson name** field, for example:

```text
Unit 2 / Lesson 26
```

The first part becomes the parent unit; remaining parts form the lesson title and any deeper hierarchy. A single name such as `Greetings` creates a top-level lesson. Then enter the vocabulary in the multiline **YAML** field. The field starts empty; its neutral placeholder is an example only and is not imported.

Use a `vocabulary:` root, then group vocabulary under any number of section levels. Example:

```yaml
vocabulary:
  nouns:
    everyday:
      - ko: "예시 단어"
        en: "example word"
        audio: "https://example.com/word-audio.mp3"
        notes: "Optional HTML or Markdown notes"
        examples:
          - ko: "저는 **예시 단어**를 배워요."
            en: "I learn an **example word**."
          - ko: "다른 문장입니다."
            audio: "https://example.com/sentence-audio.mp3"
            en: "This is another sentence."
  verbs:
    - ko: "만들다"
      en: "to make"
```

Each entry should include a target-language field (such as `ko`) and a translation field (such as `en`). `audio`, `notes`, and `examples` are optional. Example sentence emphasis uses Markdown `**bold**`; the app uses it for cloze cards. Add an optional `id` when entries should explicitly share SRS progress, or need distinct identities:

```yaml
vocabulary:
  fruit:
    - id: pear-entry
      ko: "배"
      en: "pear"
  common-words:
    - id: pear-entry
      ko: "배"
      en: "pear"
```

The **Import YAML** button remains disabled until valid YAML can be previewed. Fix any displayed parse errors, review the lesson and vocabulary preview, then import. You can also use **Pick File** to load a YAML/YML/TXT/Markdown file, or **Pick Folder** to scan Markdown files recursively. Folder imports use only files with a `vocabulary:` map in their YAML frontmatter; ordinary Markdown body text is ignored. Re-importing updates matching lessons and vocabulary while preserving SRS progress and keeping unmatched vocabulary.

### Markdown frontmatter format

For folder imports, Markdown files must have YAML frontmatter containing a `vocabulary:` map. The first Markdown heading supplies the lesson title unless a lesson name is supplied separately:

```markdown
---
vocabulary:
  nouns:
    - ko: "예시 단어"
      en: "example word"
---
# Lesson 1: Example title

Lesson notes go here and are not imported as vocabulary.
```

Vocabulary sections can be nested to any depth. Entries with the same explicit
vocabulary `id` share SRS progress, including across sections. Use different IDs
to force separate progress identities when needed. Without an explicit ID, the
app shares progress for the same target form and meaning, while different
meanings receive separate generated IDs.
