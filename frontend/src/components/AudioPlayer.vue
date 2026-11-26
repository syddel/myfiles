<script setup>
// The full audio player, shown when an audio file is previewed. Playback goes
// through the page-wide player, so it carries on after the preview closes.
import { computed, onMounted, watch } from 'vue'
import { ListMusic, ListPlus, Pause, Play, RotateCcw, RotateCw, SkipBack, SkipForward } from 'lucide-vue-next'
import {
  BACK_SECONDS, FORWARD_SECONDS, SPEEDS, addToPlaylist, inPlaylist, next, nextInPlaylist, playFile, player,
  previous, seek, setSpeed, skip, startOver, toggle,
} from '../player'
import { formatSize } from '../format'
import { formatTime, playlistAddedMessage } from '../audioFormat'
import { toast } from '../toast'
import FileIcon from './FileIcon.vue'

const props = defineProps({ node: Object })
// follow: the playlist moved on to another file (the preview shows that one instead)
const emit = defineEmits(['follow'])

const current = computed(() => player.node?.id === props.node.id)
const index = computed(() => player.playlist.findIndex((e) => e.id === props.node.id))

onMounted(() => playFile(props.node))
watch(() => props.node.id, () => playFile(props.node))

// When the playlist moves on from this file, show the next one.
watch(
  () => player.node?.id,
  (id, old) => {
    if (old === props.node.id && id != null && id !== props.node.id) emit('follow', { ...player.node, kind: 'audio', is_dir: false })
  },
)

async function add() {
  try {
    toast(playlistAddedMessage(await addToPlaylist([props.node])))
  } catch (e) {
    toast(e.message, 'error')
  }
}
</script>

<template>
  <div class="w-full max-w-lg rounded-xl bg-white/5 p-6 text-center sm:p-8">
    <FileIcon kind="audio" :size="64" class="mx-auto mb-4" />
    <p class="mb-1 font-medium break-words">{{ node.name }}</p>
    <p class="mb-4 text-xs text-slate-400">{{ formatSize(node.size) }}</p>

    <p v-if="current && player.error" class="mb-3 text-sm text-red-300">{{ player.error }}</p>
    <p v-if="current && player.resumedFrom" class="mb-3 text-sm text-slate-300">
      Continuing from {{ formatTime(player.resumedFrom) }} ·
      <button class="font-medium text-blue-300 hover:underline" @click="startOver">Start over</button>
    </p>

    <input
      type="range"
      class="w-full accent-blue-400"
      min="0"
      :max="(current && player.duration) || 1"
      step="0.1"
      :value="current ? player.position : 0"
      :disabled="!current || !player.duration"
      aria-label="Position"
      @input="seek(Number($event.target.value))"
    />
    <div class="mb-3 flex justify-between text-xs text-slate-400 tabular-nums">
      <span>{{ formatTime(current ? player.position : 0) }}</span>
      <span>{{ current && player.duration ? formatTime(player.duration) : '--:--' }}</span>
    </div>

    <div class="flex items-center justify-center gap-1 sm:gap-2">
      <select
        class="rounded-md bg-white/10 px-1.5 py-1 text-sm"
        title="Playback speed"
        aria-label="Playback speed"
        :value="player.speed"
        @change="setSpeed(Number($event.target.value))"
      >
        <option v-for="s in SPEEDS" :key="s" :value="s" class="text-slate-900">{{ s }}×</option>
      </select>
      <button
        v-if="current && index >= 0"
        class="rounded-full p-2 hover:bg-white/10"
        title="Previous in playlist"
        @click="previous"
      >
        <SkipBack :size="20" />
      </button>
      <button class="rounded-full p-2 hover:bg-white/10" :title="`Back ${BACK_SECONDS} seconds`" :disabled="!current" @click="skip(-BACK_SECONDS)">
        <RotateCcw :size="20" />
      </button>
      <button
        class="rounded-full bg-blue-500 p-3 text-white hover:bg-blue-400"
        :title="current && player.playing ? 'Pause' : 'Play'"
        @click="current ? toggle() : playFile(node)"
      >
        <Pause v-if="current && player.playing" :size="26" />
        <Play v-else :size="26" />
      </button>
      <button class="rounded-full p-2 hover:bg-white/10" :title="`Forward ${FORWARD_SECONDS} seconds`" :disabled="!current" @click="skip(FORWARD_SECONDS)">
        <RotateCw :size="20" />
      </button>
      <button
        v-if="current && index >= 0"
        class="rounded-full p-2 hover:bg-white/10 disabled:opacity-40"
        title="Next in playlist"
        :disabled="!nextInPlaylist()"
        @click="next"
      >
        <SkipForward :size="20" />
      </button>
      <a href="#/playlist" class="rounded-full p-2 hover:bg-white/10" title="Playlist"><ListMusic :size="20" /></a>
    </div>

    <p v-if="index >= 0" class="mt-4 text-sm text-slate-400">{{ index + 1 }} of {{ player.playlist.length }} in the playlist</p>
    <button v-else class="btn mt-4 text-blue-300 hover:bg-white/10" @click="add"><ListPlus :size="16" /> Add to playlist</button>
  </div>
</template>
