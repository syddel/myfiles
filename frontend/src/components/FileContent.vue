<script setup>
// Shows a file's content in the browser: image, video, audio, PDF or text.
// Used by the preview dialog and by the page for a shared file.
import { ref, watch } from 'vue'
import { Download } from 'lucide-vue-next'
import FileIcon from './FileIcon.vue'

// Show at most this much of a text file.
const TEXT_LIMIT = 1024 * 1024

const props = defineProps({
  node: Object,
  url: String,
  downloadUrl: String,
  dark: Boolean, // light-on-dark styling for the full-screen preview
  autoplay: Boolean,
})

const text = ref('')
const textTruncated = ref(false)
const textError = ref('')

async function loadText() {
  text.value = ''
  textError.value = ''
  textTruncated.value = props.node.size > TEXT_LIMIT
  try {
    const res = await fetch(props.url, { headers: { Range: `bytes=0-${TEXT_LIMIT - 1}` } })
    if (!res.ok) throw new Error(res.statusText)
    text.value = new TextDecoder('utf-8').decode(await res.arrayBuffer())
  } catch (e) {
    textError.value = `Couldn't load file: ${e.message}`
  }
}

watch(() => props.node.id, () => props.node.kind === 'text' && loadText(), { immediate: true })
</script>

<template>
  <img v-if="node.kind === 'image'" :key="node.id" :src="url" :alt="node.name" class="max-h-full max-w-full object-contain" />
  <video v-else-if="node.kind === 'video'" :key="node.id" :src="url" controls :autoplay="autoplay" class="max-h-full max-w-full" />
  <div
    v-else-if="node.kind === 'audio'"
    :key="node.id"
    class="w-full max-w-lg rounded-xl p-8 text-center"
    :class="dark ? 'bg-white/5' : 'border border-slate-200 bg-slate-50'"
  >
    <FileIcon kind="audio" :size="64" class="mx-auto mb-6" />
    <audio :src="url" controls :autoplay="autoplay" class="w-full" />
  </div>
  <iframe v-else-if="node.kind === 'pdf'" :key="node.id" :src="url" class="h-full w-full max-w-5xl rounded border-0 bg-white" />
  <div
    v-else-if="node.kind === 'text'"
    class="keep-colors flex h-full w-full max-w-5xl flex-col overflow-hidden rounded bg-surface text-slate-800 dark:bg-slate-950 dark:text-slate-200"
    :class="{ 'border border-slate-200 dark:border-slate-700': !dark }"
  >
    <!-- keep-colors + explicit dark: colors give the same readable panel whether it's
         shown in the (always-dark) preview window or on a shared-file page. -->
    <p v-if="textTruncated" class="bg-amber-50 px-4 py-2 text-xs text-amber-800 dark:text-amber-200">
      Showing the first 1 MB only. Download the file to see all of it.
    </p>
    <p v-if="textError" class="p-4 text-sm text-red-600">{{ textError }}</p>
    <pre class="flex-1 overflow-auto p-4 font-mono text-[13px] leading-relaxed whitespace-pre-wrap">{{ text }}</pre>
  </div>
  <div v-else class="text-center">
    <FileIcon :kind="node.kind" :size="64" class="mx-auto mb-4" />
    <p class="mb-4" :class="dark ? 'text-slate-300' : 'text-slate-500'">No preview available for this file type.</p>
    <a :href="downloadUrl" class="btn btn-primary"><Download :size="16" /> Download</a>
  </div>
</template>
