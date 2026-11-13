<script setup>
import { computed, onBeforeUnmount, onMounted, reactive, ref, watch } from 'vue'
import {
  ArrowDown, ArrowUp, ChevronRight, CloudUpload, CornerLeftUp, Link2, Share2, ShieldCheck, Download, EllipsisVertical, Eye, FolderInput,
  FolderPlus, FolderUp, KeyRound, LogOut, Monitor, Moon, Pencil, Search, Sun, Trash2, Upload, User, X,
} from 'lucide-vue-next'
import { api, contentUrl, zipUrl } from '../api'
import { prefs, savePrefs, setTheme } from '../prefs'
import { formatDate, formatSize, typeLabel } from '../format'
import { toast } from '../toast'
import { enqueueUploads, filesFromDrop, filesFromInput, onUploadFinished, uploads } from '../uploads'
import ConfirmDialog from './ConfirmDialog.vue'
import FileIcon from './FileIcon.vue'
import FolderColorDialog from './FolderColorDialog.vue'
import MoveDialog from './MoveDialog.vue'
import PasswordDialog from './PasswordDialog.vue'
import PreviewDialog from './PreviewDialog.vue'
import PromptDialog from './PromptDialog.vue'
import ShareDialog from './ShareDialog.vue'
import SharesView from './SharesView.vue'
import AdminView from './AdminView.vue'
import UploadPanel from './UploadPanel.vue'
import { ROOT_NAME } from '../utils'

const props = defineProps({ user: Object, config: Object })
const emit = defineEmits(['logout'])

// ------------------------------------------------------------ navigation

