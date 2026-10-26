# Architecture

Overview of the source layout. Lesson file syntax lives in [lesson-format.md](lesson-format.md).

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
│   │   ├── lesson_ai_prompt.dart      # Prompt, ids and suggestions for lesson AI chats
│   │   ├── ai_discussion_search.dart  # Ids, search and related-word suggestions for saved AI chats
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
