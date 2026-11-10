// A VitePress theme that shows LinguaSRS lesson tags in the preview.
// Copy this folder to `.vitepress/theme/` in the folder VitePress serves.
// See ../vitepress.md.
import DefaultTheme from 'vitepress/theme'
import AudioButton from './AudioButton.vue'
import Nothing from './Nothing.vue'
import TTS from './TTS.vue'
import YouTube from './YouTube.vue'
import './lesson.css'

export default {
  extends: DefaultTheme,
  enhanceApp({ app }) {
    app.component('AudioButton', AudioButton)
    app.component('TTS', TTS)
    app.component('YouTube', YouTube)
    // The app shows nothing for these.
    app.component('VocabQuiz', Nothing)
    app.component('SentenceQuiz', Nothing)
  },
}
