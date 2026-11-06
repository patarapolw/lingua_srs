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
   - A **front hint** can cover both directions or be set per direction; a direction-specific hint wins. On EN ➔ KO, *Find similar English meanings* searches your vocabulary for words with similar meanings (the same type by default) to help you write a hint that tells them apart. With a DeepSeek API key, the sparkle button suggests a hint, sending the vocabulary of the same type (EN ➔ KO) or the words with the same spelling (KO ➔ EN) to DeepSeek.
   - Each card direction has editable Markdown notes displayed on its back. Notes fields everywhere work alike: an *Add … note* button while empty, the rendered notes with *Edit* once filled, *Preview* while editing.
   - **Image cache**: online images in Markdown are downloaded once into `image_cache/` (next to `audio_cache/`; on Windows under `%LOCALAPPDATA%\\cc.polv\\lingua.srs`) and shown from disk afterwards, including offline. An image that cannot be saved (not a picture, SVG, over 25 MB, offline the first time) is shown from the network as before.

4. **Front-of-Card Random Sentence with Cloze Deletion**:
   - Each card dynamically selects a **random example sentence** from the vocabulary's pool to display on the front.
   - For **KO ➔ EN** cards: Displays the target word and the Korean example sentence.
   - For **EN ➔ KO** cards: Displays the English translation prompt and the random sentence with **Cloze Deletion** (e.g. `저는 (___)를 위해 문을 열었어요`), handling bold tags and Korean verb/adjective stems.
   - The user can flip back and forth between front and back anytime (via `Space`, `Enter`, `F`, or tapping the card).

