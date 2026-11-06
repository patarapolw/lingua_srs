# Architecture

Overview of the source layout. Lesson file syntax lives in [lesson-format.md](lesson-format.md).

```
lingua_srs/
├── worker/                            # Cloudflare Worker (D1) for sync; see sync.md
├── lib/
│   ├── main.dart                      # App entry point, MultiProvider, adaptive theming
│   ├── models/
│   │   ├── lesson.dart                # Lesson model with language pair and stats
│   │   ├── vocab_item.dart            # Vocab model with POS, notes, toggles
│   │   ├── sentence.dart              # Sentence model with cloze deletion generator
│   │   ├── srs_card.dart              # SRS state (SM-2 intervals, reps, due date)
│   │   ├── shared_vocab.dart          # Details and SRS cards shared by every word with the same id
│   │   ├── vocab_merge_record.dart    # Vocab groups, merge records and undo snapshots
│   │   └── ai_discussion_message.dart # Saved AI discussion messages
│   ├── providers/
│   │   └── app_provider.dart          # State management (lessons, queues, review handling)
│   ├── services/
│   │   ├── srs_service.dart           # SM-2 algorithm implementation
│   │   ├── study_stats.dart           # Streak, right/wrong split and due forecast for Study activity
│   │   ├── yaml_parser_service.dart   # Markdown/YAML lesson & sentence parser
│   │   ├── audio_service.dart         # Audio playback, TTS and offline caching
│   │   ├── image_cache_service.dart   # Disk cache for online images in Markdown
│   │   ├── deepseek_service.dart      # DeepSeek chat client for quiz discussions
│   │   ├── backup_service.dart        # Versioned local data backup and restore
│   │   ├── sync_pairing.dart          # Sync account (email and password) and its `linguasrs://sync` sign-in link
│   │   ├── sync_client.dart           # Cloudflare Worker sync and dictionary inbox client
│   │   ├── sync_error_text.dart       # Plain messages for failed sync requests
│   │   ├── sync_account_crypto.dart   # Password-derived sync keys and wrapped data key
│   │   ├── sync_account_service.dart  # Sync account creation, confirmation and password changes
│   │   ├── sync_password_policy.dart  # New-account and password-change validation
│   │   ├── sync_records.dart          # The records that sync, built from the app's state
│   │   ├── sync_change_tracker.dart   # Notices changed records; pending pushes and pull cursor
│   │   ├── sync_record_cipher.dart    # Encrypts, splits and decrypts records; the unlocked data key
│   │   ├── sync_engine.dart           # Pulls, resolves conflicts and pushes records
│   │   ├── sync_apply.dart            # Applies pulled records to lessons, cards and the rest
│   │   ├── secret_storage.dart        # OS-backed secure storage for credentials
│   │   ├── lesson_ai_prompt.dart      # Prompt, ids and suggestions for lesson AI chats
│   │   ├── word_ai_prompt.dart        # Prompt for word AI chats, with the current example sentence
│   │   ├── ai_question_suggestions.dart # Fixed and AI-suggested questions offered in AI chats, per language
│   │   ├── ai_discussion_search.dart  # Ids, search and related-word suggestions for saved AI chats
│   │   ├── korean_text_search.dart    # Korean-aware sentence search tokenizer
│   │   ├── vocab_picker_search.dart   # Ranks vocabulary for the merge picker; scores a typed query
│   │   ├── vocab_pool_search.dart     # Browse, search and POS filter for the Vocab Pool
│   │   ├── clipboard_markdown.dart    # Reads the clipboard as Markdown, converting copied HTML
│   │   ├── html_to_markdown.dart      # Converts copied HTML to Markdown
│   │   ├── english_text_search.dart   # English full-text search over vocabulary meanings
│   │   ├── korean_pronunciation_service.dart # Revised Romanization and IPA from how Korean sounds
│   │   ├── lesson_export_service.dart # Exports lessons and units as a ZIP of Markdown files
│   │   ├── markdown_archive_service.dart # Reads Markdown files out of an imported ZIP
│   │   ├── vocab_ai_service.dart      # AI merge suggestions and similar-meaning hints
│   │   └── storage_service.dart       # Local persistence and debug seed data
│   ├── views/
│   │   ├── study_view.dart            # Flashcard study view with cloze & shortcuts
│   │   ├── lesson_list_view.dart      # Lessons dashboard & due queue counter
│   │   ├── lesson_reader_view.dart    # Lesson Markdown reader & editor
│   │   ├── lesson_detail_view.dart    # Vocab list, POS filters, direction toggles
│   │   ├── sentence_pool_view.dart    # Global & lesson sentence pool browser
│   │   ├── vocab_pool_view.dart       # Vocab Pool tab: all distinct words, search, POS filter
│   │   ├── yaml_import_view.dart      # File/folder import, editor, validator & preview
│   │   ├── vocab_edit_dialog.dart     # On-the-go editor for any field
│   │   ├── ai_discussion_dialog.dart  # AI-assisted quiz discussion chat
│   │   ├── recent_ai_discussions_view.dart # Recent Discussions tab, with search
│   │   ├── related_ai_discussions_sheet.dart # Related discussions panel of an AI chat
│   │   ├── activity_heatmap_view.dart # Study activity: heatmap, cards by stage, leeches
│   │   ├── similar_meanings_dialog.dart # Review AI-suggested hints for similar words
│   │   ├── similar_search_dialog.dart # Search similar English meanings to write a front hint
│   │   ├── vocab_merge_dialogs.dart   # Manual and AI merge flows, merge history and undo
│   │   ├── pairing_confirmation.dart  # Asks before a pairing link signs this device in
│   │   └── settings_dialog.dart       # Theme, autoplay, review limits, backup, AI key and sync
│   └── widgets/
│       ├── adaptive_scaffold.dart     # Responsive layout (Rail vs BottomNav)
│       ├── ai_discussion_suggestion_tile.dart # One suggested AI discussion and why
│       ├── ai_question_chip.dart              # A suggested question to tap; a long one wraps onto more lines
│       ├── audio_button.dart          # Audio play/stop indicator
│       ├── answer_workspace.dart      # Per-card handwriting or typed answer area
│       ├── audio_edit_fields.dart     # Audio URL (preview, use-recording checkbox) and collapsible TTS text fields for edit dialogs
│       ├── emphasis_text.dart         # Sentence text with **bold** segments, no Markdown
│       ├── folder_picker_dialog.dart  # Pick an existing or new folder to move a lesson/folder into
│       ├── lesson_hierarchy_view.dart # Lesson folder tree with reordering
│       ├── lesson_content_view.dart   # Lesson Markdown reader (native, chunked lazy list)
│       ├── cached_markdown_image.dart # Online Markdown image shown from the disk cache
│       ├── markdown_content.dart      # Markdown renderer for notes and chat
│       ├── markdown_notes_field.dart  # Notes form field: Add button, rendered notes, Edit/Preview
│       ├── icon_switch.dart           # Switch flanked by icons, e.g. light and dark
│       ├── markdown_text_field.dart   # Markdown text field that converts pasted HTML
│       ├── pronunciation_line.dart    # Optional romanization and IPA lines under Korean text
│       ├── pronunciation_toggle.dart  # RR and IPA toggles in the review menu
│       ├── review_notes_editor.dart   # Review note editable from a card's back; text-focus check for shortcuts
│       ├── swipe_actions.dart         # Swipe-to-reveal action panel for list tiles
│       ├── sync_scheduler.dart        # Runs syncs at start, on resume and after edits
│       └── youtube_embed.dart         # YouTube embed for lesson Markdown
├── integration_test/                  # Keychain and network checks on a real desktop build
└── test/                              # Parser, SRS, storage, import and widget tests
```