function folderFromHash() {
  const m = location.hash.match(/^#\/folder\/(\d+)/)
  return m ? Number(m[1]) : props.user.root_id
}

// '#/shared' shows the list of shared folders instead of the file list.
// '#/shared' and '#/admin' show those pages instead of the file list.
function pageFromHash() {
  if (location.hash === '#/shared') return 'shares'
  if (location.hash === '#/admin' && props.user.is_admin) return 'admin'
  return 'files'
}
const page = ref(pageFromHash())
const folderId = ref(folderFromHash())
const folder = ref(null)
const breadcrumb = ref([])
const items = ref([])
const loading = ref(true)

function navigate(id) {
  query.value = ''
  location.hash = id === props.user.root_id ? '#/' : `#/folder/${id}`
}

function onHashChange() {
  const previous = page.value
  page.value = pageFromHash()
  if (page.value !== 'files') {
    selection.clear()
    menu.value = null
  }
  const id = folderFromHash()
  // Coming back from the shares page to the same folder: reload so share icons are current.
  if (previous !== 'files' && page.value === 'files' && id === folderId.value) {
    loadFolder()
    loadStats() // an admin may have changed quotas
  }
  folderId.value = id
}

// The first folder opened after sign-in comes from the address, which may be a
// bookmark or another user's folder (e.g. their session expired and someone else
// signed in). If it isn't available, just start at Home without an error.
let firstLoad = true

async function loadFolder() {
  const quiet = firstLoad
  firstLoad = false
  try {
    const data = await api.folder(folderId.value)
    folder.value = data.folder
    breadcrumb.value = data.breadcrumb
    items.value = data.items
  } catch (e) {
    if (e.status === 404 && folderId.value !== props.user.root_id) {
      if (!quiet) toast("That folder doesn't exist any more", 'error')
      navigate(props.user.root_id)
    } else toast(e.message, 'error')
  } finally {
    loading.value = false
  }
}

watch(folderId, () => {
  selection.clear()
  loadFolder()
})

// Folder one level up, shown as the ".." row; null in the root folder.
const parentCrumb = computed(() => (breadcrumb.value.length > 1 ? breadcrumb.value.at(-2) : null))

// ------------------------------------------------------------ theme

const THEME_OPTIONS = [
  { key: 'light', label: 'Light', icon: Sun },
  { key: 'dark', label: 'Dark', icon: Moon },
  { key: 'system', label: 'System', icon: Monitor },
]

function chooseTheme(theme) {
  const previous = prefs.theme
  if (theme === previous) return
  setTheme(theme)
  savePrefs({ theme }, () => setTheme(previous))
}

// ------------------------------------------------------------ search

const query = ref('')
const searchResults = ref([])
const searching = computed(() => query.value.trim() !== '')
let searchTimer = null

watch(query, () => {
  clearTimeout(searchTimer)
  selection.clear()
  if (!searching.value) return
  // Searching from the shares page switches back to the file list (keeping the query).
  if (page.value === 'shares') location.hash = folderId.value === props.user.root_id ? '#/' : `#/folder/${folderId.value}`
  searchTimer = setTimeout(runSearch, 200)
})

async function runSearch() {
  if (!searching.value) return
  const q = query.value
  const results = await api.search(q).catch((e) => (toast(e.message, 'error'), []))
  if (q === query.value) searchResults.value = results
}

// ------------------------------------------------------------ stats

const stats = ref(null)
async function loadStats() {
  stats.value = await api.stats().catch(() => null)
}

async function refresh() {
  await Promise.all([loadFolder(), searching.value ? runSearch() : null, loadStats()])
  // Drop selected ids that no longer exist.
  const ids = new Set(rows.value.map((n) => n.id))
  for (const id of [...selection]) if (!ids.has(id)) selection.delete(id)
}

// ------------------------------------------------------------ sorting

const sort = reactive({ key: 'name', dir: 1 })
const collator = new Intl.Collator(undefined, { numeric: true, sensitivity: 'base' })

function setSort(key) {
  if (sort.key === key) sort.dir = -sort.dir
  else Object.assign(sort, { key, dir: 1 })
}

const rows = computed(() => {
  const list = [...(searching.value ? searchResults.value : items.value)]
  const cmp = {
    name: (a, b) => collator.compare(a.name, b.name),
    updated_at: (a, b) => a.updated_at.localeCompare(b.updated_at),
    size: (a, b) => a.size - b.size,
    type: (a, b) => collator.compare(typeLabel(a), typeLabel(b)) || collator.compare(a.name, b.name),
  }[sort.key]
  return list.sort((a, b) => (b.is_dir - a.is_dir) || sort.dir * cmp(a, b))
})

// ------------------------------------------------------------ selection

const selection = reactive(new Set())
let anchorId = null

const selectedNodes = computed(() => rows.value.filter((n) => selection.has(n.id)))
const allSelected = computed(() => rows.value.length > 0 && selection.size === rows.value.length)

function onRowClick(e, node) {
  if (e.shiftKey && anchorId !== null) {
    const ids = rows.value.map((n) => n.id)
    const [a, b] = [ids.indexOf(anchorId), ids.indexOf(node.id)].sort((x, y) => x - y)
    if (!(e.ctrlKey || e.metaKey)) selection.clear()
    ids.slice(a, b + 1).forEach((id) => selection.add(id))
    return
  }
  if (e.ctrlKey || e.metaKey) toggleSelected(node)
  else {
    selection.clear()
    selection.add(node.id)
  }
  anchorId = node.id
}

function toggleSelected(node) {
  selection.has(node.id) ? selection.delete(node.id) : selection.add(node.id)
  anchorId = node.id
}

function toggleAll() {
  if (allSelected.value) selection.clear()
  else rows.value.forEach((n) => selection.add(n.id))
}

// ------------------------------------------------------------ actions

const dialog = ref(null) // { type: 'new-folder' | 'rename' | 'delete' | 'move' | 'password', nodes? }
const preview = ref(null)

function open(node) {
  if (node.is_dir) navigate(node.id)
  else preview.value = node
}

async function createFolder(name) {
  try {
    await api.createFolder(folderId.value, name)
    dialog.value = null
    await refresh()
  } catch (e) {
    toast(e.message, 'error')
  }
}

async function rename(node, name) {
  try {
    await api.rename(node.id, name)
    dialog.value = null
    await refresh()
  } catch (e) {
    toast(e.message, 'error')
  }
}

async function moveNodes(nodes, targetId) {
  const ids = nodes.map((n) => n.id).filter((id) => id !== targetId)
  if (!ids.length) return
  try {
    await api.move(ids, targetId)
    dialog.value = null
    toast(ids.length === 1 ? `Moved "${nodes.find((n) => n.id === ids[0]).name}"` : `Moved ${ids.length} items`)
    await refresh()
  } catch (e) {
    toast(e.message, 'error')
  }
}

async function deleteNodes(nodes) {
  try {
    await api.remove(nodes.map((n) => n.id))
    dialog.value = null
    toast(nodes.length === 1 ? `Deleted "${nodes[0].name}"` : `Deleted ${nodes.length} items`)
    await refresh()
  } catch (e) {
    toast(e.message, 'error')
  }
}

// One file downloads as itself; folders and multiple items come as one zip.
function download(nodes) {
  if (!nodes.length) return
  const single = nodes.length === 1 && !nodes[0].is_dir
  const a = document.createElement('a')
  a.href = single ? contentUrl(nodes[0].id, true) : zipUrl(nodes.map((n) => n.id))
  if (single) a.download = nodes[0].name
  document.body.appendChild(a)
  a.click()
  a.remove()
  if (!single) toast('Preparing zip download…')
}

const deleteMessage = computed(() => {
  const nodes = dialog.value?.nodes ?? []
  const what = nodes.length === 1 ? `"${nodes[0].name}"` : `these ${nodes.length} items`
  return nodes.some((n) => n.is_dir)
    ? `Delete ${what}? Folders are deleted with everything inside them. This can’t be undone.`
    : `Delete ${what}? This can’t be undone.`
})

// ------------------------------------------------------------ context menu

const menu = ref(null) // { x, y, nodes }

function openMenu(e, node) {
  if (!selection.has(node.id)) {
    selection.clear()
    selection.add(node.id)
    anchorId = node.id
  }
  const r = e.type === 'contextmenu' ? { x: e.clientX, y: e.clientY } : e.currentTarget.getBoundingClientRect()
  const x = Math.min(r.x ?? r.left, window.innerWidth - 200)
  const y = Math.min((r.y ?? r.top) + (e.type === 'contextmenu' ? 0 : r.height), window.innerHeight - 240)
  menu.value = { x, y, nodes: selectedNodes.value }
}

function menuAction(action) {
  const nodes = menu.value.nodes
  menu.value = null
  if (action === 'open') open(nodes[0])
  else if (action === 'share') dialog.value = { type: 'share', node: nodes[0] }
  else if (action === 'download') download(nodes)
  else if (action === 'rename') dialog.value = { type: 'rename', nodes }
  else dialog.value = { type: action, nodes }
}

// ------------------------------------------------------------ uploads

const fileInput = ref(null)
const folderInput = ref(null)
const uploadMenu = ref(false)
const userMenu = ref(false)

function upload(entries) {
  if (!entries.length) return
  const max = props.config.max_upload_bytes
  const tooBig = max ? entries.filter((e) => e.file.size > max) : []
  if (tooBig.length) toast(`${tooBig.length} file(s) exceed the ${formatSize(max)} limit and were skipped`, 'error')
  const accepted = entries.filter((e) => !tooBig.includes(e))

  // Check the quota before sending anything (the server checks again, too).
  const quota = stats.value?.quota_bytes
  if (quota != null && accepted.length) {
    const pending = uploads.items
      .filter((i) => (i.status === 'queued' || i.status === 'uploading') && i.endpoint === 'api/upload')
      .reduce((total, i) => total + i.size - i.loaded, 0)
    const left = Math.max(quota - stats.value.used_bytes - pending, 0)
    const needed = accepted.reduce((total, e) => total + e.file.size, 0)
    if (needed > left) {
      toast(`Not enough space: ${formatSize(needed)} needed, but only ${formatSize(left)} of your ${formatSize(quota)} quota is left`, 'error')
      return
    }
  }
  enqueueUploads(accepted, folderId.value)
}

const quotaPercent = computed(() => {
  const s = stats.value
  return s && s.quota_bytes ? Math.min(100, (s.used_bytes / s.quota_bytes) * 100) : 0
})

function onFilesChosen(e) {
  upload(filesFromInput(e.target.files))
  e.target.value = ''
}

let refreshTimer = null
const stopListening = onUploadFinished(() => {
  clearTimeout(refreshTimer)
  refreshTimer = setTimeout(refresh, 300)
})

// ------------------------------------------------------------ drag and drop

const DRAG_TYPE = 'application/x-myfiles-ids'
const externalDrag = ref(false)
const dropTarget = ref(null)
let dragDepth = 0

function isExternal(e) {
  return e.dataTransfer.types.includes('Files') && !e.dataTransfer.types.includes(DRAG_TYPE)
}

function onRowDragStart(e, node) {
  if (!selection.has(node.id)) {
    selection.clear()
    selection.add(node.id)
  }
  e.dataTransfer.effectAllowed = 'move'
  e.dataTransfer.setData(DRAG_TYPE, JSON.stringify([...selection]))
}

function onFolderDragOver(e, targetId) {
  if (!e.dataTransfer.types.includes(DRAG_TYPE) || selection.has(targetId)) return
  e.preventDefault()
  e.stopPropagation()
  e.dataTransfer.dropEffect = 'move'
  dropTarget.value = targetId
}

function onFolderDrop(e, targetId) {
  if (!e.dataTransfer.types.includes(DRAG_TYPE)) return
  e.preventDefault()
  e.stopPropagation()
  dropTarget.value = null
  const ids = new Set(JSON.parse(e.dataTransfer.getData(DRAG_TYPE)))
  moveNodes(rows.value.filter((n) => ids.has(n.id)), targetId)
}

function onAreaDragEnter(e) {
  if (!isExternal(e)) return
  dragDepth++
  externalDrag.value = true
}

function onAreaDragLeave(e) {
  if (!isExternal(e)) return
  if (--dragDepth <= 0) {
    dragDepth = 0
    externalDrag.value = false
  }
}

function onAreaDragOver(e) {
  if (isExternal(e)) {
    e.preventDefault()
    e.dataTransfer.dropEffect = 'copy'
  }
}

async function onAreaDrop(e) {
  dragDepth = 0
  externalDrag.value = false
  if (!isExternal(e)) return
  e.preventDefault()
  upload(await filesFromDrop(e.dataTransfer))
}

// ------------------------------------------------------------ keyboard

function onKeyDown(e) {
  // Escape closes any open menu (account, upload, right-click), on every page.
  if (e.key === 'Escape' && (userMenu.value || uploadMenu.value || menu.value)) {
    closeMenus()
    return
  }
  if (dialog.value || preview.value || page.value !== 'files') return
  if (['INPUT', 'TEXTAREA'].includes(e.target.tagName)) {
    if (e.key === 'Escape') e.target.blur()
    return
  }
  const nodes = selectedNodes.value
  if (e.key === 'Escape') {
    menu.value = null
    selection.clear()
  } else if ((e.ctrlKey || e.metaKey) && e.key === 'a') {
    e.preventDefault()
    rows.value.forEach((n) => selection.add(n.id))
  } else if (e.key === 'Delete' && nodes.length) {
    dialog.value = { type: 'delete', nodes }
  } else if (e.key === 'F2' && nodes.length === 1) {
    e.preventDefault()
    dialog.value = { type: 'rename', nodes }
  } else if (e.key === 'Enter' && nodes.length === 1) {
    open(nodes[0])
  } else if (e.key === 'Backspace' && !searching.value && breadcrumb.value.length > 1) {
    navigate(breadcrumb.value.at(-2).id)
  } else if (e.key === '/') {
    e.preventDefault()
    document.getElementById('search')?.focus()
  }
}

function closeMenus() {
  menu.value = null
  uploadMenu.value = false
  userMenu.value = false
}

onMounted(() => {
  window.addEventListener('hashchange', onHashChange)
  window.addEventListener('keydown', onKeyDown)
  window.addEventListener('click', closeMenus)
  loadFolder()
  loadStats()
})

onBeforeUnmount(() => {
  window.removeEventListener('hashchange', onHashChange)
  window.removeEventListener('keydown', onKeyDown)
  window.removeEventListener('click', closeMenus)
  stopListening()
})

const statusText = computed(() => {
  const n = rows.value.length
  let s = `${n} item${n === 1 ? '' : 's'}`
  if (searching.value) s += ' found'
  if (selection.size) {
    const size = selectedNodes.value.reduce((t, x) => t + (x.is_dir ? 0 : x.size), 0)
    s += ` · ${selection.size} selected${size ? ` (${formatSize(size)})` : ''}`
  }
  return s
})
</script>

<template>
  <div class="flex h-full flex-col">
    <!-- Header -->
    <header class="flex items-center gap-3 border-b border-slate-200 px-3 py-2 sm:gap-6 sm:px-5">
      <a href="#/" class="flex shrink-0 items-center gap-2 text-lg font-semibold" @click="query = ''">
        <img :src="'favicon.svg'" class="h-7 w-7" alt="" />
        <span class="hidden max-w-60 truncate sm:block">{{ config.app_name }}</span>
      </a>
      <div class="relative max-w-2xl flex-1">
        <Search :size="18" class="pointer-events-none absolute top-1/2 left-3 -translate-y-1/2 text-slate-400" />
        <input
          id="search"
          v-model="query"
          type="text"
          placeholder="Search files and folders"
          autocomplete="off"
          class="w-full rounded-full border border-transparent bg-slate-100 py-2 pr-9 pl-10 text-sm outline-none focus:border-blue-500 focus:bg-surface focus:ring-2 focus:ring-blue-500/20"
        />
        <button
          v-if="query"
          class="absolute top-1/2 right-2 -translate-y-1/2 rounded-full p-1 text-slate-400 hover:bg-slate-200 hover:text-slate-700"
          title="Clear search"
          @click="query = ''"
        >
          <X :size="16" />
        </button>
      </div>
      <a
        href="#/shared"
        class="btn ml-auto shrink-0"
        :class="page === 'shares' ? 'bg-blue-50 text-blue-700 dark:text-blue-200' : 'btn-ghost'"
        title="Shared folders and files"
      >
        <Link2 :size="16" /><span class="hidden md:inline">Shared</span>
      </a>
      <a
        v-if="user.is_admin"
        href="#/admin"
        class="btn shrink-0"
        :class="page === 'admin' ? 'bg-blue-50 text-blue-700 dark:text-blue-200' : 'btn-ghost'"
        title="Users and storage quotas"
      >
        <ShieldCheck :size="16" /><span class="hidden md:inline">Admin</span>
      </a>
      <div class="relative">
        <button
          class="flex items-center gap-2 rounded-full py-1 pr-1 pl-3 text-sm hover:bg-slate-100"
          @click.stop="userMenu = !userMenu; uploadMenu = false; menu = null"
        >
          <span class="hidden sm:inline">{{ user.username }}</span>
          <span class="flex h-8 w-8 items-center justify-center rounded-full bg-blue-600 text-white"><User :size="16" /></span>
        </button>
        <div v-if="userMenu" class="absolute right-0 z-30 mt-1 w-56 rounded-lg border border-slate-200 bg-surface py-1 text-sm shadow-lg">
          <div class="border-b border-slate-100 px-4 py-2 text-slate-500">
            Signed in as <b class="text-slate-800">{{ user.username }}</b>
          </div>
          <div class="border-b border-slate-100 px-4 py-2" @click.stop>
            <div class="mb-1.5 text-xs text-slate-500">Theme</div>
            <div class="flex rounded-md bg-slate-100 p-0.5" role="radiogroup" aria-label="Theme">
              <button
                v-for="option in THEME_OPTIONS"
                :key="option.key"
                role="radio"
                :aria-checked="prefs.theme === option.key"
                :title="option.key === 'system' ? 'Follow this device’s light/dark setting' : `${option.label} theme`"
                class="flex flex-1 cursor-pointer items-center justify-center gap-1 rounded px-1.5 py-1 text-xs"
                :class="prefs.theme === option.key ? 'bg-surface font-medium text-slate-900 shadow-sm' : 'text-slate-600 hover:text-slate-900'"
                @click="chooseTheme(option.key)"
              >
                <component :is="option.icon" :size="14" /> {{ option.label }}
              </button>
            </div>
          </div>
          <button class="flex w-full items-center gap-2 px-4 py-2 hover:bg-slate-100" @click="dialog = { type: 'folder-color' }">
            <FileIcon kind="folder" :size="16" /> Folder color
          </button>
          <button class="flex w-full items-center gap-2 px-4 py-2 hover:bg-slate-100" @click="dialog = { type: 'password' }">
            <KeyRound :size="16" /> Change password
          </button>
          <button class="flex w-full items-center gap-2 px-4 py-2 hover:bg-slate-100" @click="emit('logout')">
            <LogOut :size="16" /> Sign out
          </button>
        </div>
      </div>
    </header>

    <SharesView v-if="page === 'shares'" @open-folder="navigate" />
    <AdminView v-if="page === 'admin'" :me="user" />

    <!-- Toolbar -->
    <div v-if="page === 'files'" class="flex min-h-14 flex-wrap items-center gap-2 border-b border-slate-200 px-3 py-2 sm:px-5">
      <nav v-if="!searching" class="flex min-w-0 flex-1 items-center text-sm">
        <template v-for="(crumb, i) in breadcrumb" :key="crumb.id">
          <ChevronRight v-if="i > 0" :size="16" class="shrink-0 text-slate-400" />
          <button
            class="truncate rounded-md px-2 py-1 hover:bg-slate-100"
            :class="[
              i === breadcrumb.length - 1 ? 'font-medium text-slate-900' : 'text-slate-600',
              dropTarget === crumb.id ? 'bg-blue-100 ring-2 ring-blue-400' : '',
            ]"
            @click="navigate(crumb.id)"
            @dragover="onFolderDragOver($event, crumb.id)"
            @dragleave="dropTarget = null"
            @drop="onFolderDrop($event, crumb.id)"
          >
            {{ crumb.name }}
          </button>
        </template>
      </nav>
      <div v-else class="flex-1 text-sm font-medium">Search results for “{{ query.trim() }}”</div>

      <div v-if="selection.size" class="flex items-center gap-1">
        <button v-if="selection.size === 1 && !selectedNodes[0]?.is_dir" class="btn btn-ghost" title="Preview" @click="open(selectedNodes[0])">
          <Eye :size="16" /><span class="hidden lg:inline">Open</span>
        </button>
        <button class="btn btn-ghost" title="Download" @click="download(selectedNodes)">
          <Download :size="16" /><span class="hidden lg:inline">Download</span>
        </button>
        <button
          v-if="selection.size === 1"
          class="btn btn-ghost"
          title="Share"
          @click="dialog = { type: 'share', node: selectedNodes[0] }"
        >
          <Share2 :size="16" /><span class="hidden lg:inline">Share</span>
        </button>
        <button v-if="selection.size === 1" class="btn btn-ghost" title="Rename (F2)" @click="dialog = { type: 'rename', nodes: selectedNodes }">
          <Pencil :size="16" /><span class="hidden lg:inline">Rename</span>
        </button>
        <button class="btn btn-ghost" title="Move to…" @click="dialog = { type: 'move', nodes: selectedNodes }">
          <FolderInput :size="16" /><span class="hidden lg:inline">Move</span>
        </button>
        <button class="btn btn-ghost-danger" title="Delete (Del)" @click="dialog = { type: 'delete', nodes: selectedNodes }">
          <Trash2 :size="16" /><span class="hidden lg:inline">Delete</span>
        </button>
        <button class="btn btn-ghost" title="Clear selection (Esc)" @click="selection.clear()"><X :size="16" /></button>
      </div>
      <div v-else-if="!searching" class="flex items-center gap-2">
        <button class="btn btn-ghost" @click="dialog = { type: 'new-folder' }">
          <FolderPlus :size="16" /><span class="hidden sm:inline">New folder</span>
        </button>
        <div class="relative">
          <button class="btn btn-primary" @click.stop="uploadMenu = !uploadMenu; userMenu = false; menu = null">
            <Upload :size="16" /> Upload
          </button>
          <div v-if="uploadMenu" class="absolute right-0 z-30 mt-1 w-44 rounded-lg border border-slate-200 bg-surface py-1 text-sm shadow-lg">
            <button class="flex w-full items-center gap-2 px-4 py-2 hover:bg-slate-100" @click="fileInput.click()">
              <Upload :size="16" /> Files
            </button>
            <button class="flex w-full items-center gap-2 px-4 py-2 hover:bg-slate-100" @click="folderInput.click()">
              <FolderUp :size="16" /> Folder
            </button>
          </div>
        </div>
        <input ref="fileInput" type="file" multiple class="hidden" @change="onFilesChosen" />
        <input ref="folderInput" type="file" webkitdirectory class="hidden" @change="onFilesChosen" />
      </div>
    </div>

    <!-- File list -->
    <main
      v-if="page === 'files'"
      class="relative min-h-0 flex-1 overflow-auto"
      @dragenter="onAreaDragEnter"
      @dragleave="onAreaDragLeave"
      @dragover="onAreaDragOver"
      @drop="onAreaDrop"
      @click.self="selection.clear()"
    >
      <table class="w-full table-fixed border-collapse text-sm select-none">
        <thead class="sticky top-0 z-10 bg-surface text-left text-xs text-slate-500">
          <tr class="border-b border-slate-200">
            <th class="w-10 py-2 pl-3 sm:pl-5">
              <input type="checkbox" class="align-middle" :checked="allSelected" :indeterminate="selection.size > 0 && !allSelected" @change="toggleAll" />
            </th>
            <th
              v-for="col in [
                { key: 'name', label: 'Name', cls: '' },
                { key: null, label: '', title: 'Shared', cls: 'w-9' },
                ...(searching ? [{ key: null, label: 'Location', cls: 'hidden w-48 md:table-cell' }] : []),
                { key: 'updated_at', label: 'Date modified', cls: 'hidden w-52 md:table-cell' },
                { key: 'type', label: 'Type', cls: 'hidden w-36 lg:table-cell' },
                { key: 'size', label: 'Size', cls: 'w-20 text-right sm:w-24' },
              ]"
              :key="col.title || col.label"
              class="px-2 py-2 font-medium"
              :class="col.cls"
              :title="col.title"
            >
              <button
                v-if="col.key"
                class="inline-flex items-center gap-1 hover:text-slate-900"
                :class="{ 'text-slate-900': sort.key === col.key }"
                @click="setSort(col.key)"
              >
                {{ col.label }}
                <template v-if="sort.key === col.key">
                  <ArrowUp v-if="sort.dir === 1" :size="12" />
                  <ArrowDown v-else :size="12" />
                </template>
              </button>
              <span v-else>{{ col.label }}</span>
            </th>
            <th class="w-10 pr-3 sm:pr-5"></th>
          </tr>
        </thead>
        <tbody>
          <tr
            v-if="parentCrumb && !searching"
            class="cursor-pointer border-b border-slate-100"
            :class="dropTarget === parentCrumb.id ? '!bg-blue-100 outline-2 -outline-offset-2 outline-blue-400' : 'hover:bg-slate-50'"
            :title="`Up to ${parentCrumb.name}`"
            @click="navigate(parentCrumb.id)"
            @dragover="onFolderDragOver($event, parentCrumb.id)"
            @dragleave="dropTarget === parentCrumb.id && (dropTarget = null)"
            @drop="onFolderDrop($event, parentCrumb.id)"
          >
            <td class="py-2 pl-3 sm:pl-5"></td>
            <td class="px-2 py-2">
              <div class="flex min-w-0 items-center gap-3">
                <button class="shrink-0 cursor-pointer hover:opacity-70" tabindex="-1" aria-hidden="true" @click.stop="navigate(parentCrumb.id)">
                  <CornerLeftUp :size="20" class="text-slate-400" stroke-width="1.75" />
                </button>
                <button class="cursor-pointer truncate text-left hover:underline" @click.stop="navigate(parentCrumb.id)">..</button>
              </div>
            </td>
            <td></td>
            <td class="hidden md:table-cell"></td>
            <td class="hidden lg:table-cell"></td>
            <td></td>
            <td></td>
          </tr>
          <tr
            v-for="node in rows"
            :key="node.id"
            draggable="true"
            class="group cursor-default border-b border-slate-100"
            :class="[
              selection.has(node.id) ? 'bg-blue-50' : 'hover:bg-slate-50',
              dropTarget === node.id ? '!bg-blue-100 outline-2 -outline-offset-2 outline-blue-400' : '',
            ]"
            @click="onRowClick($event, node)"
            @dblclick="open(node)"
            @contextmenu.prevent="openMenu($event, node)"
            @dragstart="onRowDragStart($event, node)"
            @dragend="dropTarget = null"
            @dragover="node.is_dir && onFolderDragOver($event, node.id)"
            @dragleave="dropTarget === node.id && (dropTarget = null)"
            @drop="node.is_dir && onFolderDrop($event, node.id)"
          >
            <td class="py-2 pl-3 sm:pl-5" @click.stop>
              <input type="checkbox" class="align-middle" :checked="selection.has(node.id)" @change="toggleSelected(node)" />
            </td>
            <td class="px-2 py-2">
              <div class="flex min-w-0 items-center gap-3">
                <button class="shrink-0 cursor-pointer hover:opacity-70" tabindex="-1" aria-hidden="true" @click.stop="open(node)">
                  <FileIcon :kind="node.kind" />
                </button>
                <button class="cursor-pointer truncate text-left hover:underline" :title="node.name" @click.stop="open(node)">
                  {{ node.name }}
                </button>
              </div>
            </td>
            <td class="py-2">
              <button
                v-if="node.share"
                class="flex cursor-pointer rounded p-1 text-blue-600 hover:bg-blue-100"
                :title="node.share === 'readwrite' ? 'Shared by link (read & write)' : 'Shared by link (read only)'"
                @click.stop="dialog = { type: 'share', node }"
              >
                <Link2 :size="16" />
              </button>
            </td>
            <td v-if="searching" class="hidden truncate px-2 py-2 text-slate-500 md:table-cell">
              <button class="truncate hover:underline" :title="node.path" @click.stop="navigate(node.parent_id)">
                {{ node.path === '/' ? ROOT_NAME : node.path.slice(1) }}
              </button>
            </td>
            <td class="hidden px-2 py-2 whitespace-nowrap text-slate-500 md:table-cell">{{ formatDate(node.updated_at) }}</td>
            <td class="hidden truncate px-2 py-2 text-slate-500 lg:table-cell">{{ typeLabel(node) }}</td>
            <td class="px-2 py-2 text-right text-slate-500 tabular-nums">{{ node.is_dir ? '—' : formatSize(node.size) }}</td>
            <td class="pr-3 sm:pr-5">
              <button
                class="rounded p-1 text-slate-400 hover:bg-slate-200 hover:text-slate-700 sm:opacity-0 sm:group-hover:opacity-100"
                title="More actions"
                @click.stop="openMenu($event, node)"
              >
                <EllipsisVertical :size="16" />
              </button>
            </td>
          </tr>
        </tbody>
      </table>

      <div v-if="!loading && !rows.length" class="flex flex-col items-center px-4 py-20 text-center text-slate-500">
        <template v-if="searching">
          <Search :size="40" class="mb-3 text-slate-300" />
          <p>No files or folders match “{{ query.trim() }}”.</p>
        </template>
        <template v-else>
          <CloudUpload :size="48" class="mb-3 text-slate-300" />
          <p class="font-medium text-slate-700">This folder is empty</p>
          <p class="text-sm">Drop files here, or use the Upload button.</p>
        </template>
      </div>

      <div
        v-if="externalDrag"
        class="pointer-events-none absolute inset-2 z-20 flex items-center justify-center rounded-xl border-2 border-dashed border-blue-500 bg-blue-50/80"
      >
        <div class="text-center text-blue-700 dark:text-blue-200">
          <CloudUpload :size="48" class="mx-auto mb-2" />
          <p class="font-medium">Drop to upload to “{{ breadcrumb.at(-1)?.name }}”</p>
        </div>
      </div>
    </main>

    <!-- Status bar -->
    <footer v-if="page === 'files'" class="flex items-center justify-between gap-4 border-t border-slate-200 px-3 py-1.5 text-xs text-slate-500 sm:px-5">
      <span>{{ statusText }}</span>
      <span v-if="stats && stats.quota_bytes != null" class="flex min-w-0 items-center gap-2" :title="`${Math.round(quotaPercent)}% of your storage used`">
        <span class="hidden h-1.5 w-24 overflow-hidden rounded-full bg-slate-200 sm:block">
          <span
            class="block h-full rounded-full"
            :class="quotaPercent >= 95 ? 'bg-red-500' : quotaPercent >= 80 ? 'bg-amber-500' : 'bg-blue-500'"
            :style="{ width: quotaPercent + '%' }"
          />
        </span>
        <span class="truncate" :class="{ 'font-medium text-red-600': quotaPercent >= 100 }">
          {{ formatSize(stats.used_bytes) }} of {{ formatSize(stats.quota_bytes) }} used<template v-if="quotaPercent >= 100"> · storage full</template>
        </span>
      </span>
      <span v-else-if="stats" class="truncate">
        {{ formatSize(stats.used_bytes) }} used · {{ formatSize(stats.disk_free) }} free on disk
      </span>
    </footer>

    <!-- Context menu -->
    <div
      v-if="menu"
      class="fixed z-40 w-48 rounded-lg border border-slate-200 bg-surface py-1 text-sm shadow-lg"
      :style="{ left: menu.x + 'px', top: menu.y + 'px' }"
      @click.stop
    >
      <button v-if="menu.nodes.length === 1" class="flex w-full items-center gap-2 px-4 py-2 hover:bg-slate-100" @click="menuAction('open')">
        <Eye :size="16" /> Open
      </button>
      <button class="flex w-full items-center gap-2 px-4 py-2 hover:bg-slate-100" @click="menuAction('download')">
        <Download :size="16" /> {{ menu.nodes.length === 1 && !menu.nodes[0].is_dir ? 'Download' : 'Download as zip' }}
      </button>
      <button
        v-if="menu.nodes.length === 1"
        class="flex w-full items-center gap-2 px-4 py-2 hover:bg-slate-100"
        @click="menuAction('share')"
      >
        <Share2 :size="16" /> {{ menu.nodes[0].share ? 'Sharing settings…' : 'Share…' }}
      </button>
      <button v-if="menu.nodes.length === 1" class="flex w-full items-center gap-2 px-4 py-2 hover:bg-slate-100" @click="menuAction('rename')">
        <Pencil :size="16" /> Rename
      </button>
      <button class="flex w-full items-center gap-2 px-4 py-2 hover:bg-slate-100" @click="menuAction('move')">
        <FolderInput :size="16" /> Move to…
      </button>
      <div class="my-1 border-t border-slate-100" />
      <button class="flex w-full items-center gap-2 px-4 py-2 text-red-600 hover:bg-red-50" @click="menuAction('delete')">
        <Trash2 :size="16" /> Delete
      </button>
    </div>

    <!-- Dialogs -->
    <PromptDialog
      v-if="dialog?.type === 'new-folder'"
      title="New folder"
      label="Folder name"
      initial="New folder"
      confirm-text="Create"
      @close="dialog = null"
      @submit="createFolder"
    />
    <PromptDialog
      v-if="dialog?.type === 'rename'"
      title="Rename"
      label="New name"
      :initial="dialog.nodes[0].name"
      confirm-text="Rename"
      @close="dialog = null"
      @submit="rename(dialog.nodes[0], $event)"
    />
    <ConfirmDialog
      v-if="dialog?.type === 'delete'"
      title="Delete"
      :message="deleteMessage"
      confirm-text="Delete"
      @close="dialog = null"
      @confirm="deleteNodes(dialog.nodes)"
    />
    <MoveDialog
      v-if="dialog?.type === 'move'"
      :nodes="dialog.nodes"
      :current-folder-id="folderId"
      @close="dialog = null"
      @move="moveNodes(dialog.nodes, $event)"
    />
    <PasswordDialog v-if="dialog?.type === 'password'" @close="dialog = null" />
    <FolderColorDialog v-if="dialog?.type === 'folder-color'" @close="dialog = null" />
    <ShareDialog v-if="dialog?.type === 'share'" :node="dialog.node" @close="dialog = null" @changed="refresh" />
    <PreviewDialog v-if="preview" :node="preview" :siblings="rows" @close="preview = null" @navigate="preview = $event" />

    <UploadPanel />
  </div>
</template>