5. **Sentence Pooling**:
   - Sentences from all lessons are indexed into a central **Sentence Pool**.
   - Browse, search, edit and link any sentence from the pool to any vocabulary item. The pool holds plain text; the `**` emphasis (bold and cloze blank) is set per word, so words sharing a sentence can stress different parts. See [lesson-format.md](lesson-format.md).
   - The sentence picker opens with the selected vocabulary as its search query. Korean-aware local tokenization handles Hangul subwords, common particles, and frequent verb/adjective endings without downloading a large model.
   - Create new sentences directly in the pool or while editing a vocabulary item.
   - A matching **Vocab Pool** tab lists every distinct word once, even when several lessons share it, with the lessons it appears in. Search in Korean (Hangul finds the word, its conjugated forms and its meaning) or in English (meanings and notes, best match first), narrow by part of speech, and tap a word to edit it.
   - **Deleting from the pools and Recent Discussions**: swipe a tile left to reveal a Delete button (on a wide screen, use the tile's ⋮ menu in the two pools). Nothing is deleted until you confirm. Deleting a word removes it from every lesson that has it, and the dialog lists those lessons; deleting a sentence also removes it as an example from the words that use it.

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
   - **Brackets are not spoken**: text in round brackets, such as `먹다 (to eat)`, is skipped, or the voice would stumble over the note. Cloze blanks and Markdown marks are skipped too. The pronunciation line still shows bracketed text.
   - **Voices vary**: when an Android language has several installed offline voices, each utterance picks one at random.
   - **Alternate TTS text** (`tts`) is used for review autoplay and replay as well as for the audio buttons.
   - **Recording or TTS**: every word and sentence with an audio URL has a *Use this recording* checkbox in its editor. Unticking it speaks with TTS instead, and keeps the URL.
   - **Preview in the editors**: the vocabulary editor, the *Add Example* dialog and the Sentence Pool editor all have a button on the Audio URL (plays the URL as typed) and one in the header of the collapsible *Text-to-speech* section (speaks the TTS text, or the word or sentence while that is blank), so TTS can be previewed without opening the section. The Sentence Pool list itself has no audio buttons.
   - **Order**: in every editor the Audio URL comes first, with its *Use this recording* checkbox directly under it, followed by the collapsible *Text-to-speech* section that is used when there is no recording or it is switched off.
   - **Per example**: in the vocabulary editor each example that has a recording has a small *Use recording* chip (ticked plays the recording, unticked speaks with TTS). Choices on existing examples are applied when the word is saved.

8. **Keyboard Navigation & Anki-Style Hotkeys**: see [hotkeys.md](hotkeys.md).

9. **Adaptive Desktop & Mobile UI**:
   - **Desktop**: Navigation Rail sidebar, wide-screen flashcard canvas, complete hotkey bar, undo & navigation controls.
   - **Mobile**: Responsive bottom navigation (swipe left or right to change tab), touch-friendly card taps, swipeable sheet editors.

10. **Recent Mistakes & Adaptive Queueing**:
   - **Top-Level "Recent Mistakes" Review**: Directly review active mistakes across all lessons (or per lesson) from the Daily Review Queue card, which shows a **Recent Mistakes** button with a live count only while mistakes exist.
   - **Interleaved Re-queuing**: Cards rated *Again* are automatically re-inserted a few cards ahead in the active session for delayed retrieval practice.
   - **Intelligent Session Completion**: Looping continues as long as multiple unmastered cards remain, and concludes when at most 1 *Again*'d card is left to avoid immediate zero-delay 1-card echo loops.
   - **Color-Coded Review Progress Bar**: Displays live Wrong (Red) and Right (Green) breakdown indicators directly on the top progress bar and AppBar during study sessions. In a study review a card counts by its first answer: *Good* and *Easy* are right, *Again* and *Hard* are wrong. In Recent Mistakes a card counts by its latest answer, so a mistake answered *Good* on a retry turns green. Both screens show progress as `n / total`.
   - **New Cards vs Due Cards**: A card that has never been reviewed is *new*, not *due*. Due cards (already seen and scheduled for now or earlier) are studied first, then new cards, each in lesson order. The dashboard banner lists the two counts separately (e.g. `12 due • 10 new`) and its button shows the total (`Study 22`); a lesson row shows its word count with an amber *Due* and a coloured *New* badge, and a lesson's Study button counts the cards the session will hold. On a phone the banner stacks its buttons under the text and a lesson row swaps its Study button for an icon and moves *View Vocabulary* into its menu (tapping the row still opens the lesson reader).
   - **Two Buttons for a First Review**: A new card's first review offers only *Again* (back in 1 hour) and *Good* (next day), since there is nothing yet to judge *Hard* or *Easy* against. The card carries a *NEW* chip, in the same colour as the *New* badge in the lesson list, so the shorter choice is explained. Later reviews of the card offer all four ratings.
   - **Reset Card During Review**: The overflow menu (⋮) of a study session has *Reset card to New*, available once the answer is shown. It resets only the card on screen (one direction of the vocabulary item) back to New after a confirmation; the other direction keeps its progress. The card then offers the two first-review buttons and its next rating counts as a first review. It is unavailable for cards that are already New and for cards you have navigated back to.
   - **24-Hour Review Window Limit**: Caps daily review volume to a rolling 24-hour limit (default: 100 due cards), customizable or set to unlimited in **Settings** (gear icon). A card's first review does not use this limit, and neither do cards on a sub-24h interval (the 1-hour *Again* and 12-hour *Hard* repeats): they are always queued when due and do not use up the quota. The dashboard shows cards due today (or, when none are due, how many are due tomorrow), plus the number of reviews in the last 24 hours once it is above zero. Undoing a rating takes its review back off this count and off Study activity, so rating the card again counts it once.
   - **24-Hour New Card Limit**: A separate rolling 24-hour limit on how many never-seen cards can be started (default: 10), also set in **Settings** (0 for unlimited). There is no fixed "new day" rollover: a card started at 14:00 frees its slot at 14:00 the next day. The limit is derived from each card's first-review time, so undoing or re-rating a card's first review gives the slot back. Cram Mode and Recent Mistakes ignore both limits.
   - **Cram Mode**: practise beyond the limits. The lessons screen offers *Practice in Cram Mode* when a limit is reached, and a finished session offers *Review All (Cram Mode)*; both queue every enabled card, due or not.
   - **Sub-24h Repetition for Difficult Cards**: Cards marked *Again* are scheduled to repeat after a sensible 1-hour minimum delay (rather than waiting an entire day), while *Hard* always repeats in 12 hours. *Good* is never sub-24h: it is due after 1 day on a card's first repetition, 6 days on its second, and then grows by at least a day each time (*Again* starts the count over). Hard also keeps a hidden interval in days (shorter than *Good*'s, and 1 day only when *Good* is 1 day) that the next review builds on, and *Easy* is always longer than *Good* and at least 2 days. The hidden intervals of *Again* and *Hard* are written to the debug log (`adb logcat -s flutter`).
   - **POS-Category Shuffling**: Cards within each lesson are shuffled and interleaved across parts of speech (nouns, verbs, adjectives, etc.) rather than displaying oldest-inserted cards first, while continuing to prioritize oldest-inserted lessons first.

