<script setup>
// What visitors see when they open a share link. No account needed.
import { computed, onBeforeUnmount, onMounted, reactive, ref, watch } from 'vue'
import { ChevronRight, CloudUpload, CornerLeftUp, Download, FolderUp, Link2, Lock, Upload } from 'lucide-vue-next'
import { shareApi } from '../api'
import { formatDate, formatSize } from '../format'
import { toast } from '../toast'
import { enqueueUploads, filesFromDrop, filesFromInput, onUploadFinished } from '../uploads'
import FileContent from './FileContent.vue'
import FileIcon from './FileIcon.vue'
import PreviewDialog from './PreviewDialog.vue'
import UploadPanel from './UploadPanel.vue'

const props = defineProps({ token: String })
const sapi = shareApi(props.token)

const info = ref(null)
const error = ref('')
// Password-protected link that hasn't been unlocked (or whose password was changed).
const locked = ref(false)
const password = ref('')
const unlockError = ref('')
const unlocking = ref(false)
const folderId = ref(null)
const breadcrumb = ref([])
const items = ref([])
const loading = ref(true)
const selection = reactive(new Set())
const preview = ref(null)
const uploadMenu = ref(false)
const fileInput = ref(null)
const folderInput = ref(null)

const canUpload = computed(() => info.value?.mode === 'readwrite')
// A link to a single file shows that file instead of a folder listing.
const sharedFile = computed(() => (info.value && !info.value.is_dir ? info.value.node : null))
const collator = new Intl.Collator(undefined, { numeric: true, sensitivity: 'base' })
const rows = computed(() =>
  [...items.value].sort((a, b) => (b.is_dir - a.is_dir) || collator.compare(a.name, b.name)),
)
const parentCrumb = computed(() => (breadcrumb.value.length > 1 ? breadcrumb.value.at(-2) : null))
const selectedNodes = computed(() => rows.value.filter((n) => selection.has(n.id)))

