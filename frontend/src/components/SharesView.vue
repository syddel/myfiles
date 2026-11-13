<script setup>
import { onMounted, ref } from 'vue'
import { Check, Copy, ExternalLink, FolderOpen, Link2, Lock, Plus, Settings2, Trash2 } from 'lucide-vue-next'
import { api, shareLink } from '../api'
import { formatDate } from '../format'
import { toast } from '../toast'
import { SHARE_MODES, copyText } from '../utils'
import ConfirmDialog from './ConfirmDialog.vue'
import FileIcon from './FileIcon.vue'
import MoveDialog from './MoveDialog.vue'
import ShareDialog from './ShareDialog.vue'

const emit = defineEmits(['open-folder'])

const shares = ref([])
const loading = ref(true)
const copiedId = ref(null)
const picking = ref(false)
const editing = ref(null) // { id, name, is_dir } of the item in the share dialog
const stopping = ref(null) // share being turned off

async function load() {
  try {
    shares.value = await api.shares()
  } catch (e) {
    toast(e.message, 'error')
  } finally {
    loading.value = false
  }
}
onMounted(load)

async function setMode(share, mode) {
  try {
    Object.assign(share, await api.setShare(share.node_id, mode))
    toast(`"${share.name}" is now ${SHARE_MODES[mode].label.toLowerCase()}`)
  } catch (e) {
    toast(e.message, 'error')
    await load()
  }
}

async function stop(share) {
  try {
    await api.stopSharing(share.node_id)
    stopping.value = null
    toast(`Stopped sharing "${share.name}"`)
    await load()
  } catch (e) {
    toast(e.message, 'error')
  }
}

async function copy(share) {
  try {
    await copyText(shareLink(share))
    copiedId.value = share.node_id
    toast('Link copied')
    setTimeout(() => copiedId.value === share.node_id && (copiedId.value = null), 2000)
  } catch {
    toast('Couldn’t copy automatically; open the share settings to copy the link', 'error')
  }
}

function stopMessage(share) {
  return `Stop sharing "${share.name}"? The link will stop working. Sharing it again creates a new link.`
}

function pickFolder(id, folder) {
  picking.value = false
  editing.value = { id, name: folder?.parent_id === null ? '' : folder?.name, is_dir: true }
}
</script>

<template>
  <div class="flex min-h-0 flex-1 flex-col">
    <div class="flex min-h-14 flex-wrap items-center gap-2 border-b border-slate-200 px-3 py-2 sm:px-5">
      <div class="flex-1">
        <h1 class="text-sm font-medium text-slate-900">Shared folders and files</h1>
        <p class="text-xs text-slate-500">
          Anyone with the link can open these. To share a file, right-click it in your files and choose Share.
        </p>
      </div>
      <button class="btn btn-primary" @click="picking = true"><Plus :size="16" /> Share a folder</button>
    </div>

    <main class="min-h-0 flex-1 overflow-auto">
      <table v-if="shares.length" class="w-full table-fixed border-collapse text-sm">
        <thead class="sticky top-0 z-10 bg-surface text-left text-xs text-slate-500">
          <tr class="border-b border-slate-200">
            <th class="px-3 py-2 font-medium sm:pl-5">Name</th>
            <th class="w-32 px-2 py-2 font-medium sm:w-40">Access</th>
            <th class="hidden w-52 px-2 py-2 font-medium lg:table-cell">Shared since</th>
            <th class="w-28 px-2 py-2 pr-3 text-right font-medium sm:w-44 sm:pr-5 lg:w-64">Actions</th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="share in shares" :key="share.node_id" class="border-b border-slate-100 hover:bg-slate-50">
            <td class="px-3 py-2 sm:pl-5">
              <button
                class="flex max-w-full min-w-0 cursor-pointer items-center gap-3 text-left"
                :title="share.is_dir ? 'Open folder' : 'Show in its folder'"
                @click="emit('open-folder', share.is_dir ? share.node_id : share.parent_id)"
              >
                <FileIcon :kind="share.kind" />
                <span class="min-w-0">
                  <span class="flex items-center gap-1.5">
                    <span class="truncate hover:underline">{{ share.name }}</span>
                    <Lock v-if="share.has_password" :size="13" class="shrink-0 text-slate-500" aria-label="Password protected" />
                  </span>
                  <span class="block truncate text-xs text-slate-500">
                    {{ share.path || '/' }}<template v-if="share.has_password"> · password protected</template>
                  </span>
                </span>
              </button>
            </td>
            <td class="px-2 py-2">
              <span v-if="!share.is_dir" class="px-2 text-slate-600">Read only</span>
              <select
                v-else
                class="w-full rounded-md border border-slate-300 bg-surface px-2 py-1 text-sm"
                :value="share.mode"
                @change="setMode(share, $event.target.value)"
              >
                <option v-for="(info, key) in SHARE_MODES" :key="key" :value="key">{{ info.label }}</option>
              </select>
            </td>
            <td class="hidden px-2 py-2 whitespace-nowrap text-slate-500 lg:table-cell">{{ formatDate(share.created_at) }}</td>
            <td class="px-2 py-2 pr-3 sm:pr-5">
              <div class="flex justify-end sm:gap-1">
                <button class="btn btn-ghost px-2 whitespace-nowrap" title="Copy link" @click="copy(share)">
                  <Check v-if="copiedId === share.node_id" :size="16" class="text-green-600" /><Copy v-else :size="16" />
                  <span class="hidden lg:inline">Copy link</span>
                </button>
                <a :href="shareLink(share)" target="_blank" rel="noopener" class="btn btn-ghost hidden px-2 sm:inline-flex" title="Open link in a new tab">
                  <ExternalLink :size="16" />
                </a>
                <button class="btn btn-ghost px-2" title="Share settings" @click="editing = { id: share.node_id, name: share.name, is_dir: share.is_dir }">
                  <Settings2 :size="16" />
                </button>
                <button class="btn btn-ghost-danger px-2" title="Stop sharing" @click="stopping = share">
                  <Trash2 :size="16" />
                </button>
              </div>
            </td>
          </tr>
        </tbody>
      </table>

      <div v-else-if="!loading" class="flex flex-col items-center px-4 py-20 text-center text-slate-500">
        <Link2 :size="44" class="mb-3 text-slate-300" />
        <p class="font-medium text-slate-700">You aren’t sharing anything</p>
        <p class="mb-4 text-sm">Share a folder or file to give anyone with the link access to it.</p>
        <button class="btn btn-primary" @click="picking = true"><FolderOpen :size="16" /> Choose a folder to share</button>
      </div>
    </main>

    <MoveDialog v-if="picking" title="Choose a folder to share" confirm-text="Next" @close="picking = false" @move="pickFolder" />
    <ShareDialog v-if="editing" :node="editing" @close="editing = null" @changed="load" />
    <ConfirmDialog
      v-if="stopping"
      title="Stop sharing"
      :message="stopMessage(stopping)"
      confirm-text="Stop sharing"
      @close="stopping = null"
      @confirm="stop(stopping)"
    />
  </div>
</template>