11. **AI-Assisted Quiz Discussions**:
   - Configure a DeepSeek API key in **Settings** (gear icon), then ask questions about the current vocabulary and example sentence during a quiz. Answers stream into the chat and render as Markdown.
   - A new chat starts with up to 4 fixed suggested questions about where the word comes from (Hanja or native Korean) and how the card's sentence works. A word counts as a verb or adjective when its part of speech or one of its sections says so (`verbs`, `passive verbs`, `adjectives`); when they name another part of speech (`nouns`, `adverbs`) it does not; and when they are only categories such as `food`, it does if the word ends in 다. A verb or adjective is also asked whether it is irregular, how it commonly conjugates in example sentences, and how it looks in the different speech levels, because the card has its dictionary form. Any other word is asked its register and whether there is a more polite word. A card with a sentence is also asked the sentence's speech level, and there is a question for another example.
   - After each answer, up to 4 follow-up questions are offered under *Suggested next questions*: 2 to 3 fixed ones that have not been asked yet (the sentence's speech level; whether a verb or adjective is irregular and how it conjugates; the word's pronunciation and sound rules, or for a verb or adjective the sound rules when it conjugates; register or speech levels; a quiz; other useful expressions; similar words; another example) and up to 2 the AI suggests from the last answer and the card's sentence. The AI's questions arrive a moment later, after the fixed ones, and are not saved; if they cannot be fetched, 3 fixed questions are shown. Lesson chats work the same way with lesson questions. The word questions and the AI's suggestions are written per language and only exist for Korean so far; a chat in another language gets neither.
   - Press Enter to send a chat message and Shift+Enter or Ctrl+Enter to add a new line.
   - **Ask AI about lesson** in the lesson reader opens a discussion grounded in the lesson's Markdown and vocabulary. Lesson chats are saved with the others under Recent Discussions.
   - Discussions are saved locally per vocabulary, shared by all of its example sentences (the sentence on the card is only context for the AI; it is sent in the system prompt and again in front of each new question, so the AI follows you when you ask about another sentence of the same word), restored when revisiting that card, and can be deleted from the **More** menu inside the discussion, or by swiping its tile in Recent Discussions. Merging vocabulary moves the saved discussions of the merged words to the word they were merged into and joins them into one conversation. Discussions saved per sentence by earlier versions are joined into their word's single discussion on startup. They also follow a word whose id changes (its ID edited, or the lesson re-imported after the word's text was edited), unless another word still has the old id.
   - **Earlier discussions**: When you open a discussion that has no messages yet, the dialog lists your other discussions about the same word, then the latest one for each related word (same spelling, another form of the word, or the same meaning), each labelled with why it is shown. Tap one to open it in place of the empty chat.
   - **Related discussions**: every word chat, empty or not, has a *Related discussions* button in its header (lesson chats do not). It opens a panel whose search box already holds the word, so the suggestions need no typing: other chats about the same word and about related words, each labelled, then any other chat that mentions the word. Edit the box to turn the list into a plain search, or clear it to browse every other chat. Picking one opens it on top of the current chat, so closing it comes back to where you were.
   - The **Recent Discussions** tab lists every saved discussion, most recently active first, with the vocabulary and the latest question. Tap one to reopen it. Discussions saved before timestamps were added are listed last. A search box above the list finds discussions by the Korean word (including other forms of it), its meaning in English, the lesson title of a lesson chat, and anything said in the conversation; the best match comes first and a word or meaning ranks above a passing mention. Each row has a delete button that asks first. A chat whose word or lesson no longer exists (deleted, or merged or renamed before ids were followed) is titled *Word not found* or *Lesson not found* and stays searchable by what was said. Opening one shows the conversation read-only, with a *Continue without the word/lesson* button; continuing tells the AI the word or lesson is gone, so it works from the conversation alone and asks for the text instead of guessing, and the suggested questions and Related discussions button are hidden. It can be deleted from the list or from inside the chat (which then closes). Deleting a word or a lesson never deletes its chats automatically.

12. **Study Activity**:
   - Open **Study activity** from the ⋮ menu on the lessons screen.
   - A calendar heatmap shows reviews per day over the past year, one column per week starting on Monday, with the total above it. Darker cells mean more reviews that day. The four shades are quarters of the busiest day shown, so heavy days stand out even at 100 reviews a day; each legend square's tooltip gives its range.
   - **Cards by stage** charts the enabled cards that are New, Learning or Review. A card shared by several lessons is counted once.
   - **Leeches** lists cards with at least 8 lapses, showing the word, its meaning and the lapse count, since they may need a new approach.
   - Until you have reviewed something (and have no leeches), *No study activity yet* takes the calendar's place, and Cards by stage still shows the cards waiting. With no cards at all, the screen shows only *No study activity yet*.

