// A VitePress theme that shows LinguaSRS lesson tags in the preview.
// Copy this folder to `.vitepress/theme/` in the folder VitePress serves.
// See ../vitepress.md.
import DefaultTheme from 'vitepress/theme'
import AudioButton from './components/AudioButton.vue/index.js'
import Nothing from './components/Nothing.vue/index.js'
import TTS from './components/TTS.vue'
import YouTube from './components/YouTube.vue/index.js'
import './lesson.css'

export default {
  extends: DefaultTheme,
  enhanceApp({ app }) {
    app.component('AudioButton', AudioButton)
    app.component('TTS', TTS)
    app.component('YouTube', YouTube)
    // The app shows nothing for these.
    app.component('VocabQuiz', Nothing)
    app.component('Nothing', Nothing)
  },
}
