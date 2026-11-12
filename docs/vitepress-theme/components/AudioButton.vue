<script setup>
// <AudioButton src="..." />: a button that plays an audio file.
import { onBeforeUnmount, ref } from 'vue'
import { withBase } from 'vitepress'

const props = defineProps({
  src: { type: String, required: true },
})

const playing = ref(false)
const failed = ref(false)
let audio

function toggle() {
  if (playing.value) {
    audio.pause()
    playing.value = false
    return
  }
  if (!audio) {
    // `/audio/a.mp3` is a file in `public/`; a full URL is used as it is.
    audio = new Audio(withBase(props.src))
    audio.addEventListener('ended', () => (playing.value = false))
    audio.addEventListener('error', () => {
      playing.value = false
      failed.value = true
    })
  }
  failed.value = false
  audio.currentTime = 0
  audio.play().then(
    () => (playing.value = true),
    () => (failed.value = true),
  )
}

onBeforeUnmount(() => audio?.pause())
</script>

<template>
  <button
    type="button"
    class="lesson-audio"
    :class="{ playing, failed }"
    :title="failed ? `Cannot play ${src}` : 'Play audio'"
    :aria-label="playing ? 'Stop audio' : 'Play audio'"
    @click="toggle"
  >
    {{ failed ? '⚠' : playing ? '■' : '▶' }}
  </button>
</template>
