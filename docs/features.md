# Features

Full feature reference. For a short overview see the [README](../README.md).

1. **YAML/Markdown Lesson Architecture**:
   - Create lessons from the **Import Lessons** screen (**Add Lessons** in the section header) with a lesson-name field and a Markdown editor. Both start empty; the editor shows a placeholder example of Markdown with YAML frontmatter and an optional Markdown body.
   - Use `::` in the lesson name to separate hierarchy levels. For example, `Unit 2::Lesson 26` groups the lesson under `Unit 2`; `Topic::Subtopic::Lesson A` creates a deeper hierarchy.
   - Import Markdown/YAML files or ZIP archives with one picker, or drag `.md`, `.yaml`/`.yml`, and `.zip` files onto the desktop import screen. Markdown containing only YAML frontmatter imports the same as equivalent plain YAML. Import folder(s) with a separate action. Multiple folders can be selected together on macOS; other platforms select one folder at a time. Nested folder and archive paths preserve lesson hierarchy.
   - Importing ZIP archives provides a batch-import option on Android, where directory import is restricted. Choose which Markdown lessons to import (all unchecked initially, with **Check all** and **Uncheck all** controls).
   - YAML and Markdown frontmatter are parsed in a background isolate with parse errors and an import preview. Folder import parsing also runs off the UI isolate.
   - Unit and nested folder groups in the library are expanded by default; expansion states and sibling order are saved across view changes and app restarts. Drag lessons and folders to reorder them, or use their menus to move them between folders. `::`-separated lesson paths create nested folders. Vocabulary frontmatter uses `vocabulary:` as the root, with part-of-speech keys directly beneath it and vocabulary entries listed under each key. Re-importing updates matching lessons and vocabulary in place while retaining SRS progress and entries not present in the import.
   - Imported vocabulary with the same target form and meaning shares SRS progress across part-of-speech groups. Different meanings receive separate generated IDs; an optional `id` on a vocabulary entry can explicitly control sharing.
   - Importing Markdown lessons keeps the document body for reading from the lesson list; it can be edited and saved at any time. The reader renders the whole lesson as a single document in a WebView, and **View Vocabulary** remains a separate view. A table-of-contents button lists the lesson's headings and scrolls to the chosen one.

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
   - A matching **Vocab Pool** tab lists every distinct word once, even when several lessons share it, with the lessons it appears in. Search in Korean (Hangul finds the word, its conjugated forms and its meaning) or in English (meanings and notes, best match first), narrow by part of speech, and tap a word to edit it.

6. **Instant Audio Streaming with Offline Caching**:
   - **Stream-on-First-Play**: Audio starts streaming immediately on the very first play with zero wait time.
   - **Background Caching**: Simultaneously downloads and stores the `.mp3` bytes in the app's sandbox cache directory (`audio_cache/`).
   - On Windows, the cache parent directory uses the app's company and product metadata (`%LOCALAPPDATA%\cc.polv\lingua.srs\audio_cache`).
   - **Instant Offline Playback**: Subsequent plays of that vocabulary or sentence play directly from the local disk file with **zero network latency** and 100% offline availability.
   - **Pre-buffering**: Automatically pre-buffers upcoming cards in the background so cards play instantaneously without delays.
   - **Autoplay stops with the card**: In review, the autoplayed word and sentence (audio files and TTS alike, including the sentence still waiting to play) stop when you move to another card or leave the review. Rotating the device does not cut audio off.

7. **Text-to-Speech**:
   - **Android** uses an installed offline system TTS voice. Install the desired language voice in Android text-to-speech settings; generated TTS is not sent to an online service or prefetched.
   - **Windows and other platforms** use online streamed TTS with local caching. Windows does not fall back to SAPI.

8. **Keyboard Navigation & Anki-Style Hotkeys**: see [hotkeys.md](hotkeys.md).

9. **Adaptive Desktop & Mobile UI**:
   - **Desktop**: Navigation Rail sidebar, wide-screen flashcard canvas, complete hotkey bar, undo & navigation controls.
   - **Mobile**: Responsive bottom navigation, touch-friendly card taps, swipeable sheet editors.

