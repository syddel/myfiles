<script setup>
// The audio playlist: play, reorder (drag), remove, shuffle, clear, and
// "start all from the beginning".
import { computed, ref } from 'vue'
import { EllipsisVertical, GripVertical, ListMusic, Pause, Play, RotateCcw, Shuffle, Trash2, Volume2, X } from 'lucide-vue-next'
import {
  clearPlaylist, currentEntry, forgetPositions, moveInPlaylist, playPlaylist, player, removeFromPlaylist,
  savedPosition, shufflePlaylist, toggle,
} from '../player'
import { formatSize } from '../format'
import { formatTime } from '../audioFormat'
import { toast } from '../toast'
import ConfirmDialog from './ConfirmDialog.vue'
import FileIcon from './FileIcon.vue'

const confirming = ref(null) // 'clear' | 'restart'
const moreMenu = ref(false)
// Bumped to re-read saved positions after they're forgotten.
const positionsVersion = ref(0)

const playingFromPlaylist = computed(() => player.node && player.playlist.some((e) => e.id === player.node.id))
const playLabel = computed(() => {
  if (playingFromPlaylist.value) return player.playing ? 'Pause' : 'Play'
  return currentEntry() === player.playlist[0] ? 'Play' : 'Continue'
})

function playButton() {
  if (playingFromPlaylist.value) toggle()
  else playPlaylist()
}

function subtitle(entry) {
  if (player.node?.id === entry.id) return `${player.playing ? 'Playing' : 'Paused'} · ${formatTime(player.position)}`
  void positionsVersion.value
  const saved = savedPosition(entry.id)
  return saved ? `Continue from ${formatTime(saved)}` : formatSize(entry.size)
}

function remove(entry) {
  removeFromPlaylist(entry.id)
  toast(`Removed "${entry.name}" from the playlist`)
}

function confirmed() {
  if (confirming.value === 'clear') clearPlaylist()
  else {
    forgetPositions(player.playlist.map((e) => e.id))
    positionsVersion.value++
    toast('All files will start from the beginning')
  }
  confirming.value = null
}

function shuffle() {
  shufflePlaylist()
  toast('Shuffled')
}

// ------------------------------------------------------------ drag to reorder

const dragFrom = ref(null)
const dragOver = ref(null)

function onDragStart(e, i) {
  dragFrom.value = i
  e.dataTransfer.effectAllowed = 'move'
  e.dataTransfer.setData('text/plain', String(i))
}

function onDragOver(e, i) {
  if (dragFrom.value == null) return
  e.preventDefault()
  dragOver.value = i
}

function onDrop(e, i) {
  e.preventDefault()
  if (dragFrom.value != null) moveInPlaylist(dragFrom.value, i)
  dragFrom.value = dragOver.value = null
}
</script>

<template>
  <main class="min-h-0 flex-1 overflow-auto" @click="moreMenu = false">
    <div class="mx-auto max-w-3xl px-3 py-4 sm:px-5">
      <div class="mb-4 flex flex-wrap items-center gap-2">
        <h1 class="mr-auto text-lg font-semibold">
          Playlist<span v-if="player.playlist.length" class="font-normal text-slate-500"> ({{ player.playlist.length }})</span>
        </h1>
        <template v-if="player.playlist.length">
          <button class="btn btn-primary" @click="playButton">
            <Pause v-if="playingFromPlaylist && player.playing" :size="16" />
            <Play v-else :size="16" />
            {{ playLabel }}
          </button>
          <button class="btn btn-ghost" title="Shuffle" :disabled="player.playlist.length < 2" @click="shuffle">
            <Shuffle :size="16" /><span class="hidden sm:inline">Shuffle</span>
          </button>
          <button class="btn btn-ghost" title="Clear playlist" @click="confirming = 'clear'">
            <Trash2 :size="16" /><span class="hidden sm:inline">Clear</span>
          </button>
          <div class="relative">
            <button class="btn btn-ghost" title="More" @click.stop="moreMenu = !moreMenu"><EllipsisVertical :size="16" /></button>
            <div v-if="moreMenu" class="absolute right-0 z-30 mt-1 w-60 rounded-lg border border-slate-200 bg-surface py-1 text-sm shadow-lg">
              <button class="flex w-full items-center gap-2 px-4 py-2 hover:bg-slate-100" @click="confirming = 'restart'">
                <RotateCcw :size="16" /> Start all from the beginning
              </button>
            </div>
          </div>
        </template>
      </div>

      <div v-if="!player.playlist.length" class="flex flex-col items-center px-4 py-20 text-center text-slate-500">
        <ListMusic :size="48" class="mb-3 text-slate-300" />
        <p class="font-medium text-slate-700">The playlist is empty</p>
        <p class="text-sm">Add audio files with “Add to playlist” in a file’s or folder’s menu (⋮ or right-click).</p>
      </div>

      <ol v-else class="divide-y divide-slate-100 rounded-lg border border-slate-200">
        <li
          v-for="(entry, i) in player.playlist"
          :key="entry.id"
          draggable="true"
          class="group flex items-center gap-2 px-2 py-2"
          :class="[
            player.currentId === entry.id || player.node?.id === entry.id ? 'bg-blue-50' : 'hover:bg-slate-50',
            dragOver === i && dragFrom !== i ? 'outline-2 -outline-offset-2 outline-blue-400' : '',
          ]"
          @dragstart="onDragStart($event, i)"
          @dragover="onDragOver($event, i)"
          @dragleave="dragOver === i && (dragOver = null)"
          @drop="onDrop($event, i)"
          @dragend="dragFrom = dragOver = null"
        >
          <span class="cursor-grab text-slate-400" title="Drag to reorder"><GripVertical :size="16" /></span>
          <span class="w-6 text-center text-xs text-slate-500 tabular-nums">
            <Volume2 v-if="player.node?.id === entry.id" :size="16" class="mx-auto text-blue-600" />
            <template v-else>{{ i + 1 }}</template>
          </span>
          <button class="flex min-w-0 flex-1 items-center gap-3 text-left" :title="`Play ${entry.name}`" @click="playPlaylist(entry)">
            <FileIcon kind="audio" class="shrink-0" />
            <span class="min-w-0">
              <span class="block truncate text-sm hover:underline">{{ entry.name }}</span>
              <span class="block text-xs text-slate-500 tabular-nums">{{ subtitle(entry) }}</span>
            </span>
          </button>
          <button
            class="rounded p-1 text-slate-400 hover:bg-slate-200 hover:text-slate-700 sm:opacity-0 sm:group-hover:opacity-100"
            title="Remove from the playlist"
            @click="remove(entry)"
          >
            <X :size="16" />
          </button>
        </li>
      </ol>
    </div>

    <ConfirmDialog
      v-if="confirming === 'clear'"
      title="Clear the playlist?"
      :message="`This removes all ${player.playlist.length} file${player.playlist.length === 1 ? '' : 's'} from the playlist, so you can start a new one. The files themselves aren’t deleted.`"
      confirm-text="Clear"
      @close="confirming = null"
      @confirm="confirmed"
    />
    <ConfirmDialog
      v-if="confirming === 'restart'"
      title="Start all from the beginning?"
      :message="`This forgets where you stopped in each of the ${player.playlist.length} file${player.playlist.length === 1 ? '' : 's'} in the playlist, so they all play from the start.`"
      confirm-text="Start from the beginning"
      :danger="false"
      @close="confirming = null"
      @confirm="confirmed"
    />
  </main>
</template>