13. **Answer Pad**:
   - Each card in a review, front and back, has a collapsed *Your answer* button that opens a pad for writing the answer before you reveal it.
   - Choose between typing and drawing. Typing is the default on Windows, macOS and Linux, drawing on Android and iOS. Drawing opens a scratchpad with pen colours, an eraser and a clear button.
   - `Ctrl+Enter` in the typed answer reveals the card, or submits **Good** once the answer is shown, like the hotkey in [hotkeys.md](hotkeys.md).
   - The pad is a scratch area: nothing is saved or graded, and it starts empty on every card.

14. **Backup, Restore & Export**:
   - **Backup**: **Settings** (gear icon) ➔ *Backup and restore* saves a `lingua_srs_backup.json` file with your lessons, study progress, sentences, shared vocabulary and merge history, AI discussions, lesson Markdown and app settings. The DeepSeek API key and the sync password are not included, and neither are the audio and image caches, which are downloaded again when needed.
   - **Restore**: pick a backup file; after a confirmation it replaces the app data on this device, and the DeepSeek API key and sync sign-in stay. A file in another format or version, or with invalid data, is rejected before anything is replaced.
   - **Export as ZIP**: choose *Export as ZIP* in the menu of a lesson, or of a unit or folder in the lesson list. Each lesson becomes a Markdown file with YAML frontmatter, placed in folders that mirror its `::` hierarchy, so the ZIP can be imported again (see [lesson-format.md](lesson-format.md)). File names are made safe for common file systems, and lessons with the same name get their ID added. Review progress is not part of an export; use a backup for that.

15. **Pronunciation Cues**:
   - In a Korean lesson's review, the ⋮ menu has a *Pronunciation cue* entry with **RR** (Revised Romanization) and **IPA** toggles, set separately for the **Vocabulary** and the **Sentence**. The choice is remembered between sessions and is part of a backup.
   - The lines appear under the Korean text on the back of the card only, so they never give the answer away. The toggles stay disabled until the answer is revealed.
   - The text is converted by how it sounds, not how it is spelled: sound changes between neighbouring syllables are applied within each run of Hangul. IPA is shown in brackets, with syllables separated by dots.
   - **Bold** marks and cloze blanks are skipped, and bracketed text is kept.

16. **Merging Duplicate Vocabulary**:
   - Open a saved word's editor and use **Merge duplicates**. *Merge with another word…* lets you search the other word in Korean or English. With a DeepSeek API key, *Suggest merge with AI* proposes duplicates for that word, and *Suggest merges with AI* in the ⋮ menu of the lessons screen does the same for the whole collection.
   - Merged words become one vocabulary in every lesson, sharing SRS progress, audio, notes and front hint, while each lesson keeps its own wording.
   - When merging by hand you choose whose SRS progress to keep (each option shows its review count and lessons). The other word's progress and card hints are discarded once you confirm.
   - A snackbar offers *Undo* for 10 seconds, and *Merge history / undo* in the same ⋮ menu (available once something has been merged) lists past merges so any of them can be undone later, bringing back the discarded progress and hints.

17. **Settings**:
   - Open **Settings** (gear icon) on the lessons screen.
   - **Theme** switches between light and dark. **Autoplay audio** turns the automatic playback of a card's word and sentence audio on or off.
   - **Max reviews per 24 hours** and **Max new cards per 24 hours** set the rolling limits described under *Recent Mistakes & Adaptive Queueing*. Enter 0 for unlimited.
   - **DeepSeek API key** enables the AI features. It is stored in the device's secure storage and can be removed beside the key field in Settings.
   - **Sync** lets you create an account with an email-confirmation code, sign in with an email and password, or use a one-time encrypted pairing link copied from another device. New and changed passwords must meet the policy in [sync.md](sync.md); existing passwords remain valid for sign-in. Signed-in users can change their password without re-encrypting the wrapped data key, display a QR code or copy a short-lived pairing link for another device, check that the server still accepts their sign-in, delete their account from the server, or sign out after confirmation. Pairing links grant account access, expire after 10 minutes, and should only be shared with a device you control; a device asks to confirm the account and server before it signs in from one. A device whose account was deleted or whose password was changed elsewhere keeps its lessons and progress, is not signed out by itself, and is told so by *Check sign-in*. The sign-in is stored on the device and is not part of a backup. The section only appears in a build made with a sync server address (see sync.md). Lessons and progress are not synced yet.
   - **Back up** and **Restore**: see *Backup, Restore & Export*.
