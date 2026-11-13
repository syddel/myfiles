<script setup>
import { computed, onMounted, reactive, ref } from 'vue'
import { ChevronDown, ChevronRight } from 'lucide-vue-next'
import { api } from '../api'
import FileIcon from './FileIcon.vue'
import Modal from './Modal.vue'

// Also used as a plain folder picker: pass title/confirmText and no nodes.
const props = defineProps({
  nodes: { type: Array, default: () => [] },
  currentFolderId: Number,
  title: String,
  confirmText: { type: String, default: 'Move here' },
})
const emit = defineEmits(['close', 'move'])

const folders = ref([])
const expanded = reactive(new Set())
const selected = ref(null)
const movingIds = computed(() => new Set(props.nodes.map((n) => n.id)))

onMounted(async () => {
  folders.value = await api.allFolders()
  const byId = new Map(folders.value.map((f) => [f.id, f]))
  // Open the tree down to the folder the user is currently in.
  for (let f = byId.get(props.currentFolderId); f; f = byId.get(f.parent_id)) expanded.add(f.id)
  expanded.add(folders.value.find((f) => f.parent_id === null)?.id)
})

const children = computed(() => {
  const map = new Map()
  for (const f of folders.value) {
    if (!map.has(f.parent_id)) map.set(f.parent_id, [])
    map.get(f.parent_id).push(f)
  }
  for (const list of map.values()) list.sort((a, b) => a.name.localeCompare(b.name))
  return map
})

// Visible rows of the tree; folders being moved (and their contents) are hidden.
const rows = computed(() => {
  const out = []
  const walk = (parentId, depth) => {
    for (const f of children.value.get(parentId) ?? []) {
      if (movingIds.value.has(f.id)) continue
      out.push({ folder: f, depth, hasChildren: children.value.has(f.id) })
      if (expanded.has(f.id)) walk(f.id, depth + 1)
    }
  }
  walk(null, 0)
  return out
})

function toggle(id) {
  expanded.has(id) ? expanded.delete(id) : expanded.add(id)
}

const title = computed(() =>
  props.title ?? (props.nodes.length === 1 ? `Move "${props.nodes[0].name}"` : `Move ${props.nodes.length} items`),
)

function choose(id) {
  emit('move', id, folders.value.find((f) => f.id === id))
}
</script>

<template>
  <Modal :title="title" wide @close="emit('close')">
    <div class="h-72 overflow-auto rounded-md border border-slate-200 py-1">
      <div
        v-for="{ folder, depth, hasChildren } in rows"
        :key="folder.id"
        class="flex cursor-pointer items-center gap-1 py-1 pr-2 text-sm select-none"
        :class="selected === folder.id ? 'bg-blue-100 text-blue-900 dark:text-blue-50' : 'hover:bg-slate-100'"
        :style="{ paddingLeft: `${depth * 18 + 4}px` }"
        @click="selected = folder.id"
        @dblclick="choose(folder.id)"
      >
        <button
          class="rounded p-0.5 text-slate-400 hover:text-slate-700"
          :class="{ invisible: !hasChildren }"
          @click.stop="toggle(folder.id)"
        >
          <ChevronDown v-if="expanded.has(folder.id)" :size="14" />
          <ChevronRight v-else :size="14" />
        </button>
        <FileIcon kind="folder" :size="16" />
        <span class="truncate">{{ folder.name }}</span>
        <span v-if="folder.id === currentFolderId" class="ml-auto text-xs text-slate-400">current</span>
      </div>
    </div>
    <template #footer>
      <button class="btn btn-ghost" @click="emit('close')">Cancel</button>
      <button class="btn btn-primary" :disabled="selected === null" @click="choose(selected)">{{ confirmText }}</button>
    </template>
  </Modal>
</template>
