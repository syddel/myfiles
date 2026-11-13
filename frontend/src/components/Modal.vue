<script setup>
import { onBeforeUnmount, onMounted } from 'vue'
import { X } from 'lucide-vue-next'

defineProps({ title: String, wide: Boolean })
const emit = defineEmits(['close'])

function onKey(e) {
  if (e.key === 'Escape') emit('close')
}
onMounted(() => window.addEventListener('keydown', onKey))
onBeforeUnmount(() => window.removeEventListener('keydown', onKey))
</script>

<template>
  <div class="fixed inset-0 z-50 flex items-center justify-center bg-slate-950/50 p-4" @mousedown.self="emit('close')">
    <div class="flex max-h-full w-full flex-col rounded-xl bg-surface shadow-xl" :class="wide ? 'max-w-lg' : 'max-w-sm'">
      <div class="flex items-center justify-between border-b border-slate-100 px-5 py-3">
        <h2 class="font-medium">{{ title }}</h2>
        <button class="rounded p-1 text-slate-400 hover:bg-slate-100 hover:text-slate-700" @click="emit('close')">
          <X :size="18" />
        </button>
      </div>
      <div class="overflow-auto px-5 py-4"><slot /></div>
      <div v-if="$slots.footer" class="flex justify-end gap-2 border-t border-slate-100 px-5 py-3">
        <slot name="footer" />
      </div>
    </div>
  </div>
</template>
