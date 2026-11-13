<script setup>
import { computed, ref, watch } from 'vue'
import { Check, ChevronDown, ChevronUp, CircleAlert, X } from 'lucide-vue-next'
import { cancelAll, cancelUpload, clearFinished, uploads } from '../uploads'
import { formatSize } from '../format'

const collapsed = ref(false)

const pending = computed(() => uploads.items.filter((i) => i.status === 'queued' || i.status === 'uploading'))
const failed = computed(() => uploads.items.filter((i) => i.status === 'error'))
const totals = computed(() => {
  let size = 0
  let loaded = 0
  for (const i of uploads.items) {
    if (i.status === 'cancelled') continue
    size += i.size
    loaded += i.status === 'error' ? i.size : i.loaded
  }
  return { size, loaded, percent: size ? Math.round((loaded / size) * 100) : 100 }
})
const title = computed(() => {
  if (pending.value.length) return `Uploading ${pending.value.length} ${pending.value.length === 1 ? 'file' : 'files'}… ${totals.value.percent}%`
  if (failed.value.length) return `${failed.value.length} upload${failed.value.length === 1 ? '' : 's'} failed`
  return 'Uploads complete'
})

// Hide the panel a few seconds after everything uploaded successfully.
let hideTimer = null
watch(
  () => pending.value.length === 0 && failed.value.length === 0 && uploads.items.some((i) => i.status === 'done'),
  (allDone) => {
    clearTimeout(hideTimer)
    if (allDone) hideTimer = setTimeout(clearFinished, 5000)
  },
)

function percent(item) {
  return item.size ? Math.min(100, Math.round((item.loaded / item.size) * 100)) : 100
}

function close() {
  cancelAll()
  clearFinished()
}
</script>

<template>
  <div
    v-if="uploads.items.length"
    class="fixed right-4 bottom-4 z-40 w-[calc(100%-2rem)] max-w-sm overflow-hidden rounded-xl border border-slate-200 bg-surface shadow-xl"
  >
    <div class="keep-colors flex items-center gap-2 bg-slate-800 px-4 py-2.5 text-sm text-white">
      <span class="flex-1 truncate">{{ title }}</span>
      <button class="rounded p-1 hover:bg-white/10" @click="collapsed = !collapsed">
        <ChevronUp v-if="collapsed" :size="16" />
        <ChevronDown v-else :size="16" />
      </button>
      <button class="rounded p-1 hover:bg-white/10" :title="pending.length ? 'Cancel all' : 'Close'" @click="close">
        <X :size="16" />
      </button>
    </div>
    <div v-if="pending.length" class="h-1 bg-slate-200">
      <div class="h-full bg-blue-600 transition-all" :style="{ width: totals.percent + '%' }" />
    </div>
    <ul v-if="!collapsed" class="max-h-72 divide-y divide-slate-100 overflow-auto">
      <li v-for="item in uploads.items" :key="item.id" class="px-4 py-2 text-sm">
        <div class="flex items-center gap-2">
          <span class="min-w-0 flex-1 truncate" :title="item.name">{{ item.name }}</span>
          <Check v-if="item.status === 'done'" :size="16" class="shrink-0 text-green-600" />
          <CircleAlert v-else-if="item.status === 'error'" :size="16" class="shrink-0 text-red-600" />
          <span v-else-if="item.status === 'cancelled'" class="text-xs text-slate-400">Cancelled</span>
          <button
            v-else
            class="shrink-0 rounded p-0.5 text-slate-400 hover:bg-slate-100 hover:text-slate-700"
            title="Cancel"
            @click="cancelUpload(item)"
          >
            <X :size="14" />
          </button>
        </div>
        <div v-if="item.status === 'uploading' || item.status === 'queued'" class="mt-1.5 flex items-center gap-2">
          <div class="h-1.5 flex-1 overflow-hidden rounded-full bg-slate-200">
            <div class="h-full rounded-full bg-blue-600 transition-all" :style="{ width: percent(item) + '%' }" />
          </div>
          <span class="w-28 text-right text-xs text-slate-500 tabular-nums">
            {{ item.status === 'queued' ? 'Waiting' : `${formatSize(item.loaded)} / ${formatSize(item.size)}` }}
          </span>
        </div>
        <p v-if="item.status === 'error'" class="mt-0.5 text-xs text-red-600">{{ item.error }}</p>
      </li>
    </ul>
  </div>
</template>
