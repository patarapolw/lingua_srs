# LinguaSRS - Adaptive Language Learning SRS App

A Flutter application targeting **Desktop (Windows, macOS, Linux)** and **Mobile (Android, iOS)** for language learning with an Anki/SM-2 Spaced Repetition System (SRS).

---

## 🌟 Key Features

1. **YAML/Markdown Lesson Architecture**:
   - Create and import lessons using human-readable YAML or Markdown documents with YAML frontmatter.
   - Import a directory recursively; Markdown files are read from their `vocabulary:` frontmatter section and grouped by their parent folder (for example, `unit-2` becomes Unit 2).
   - Built-in parser with live syntax checking, error reporting, and visual preview.
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

## 📝 Example YAML Lesson Format

```yaml
Lesson: Unit 2/Lesson 26

nouns:
  - ko: 아줌마
    audio: https://example.com/audio/2016/01/Lesson26v2.mp3
    en: middle aged/older woman
    notes: |
      <p>The word "아주머니" is commonly used as well</p>
      <p>아줌마 and 아주머니 are commonly used to refer to an older woman that you don't know the name of.</p>
    examples:
      - ko: 저는 **아줌마**를 위해 문을 열었어요
        en: I opened the door for **an older lady**

verbs:
  - ko: 도착하다
    audio: https://example.com/audio/2016/01/Lesson26v8.mp3
    en: to arrive
    examples:
      - ko: 우리는 공항에 정각에 **도착했어요**
        en: We arrived at the airport on time
```

Vocabulary sections can be nested to any depth. An optional vocabulary `id`
explicitly identifies entries that should share SRS progress across sections:

```yaml
vocabulary:
  nouns:
    food:
      - id: shared-pear
        ko: 배
        en: pear
  examples:
    - id: shared-pear
      ko: 배
      en: pear
```
