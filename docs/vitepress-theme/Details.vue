<script setup>
// <Details summary="...">...</Details>: the app shows the summary in bold
// and the content under it, always open.
defineProps({
  summary: String,
  title: String,
})
</script>

<template>
  <div class="lesson-details">
    <p v-if="summary || title">
      <strong>{{ summary || title }}</strong>
    </p>
    <slot />
  </div>
</template>