function folderFromHash() {
  const m = location.hash.match(/^#\/folder\/(\d+)/)
  return m ? Number(m[1]) : info.value?.root_id
}

function navigate(id) {
  location.hash = id === info.value.root_id ? '#/' : `#/folder/${id}`
}

async function loadFolder() {
  try {
    const data = await sapi.folder(folderId.value)
    breadcrumb.value = data.breadcrumb
    items.value = data.items
  } catch (e) {
    if (e.status === 401) locked.value = true
    else if (e.status === 404 && folderId.value !== info.value.root_id) navigate(info.value.root_id)
    else error.value = e.message
  } finally {
    loading.value = false
  }
}

watch(folderId, () => {
  selection.clear()
  loadFolder()
})

function onHashChange() {
  folderId.value = folderFromHash()
}

function open(node) {
  if (node.is_dir) navigate(node.id)
  else preview.value = node
}

function toggle(node) {
  selection.has(node.id) ? selection.delete(node.id) : selection.add(node.id)
}

// One file downloads as itself; folders and multiple items come as one zip.
function download(nodes) {
  const single = nodes.length === 1 && !nodes[0].is_dir
  const a = document.createElement('a')
  a.href = single ? sapi.contentUrl(nodes[0].id, true) : sapi.zipUrl(nodes.map((n) => n.id))
  document.body.appendChild(a)
  a.click()
  a.remove()
  if (!single) toast('Preparing zip download…')
}

// ------------------------------------------------------------ uploads (read & write links only)

function upload(entries) {
  if (entries.length) enqueueUploads(entries, folderId.value, sapi.uploadEndpoint)
}

function onFilesChosen(e) {
  upload(filesFromInput(e.target.files))
  e.target.value = ''
}

let refreshTimer = null
const stopListening = onUploadFinished(() => {
  clearTimeout(refreshTimer)
  refreshTimer = setTimeout(loadFolder, 300)
})

const externalDrag = ref(false)
let dragDepth = 0
const isFileDrag = (e) => canUpload.value && e.dataTransfer.types.includes('Files')

function onDragEnter(e) {
  if (!isFileDrag(e)) return
  dragDepth++
  externalDrag.value = true
}
function onDragLeave(e) {
  if (!isFileDrag(e)) return
  if (--dragDepth <= 0) {
    dragDepth = 0
    externalDrag.value = false
  }
}
function onDragOver(e) {
  if (isFileDrag(e)) e.preventDefault()
}
async function onDrop(e) {
  dragDepth = 0
  externalDrag.value = false
  if (!isFileDrag(e)) return
  e.preventDefault()
  upload(await filesFromDrop(e.dataTransfer))
}

function closeMenus() {
  uploadMenu.value = false
}

async function loadInfo() {
  try {
    const data = await sapi.info()
    if (data.locked) {
      locked.value = true
      document.title = data.app_name
      loading.value = false
      return
    }
    locked.value = false
    info.value = data
    document.title = `${data.name} – ${data.app_name}`
    if (!data.is_dir) loading.value = false
    else if (folderId.value === folderFromHash()) loadFolder()
    else folderId.value = folderFromHash()
  } catch (e) {
    error.value = e.message
    loading.value = false
  }
}

async function unlock() {
  unlockError.value = ''
  unlocking.value = true
  try {
    await sapi.unlock(password.value)
    password.value = ''
    await loadInfo()
  } catch (e) {
    unlockError.value = e.message
  } finally {
    unlocking.value = false
  }
}

onMounted(() => {
  window.addEventListener('hashchange', onHashChange)
  window.addEventListener('click', closeMenus)
  loadInfo()
})

onBeforeUnmount(() => {
  window.removeEventListener('hashchange', onHashChange)
  window.removeEventListener('click', closeMenus)
  stopListening()
})
</script>

<template>
  <div v-if="error" class="flex min-h-full items-center justify-center bg-slate-50 px-4">
    <div class="max-w-sm text-center">
      <Link2 :size="44" class="mx-auto mb-3 text-slate-300" />
      <h1 class="mb-1 text-lg font-medium">Link not available</h1>
      <p class="text-sm text-slate-600">{{ error }}</p>
    </div>
  </div>

  <div v-else-if="locked" class="flex min-h-full items-center justify-center bg-slate-50 px-4">
    <form class="w-full max-w-sm space-y-4 rounded-xl border border-slate-200 bg-surface p-6 text-center shadow-sm" @submit.prevent="unlock">
      <Lock :size="36" class="mx-auto text-slate-400" />
      <div>
        <h1 class="text-lg font-medium">Password required</h1>
        <p class="text-sm text-slate-600">Enter the password you were given to open this link.</p>
      </div>
      <input
        v-model="password"
        type="password"
        class="input"
        placeholder="Password"
        aria-label="Password"
        autocomplete="off"
        required
        autofocus
      />
      <p v-if="unlockError" class="rounded-md bg-red-50 px-3 py-2 text-sm text-red-700 dark:text-red-300">{{ unlockError }}</p>
      <button class="btn btn-primary w-full justify-center py-2" :disabled="unlocking || !password">Open</button>
    </form>
  </div>

  <div v-else class="flex h-full flex-col">
    <header class="flex items-center gap-3 border-b border-slate-200 px-3 py-2 sm:px-5">
      <img :src="'favicon.svg'" class="h-7 w-7 shrink-0" alt="" />
      <div class="min-w-0 flex-1">
        <div class="truncate font-semibold">{{ info?.name ?? 'Shared folder' }}</div>
        <div v-if="info" class="truncate text-xs text-slate-500">Shared by {{ info.owner }}</div>
      </div>
      <span
        v-if="info"
        class="shrink-0 rounded-full px-2.5 py-1 text-xs font-medium"
        :class="canUpload ? 'bg-amber-100 text-amber-800 dark:text-amber-200' : 'bg-slate-100 text-slate-600'"
      >
        {{ canUpload ? 'You can view and upload' : sharedFile ? 'View and download' : 'View only' }}
      </span>
    </header>

    <template v-if="sharedFile">
      <div class="flex min-h-14 flex-wrap items-center gap-3 border-b border-slate-200 px-3 py-2 sm:px-5">
        <FileIcon :kind="sharedFile.kind" />
        <div class="min-w-0 flex-1 text-sm text-slate-500">
          {{ formatSize(sharedFile.size) }} · {{ formatDate(sharedFile.updated_at) }}
        </div>
        <a :href="sapi.contentUrl(sharedFile.id, true)" class="btn btn-primary"><Download :size="16" /> Download</a>
      </div>
      <main class="flex min-h-0 flex-1 items-center justify-center overflow-auto bg-slate-50 p-4">
        <FileContent :node="sharedFile" :url="sapi.contentUrl(sharedFile.id)" :download-url="sapi.contentUrl(sharedFile.id, true)" />
      </main>
    </template>

    <template v-else>
      <div class="flex min-h-14 flex-wrap items-center gap-2 border-b border-slate-200 px-3 py-2 sm:px-5">
        <nav class="flex min-w-0 flex-1 items-center text-sm">
          <template v-for="(crumb, i) in breadcrumb" :key="crumb.id">
            <ChevronRight v-if="i > 0" :size="16" class="shrink-0 text-slate-400" />
            <button
              class="truncate rounded-md px-2 py-1 hover:bg-slate-100"
              :class="i === breadcrumb.length - 1 ? 'font-medium text-slate-900' : 'text-slate-600'"
              @click="navigate(crumb.id)"
            >
              {{ crumb.name }}
            </button>
          </template>
        </nav>
        <div class="flex items-center gap-2">
          <button v-if="selection.size" class="btn btn-ghost" @click="download(selectedNodes)">
            <Download :size="16" /> Download {{ selection.size }} selected
          </button>
          <button v-else-if="rows.length" class="btn btn-ghost" title="Download this folder as a zip" @click="download([{ id: folderId, is_dir: true }])">
            <Download :size="16" /><span class="hidden sm:inline">Download all</span>
          </button>
          <div v-if="canUpload" class="relative">
            <button class="btn btn-primary" @click.stop="uploadMenu = !uploadMenu"><Upload :size="16" /> Upload</button>
            <div v-if="uploadMenu" class="absolute right-0 z-30 mt-1 w-44 rounded-lg border border-slate-200 bg-surface py-1 text-sm shadow-lg">
              <button class="flex w-full items-center gap-2 px-4 py-2 hover:bg-slate-100" @click="fileInput.click()">
                <Upload :size="16" /> Files
              </button>
              <button class="flex w-full items-center gap-2 px-4 py-2 hover:bg-slate-100" @click="folderInput.click()">
                <FolderUp :size="16" /> Folder
              </button>
            </div>
            <input ref="fileInput" type="file" multiple class="hidden" @change="onFilesChosen" />
            <input ref="folderInput" type="file" webkitdirectory class="hidden" @change="onFilesChosen" />
          </div>
        </div>
      </div>

      <main class="relative min-h-0 flex-1 overflow-auto" @dragenter="onDragEnter" @dragleave="onDragLeave" @dragover="onDragOver" @drop="onDrop">
        <table class="w-full table-fixed border-collapse text-sm select-none">
          <thead class="sticky top-0 z-10 bg-surface text-left text-xs text-slate-500">
            <tr class="border-b border-slate-200">
              <th class="w-10 py-2 pl-3 sm:pl-5"></th>
              <th class="px-2 py-2 font-medium">Name</th>
              <th class="hidden w-52 px-2 py-2 font-medium md:table-cell">Date modified</th>
              <th class="w-20 px-2 py-2 text-right font-medium sm:w-24">Size</th>
              <th class="w-12 pr-3 sm:pr-5"></th>
            </tr>
          </thead>
          <tbody>
            <tr
              v-if="parentCrumb"
              class="cursor-pointer border-b border-slate-100 hover:bg-slate-50"
              :title="`Up to ${parentCrumb.name}`"
              @click="navigate(parentCrumb.id)"
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
              <td class="hidden md:table-cell"></td>
              <td></td>
              <td></td>
            </tr>
            <tr
              v-for="node in rows"
              :key="node.id"
              class="border-b border-slate-100"
              :class="selection.has(node.id) ? 'bg-blue-50' : 'hover:bg-slate-50'"
              @dblclick="open(node)"
            >
              <td class="py-2 pl-3 sm:pl-5">
                <input type="checkbox" class="align-middle" :checked="selection.has(node.id)" @change="toggle(node)" />
              </td>
              <td class="px-2 py-2">
                <div class="flex min-w-0 items-center gap-3">
                  <button class="shrink-0 cursor-pointer hover:opacity-70" tabindex="-1" aria-hidden="true" @click="open(node)">
                    <FileIcon :kind="node.kind" />
                  </button>
                  <button class="cursor-pointer truncate text-left hover:underline" :title="node.name" @click="open(node)">
                    {{ node.name }}
                  </button>
                </div>
              </td>
              <td class="hidden px-2 py-2 whitespace-nowrap text-slate-500 md:table-cell">{{ formatDate(node.updated_at) }}</td>
              <td class="px-2 py-2 text-right text-slate-500 tabular-nums">{{ node.is_dir ? '—' : formatSize(node.size) }}</td>
              <td class="pr-3 sm:pr-5">
                <button
                  class="rounded p-1 text-slate-400 hover:bg-slate-200 hover:text-slate-700"
                  :title="node.is_dir ? 'Download folder as zip' : 'Download'"
                  @click="download([node])"
                >
                  <Download :size="16" />
                </button>
              </td>
            </tr>
          </tbody>
        </table>

        <div v-if="!loading && !rows.length" class="flex flex-col items-center px-4 py-20 text-center text-slate-500">
          <CloudUpload :size="48" class="mb-3 text-slate-300" />
          <p class="font-medium text-slate-700">This folder is empty</p>
          <p v-if="canUpload" class="text-sm">Drop files here, or use the Upload button.</p>
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

      <footer class="border-t border-slate-200 px-3 py-1.5 text-xs text-slate-500 sm:px-5">
        {{ rows.length }} item{{ rows.length === 1 ? '' : 's' }}
      </footer>
    </template>

    <PreviewDialog v-if="preview" :node="preview" :siblings="rows" :url-for="sapi.contentUrl" @close="preview = null" @navigate="preview = $event" />
    <UploadPanel />
  </div>
</template>
