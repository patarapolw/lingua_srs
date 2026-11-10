<script setup>
// <TTS>text</TTS>: the text, then a button that speaks it with the
// browser's speech synthesis.
import { onBeforeUnmount, ref } from 'vue'

const props = defineProps({
  // The app speaks lesson text as Korean.
  lang: { type: String, default: 'ko-KR' },
})

const text = ref(null)
const speaking = ref(false)

function toggle() {
  const synth = window.speechSynthesis
  if (!synth) return
  if (speaking.value) {
    synth.cancel()
    speaking.value = false
    return
  }
  // Like the app, speak the text without its tags.
  const spoken = text.value?.textContent.trim()
  if (!spoken) return
  const utterance = new SpeechSynthesisUtterance(spoken)
  utterance.lang = props.lang
  utterance.onend = utterance.onerror = () => (speaking.value = false)
  synth.cancel()
  synth.speak(utterance)
  speaking.value = true
}

onBeforeUnmount(() => {
  if (speaking.value) window.speechSynthesis?.cancel()
})
</script>

<template>
  <span class="lesson-tts">
    <span ref="text"><slot /></span>
    <button
      type="button"
      class="lesson-audio"
      :class="{ playing: speaking }"
      title="Speak"
      :aria-label="speaking ? 'Stop speaking' : 'Speak'"
      @click="toggle"
    >
      {{ speaking ? '■' : '▶' }}
    </button>
  </span>
</template>