10. **Recent Mistakes & Adaptive Queueing**:
   - **Top-Level "Recent Mistakes" Review**: Directly review active mistakes across all lessons (or per lesson) from the Daily Review Queue card, which shows a **Recent Mistakes** button with a live count only while mistakes exist.
   - **Interleaved Re-queuing**: Cards rated *Again* are automatically re-inserted a few cards ahead in the active session for delayed retrieval practice.
   - **Intelligent Session Completion**: Looping continues as long as multiple unmastered cards remain, and concludes when at most 1 *Again*'d card is left to avoid immediate zero-delay 1-card echo loops.
   - **Color-Coded Review Progress Bar**: Displays live Wrong (Red) and Right (Green) breakdown indicators directly on the top progress bar and AppBar during study sessions. In a study review a card counts by its first answer: *Good* and *Easy* are right, *Again* and *Hard* are wrong. In Recent Mistakes a card counts by its latest answer, so a mistake answered *Good* on a retry turns green. Both screens show progress as `n / total`.
   - **New Cards vs Due Cards**: A card that has never been reviewed is *new*, not *due*. Due cards (already seen and scheduled for now or earlier) are studied first, then new cards, each in lesson order. The dashboard banner lists the two counts separately (e.g. `12 due • 10 new`) and its button shows the total (`Study 22`); a lesson row shows its word count with an amber *Due* and a coloured *New* badge, and a lesson's Study button counts the cards the session will hold. On a phone the banner stacks its buttons under the text and a lesson row swaps its Study button for an icon and moves *View Vocabulary* into its menu (tapping the row still opens the lesson reader).
   - **Two Buttons for a First Review**: A new card's first review offers only *Again* (back in 1 hour) and *Good* (next day), since there is nothing yet to judge *Hard* or *Easy* against. The card carries a *NEW* chip, in the same colour as the *New* badge in the lesson list, so the shorter choice is explained. Later reviews of the card offer all four ratings.
   - **Reset Card During Review**: The overflow menu (⋮) of a study session has *Reset card to New*, available once the answer is shown. It resets only the card on screen (one direction of the vocabulary item) back to New after a confirmation; the other direction keeps its progress. The card then offers the two first-review buttons and its next rating counts as a first review. It is unavailable for cards that are already New and for cards you have navigated back to.
   - **24-Hour Review Window Limit**: Caps daily review volume to a rolling 24-hour limit (default: 100 due cards), customizable or set to unlimited in **Settings** (gear icon). A card's first review does not use this limit, and neither do cards on a sub-24h interval (the 1-hour *Again* and 12-hour *Hard* repeats): they are always queued when due and do not use up the quota. The dashboard shows cards due today (or, when none are due, how many are due tomorrow), plus the number of reviews in the last 24 hours once it is above zero.
   - **24-Hour New Card Limit**: A separate rolling 24-hour limit on how many never-seen cards can be started (default: 10), also set in **Settings** (0 for unlimited). There is no fixed "new day" rollover: a card started at 14:00 frees its slot at 14:00 the next day. The limit is derived from each card's first-review time, so undoing or re-rating a card's first review gives the slot back. Cram Mode and Recent Mistakes ignore both limits.
   - **Sub-24h Repetition for Difficult Cards**: Cards marked *Again* are scheduled to repeat after a sensible 1-hour minimum delay (rather than waiting an entire day), while early *Hard* reviews repeat in 12 hours.
   - **POS-Category Shuffling**: Cards within each lesson are shuffled and interleaved across parts of speech (nouns, verbs, adjectives, etc.) rather than displaying oldest-inserted cards first, while continuing to prioritize oldest-inserted lessons first.

11. **AI-Assisted Quiz Discussions**:
   - Configure a DeepSeek API key in **Settings** (gear icon), then ask questions about the current vocabulary and example sentence during a quiz. Answers stream into the chat and render as Markdown.
   - Start with suggested questions about etymology/Hanja, key sentence vocabulary, everyday usage, and examples; get suggested follow-ups during the discussion.
   - Press Enter to send a chat message and Shift+Enter or Ctrl+Enter to add a new line.
   - **Ask AI about lesson** in the lesson reader opens a discussion grounded in the lesson's Markdown and vocabulary. Lesson chats are saved with the others under Recent Discussions.
   - Discussions are saved locally per vocabulary, shared by all of its example sentences (the sentence on the card is only context for the AI), restored when revisiting that card, and can be deleted from the **More** menu inside the discussion (the Recent Discussions list has no delete buttons). Merging vocabulary moves the saved discussions of the merged words to the word they were merged into and joins them into one conversation. Discussions saved per sentence by earlier versions are joined into their word's single discussion on startup. They also follow a word whose id changes (its ID edited, or the lesson re-imported after the word's text was edited), unless another word still has the old id.
   - **Earlier discussions**: When you open a discussion that has no messages yet, the dialog lists your other discussions about the same word, then the latest one for each related word (same spelling, another form of the word, or the same meaning), each labelled with why it is shown. Tap one to open it in place of the empty chat.
   - **Related discussions**: every word chat, empty or not, has a *Related discussions* button in its header (lesson chats do not). It opens a panel whose search box already holds the word, so the suggestions need no typing: other chats about the same word and about related words, each labelled, then any other chat that mentions the word. Edit the box to turn the list into a plain search, or clear it to browse every other chat. Picking one opens it on top of the current chat, so closing it comes back to where you were.
   - The **Recent Discussions** tab lists every saved discussion, most recently active first, with the vocabulary and the latest question. Tap one to reopen it. Discussions saved before timestamps were added are listed last. A search box above the list finds discussions by the Korean word (including other forms of it), its meaning in English, the lesson title of a lesson chat, and anything said in the conversation; the best match comes first and a word or meaning ranks above a passing mention. Each row has a delete button that asks first. A chat whose word or lesson no longer exists (deleted, or merged or renamed before ids were followed) is titled *Word not found* or *Lesson not found* and stays searchable by what was said. Opening one shows the conversation read-only, with a *Continue without the word/lesson* button; continuing tells the AI the word or lesson is gone, so it works from the conversation alone and asks for the text instead of guessing, and the suggested questions and Related discussions button are hidden. It can be deleted from the list or from inside the chat (which then closes). Deleting a word or a lesson never deletes its chats automatically.
