<script setup>
import { computed, onBeforeUnmount, onMounted } from 'vue'
import { ChevronLeft, ChevronRight, Download, X } from 'lucide-vue-next'
import { contentUrl } from '../api'
import { previewClosed, previewOpened } from '../previewHistory'
import { PREVIEWABLE, formatSize } from '../format'
import FileContent from './FileContent.vue'
import FileIcon from './FileIcon.vue'

// urlFor(id, download) builds file URLs; share links use their own endpoints.
const props = defineProps({ node: Object, siblings: Array, urlFor: { type: Function, default: contentUrl } })
const emit = defineEmits(['close', 'navigate'])

const url = computed(() => props.urlFor(props.node.id))
const previewable = computed(() => props.siblings.filter((n) => PREVIEWABLE.has(n.kind)))
const index = computed(() => previewable.value.findIndex((n) => n.id === props.node.id))

function step(delta) {
  const list = previewable.value
  if (list.length < 2) return
  emit('navigate', list[(index.value + delta + list.length) % list.length])
}

function onKey(e) {
  if (e.key === 'Escape') emit('close')
  else if (e.target.tagName === 'VIDEO' || e.target.tagName === 'AUDIO') return
  else if (e.key === 'ArrowLeft') step(-1)
  else if (e.key === 'ArrowRight') step(1)
}
onMounted(() => {
  window.addEventListener('keydown', onKey)
  previewOpened(() => emit('close')) // the browser's Back button closes the preview
})
onBeforeUnmount(() => {
  window.removeEventListener('keydown', onKey)
  previewClosed()
})
</script>

<template>
  <div class="keep-colors fixed inset-0 z-50 flex flex-col bg-slate-950/90 text-white">
    <header class="flex items-center gap-3 px-4 py-3">
      <FileIcon :kind="node.kind" />
      <div class="min-w-0 flex-1">
        <div class="truncate font-medium">{{ node.name }}</div>
        <div class="text-xs text-slate-400">{{ formatSize(node.size) }}</div>
      </div>
      <a :href="urlFor(node.id, true)" class="btn text-white hover:bg-white/10" title="Download">
        <Download :size="18" /> <span class="hidden sm:inline">Download</span>
      </a>
      <button class="rounded-md p-2 hover:bg-white/10" title="Close (Esc)" @click="emit('close')">
        <X :size="20" />
      </button>
    </header>

    <main class="relative flex min-h-0 flex-1 items-center justify-center px-4 pb-4 sm:px-16" @click.self="emit('close')">
      <button
        v-if="previewable.length > 1"
        class="absolute left-2 z-10 rounded-full bg-white/10 p-2 hover:bg-white/20"
        title="Previous (←)"
        @click="step(-1)"
      >
        <ChevronLeft :size="22" />
      </button>

      <FileContent :node="node" :url="url" :download-url="urlFor(node.id, true)" dark autoplay />

      <button
        v-if="previewable.length > 1"
        class="absolute right-2 z-10 rounded-full bg-white/10 p-2 hover:bg-white/20"
        title="Next (→)"
        @click="step(1)"
      >
        <ChevronRight :size="22" />
      </button>
    </main>
  </div>
</template>
