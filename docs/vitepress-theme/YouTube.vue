<script setup>
// <YouTube id="..." />, <YouTube list="..." /> or <YouTube src="..." />:
// an embedded player.
import { computed } from 'vue'

const props = defineProps({
  id: String,
  videoId: String,
  video_id: String,
  list: String,
  src: String,
})

// The same rules as the app: `id` (or `video-id`, `video_id`), `list`, and
// `src` holding a video id or any YouTube link.
const embedUrl = computed(() => {
  let video = props.id || props.videoId || props.video_id
  let list = props.list
  if (props.src) {
    let url = null
    try {
      url = new URL(props.src)
    } catch {
      video ||= props.src
    }
    if (url) {
      const path = url.pathname.split('/').filter(Boolean)
      list ||= url.searchParams.get('list')
      if (url.hostname.includes('youtu.be')) video ||= path[0]
      else if (path[0] === 'embed') video ||= path[1]
      else video ||= url.searchParams.get('v')
    }
  }
  if (video === 'videoseries') video = null
  if (!video && !list) return null
  const embed = new URL(
    `https://www.youtube-nocookie.com/embed/${video || 'videoseries'}`,
  )
  if (list) embed.searchParams.set('list', list)
  return embed.href
})
</script>

<template>
  <div v-if="embedUrl" class="lesson-youtube">
    <iframe
      :src="embedUrl"
      title="YouTube video"
      loading="lazy"
      allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share"
      referrerpolicy="strict-origin-when-cross-origin"
      allowfullscreen
    />
  </div>
</template>
