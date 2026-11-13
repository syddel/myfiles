<script setup>
import { computed } from 'vue'
import { File, FileArchive, FileImage, FileMusic, FileText, FilePlay, Folder } from 'lucide-vue-next'
import { prefs } from '../prefs'
import { FOLDER_COLORS } from '../utils'

const props = defineProps({ kind: String, size: { type: Number, default: 20 } })

const ICONS = {
  folder: [Folder, ''], // colored with the user's chosen folder color
  pdf: [FileText, 'text-red-500'],
  image: [FileImage, 'text-emerald-600'],
  audio: [FileMusic, 'text-purple-500'],
  video: [FilePlay, 'text-rose-500'],
  text: [FileText, 'text-slate-500'],
  archive: [FileArchive, 'text-orange-600'],
  other: [File, 'text-slate-400'],
}
const icon = computed(() => {
  if (props.kind === 'folder') return [Folder, (FOLDER_COLORS[prefs.folderColor] ?? FOLDER_COLORS.amber).icon]
  return ICONS[props.kind] ?? ICONS.other
})
</script>

<template>
  <component :is="icon[0]" :size="size" :class="icon[1]" class="shrink-0" stroke-width="1.75" />
</template>
