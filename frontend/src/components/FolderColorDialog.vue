<script setup>
import { Check, Folder } from 'lucide-vue-next'
import { prefs, savePrefs } from '../prefs'
import { FOLDER_COLORS } from '../utils'
import Modal from './Modal.vue'

const emit = defineEmits(['close'])

// Applied immediately so every folder icon updates while the dialog is open.
function choose(key) {
  const previous = prefs.folderColor
  if (key === previous) return
  prefs.folderColor = key
  savePrefs({ folder_color: key }, () => (prefs.folderColor = previous))
}
</script>

<template>
  <Modal title="Folder color" @close="emit('close')">
    <p class="mb-3 text-sm text-slate-600">Choose the color of your folder icons.</p>
    <div class="grid grid-cols-5 gap-2">
      <button
        v-for="(color, key) in FOLDER_COLORS"
        :key="key"
        class="relative flex cursor-pointer flex-col items-center gap-1 rounded-lg border p-2 text-xs"
        :class="prefs.folderColor === key ? 'border-blue-500 bg-blue-50' : 'border-transparent hover:bg-slate-100'"
        :title="color.label"
        :aria-pressed="prefs.folderColor === key"
        @click="choose(key)"
      >
        <Folder :size="28" :class="color.icon" stroke-width="1.75" />
        <span class="text-slate-600">{{ color.label }}</span>
        <Check v-if="prefs.folderColor === key" :size="14" class="absolute top-1 right-1 text-blue-600" />
      </button>
    </div>
    <template #footer>
      <button class="btn btn-primary" @click="emit('close')">Done</button>
    </template>
  </Modal>
</template>
