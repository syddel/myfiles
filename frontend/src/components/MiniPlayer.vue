<script setup>
// The bar at the bottom of the page while audio is playing or paused.
import { computed } from 'vue'
import { ListMusic, Pause, Play, RotateCcw, RotateCw, SkipBack, SkipForward, X } from 'lucide-vue-next'
import {
  BACK_SECONDS, FORWARD_SECONDS, SPEEDS, next, nextInPlaylist, player, previous, seek, setSpeed, skip, stop, toggle,
} from '../player'
import { formatTime } from '../audioFormat'
import FileIcon from './FileIcon.vue'

// open: show the file in the full player
const emit = defineEmits(['open'])

const index = computed(() => (player.node ? player.playlist.findIndex((e) => e.id === player.node.id) : -1))
const progress = computed(() => (player.duration ? (player.position / player.duration) * 100 : 0))
</script>

<template>
  <div v-if="player.node" class="relative border-t border-slate-200 bg-slate-50" role="region" aria-label="Audio player">
    <div class="absolute inset-x-0 top-0 h-0.5 bg-slate-200 sm:hidden">
      <div class="h-full bg-blue-500" :style="{ width: progress + '%' }" />
    </div>
    <div class="flex items-center gap-1 px-2 py-1.5 sm:gap-2 sm:px-5">
      <button
        class="flex min-w-0 flex-1 items-center gap-3 rounded-md px-1 py-1 text-left hover:bg-slate-100 sm:max-w-72 sm:flex-none"
        title="Open the player"
        @click="emit('open', { ...player.node, kind: 'audio', is_dir: false })"
      >
        <FileIcon kind="audio" class="shrink-0" />
        <span class="min-w-0">
          <span class="block truncate text-sm font-medium">{{ player.node.name }}</span>
          <span class="block truncate text-xs tabular-nums" :class="player.error ? 'text-red-600' : 'text-slate-500'">
            <template v-if="player.error">{{ player.error }}</template>
            <template v-else>
              {{ formatTime(player.position) }}<template v-if="player.duration"> / {{ formatTime(player.duration) }}</template>
              <template v-if="index >= 0"> · {{ index + 1 }} of {{ player.playlist.length }}</template>
            </template>
          </span>
        </span>
      </button>

      <div class="flex shrink-0 items-center">
        <button v-if="index >= 0" class="hidden rounded-full p-2 hover:bg-slate-200 sm:block" title="Previous in playlist" @click="previous">
          <SkipBack :size="18" />
        </button>
        <button class="hidden rounded-full p-2 hover:bg-slate-200 sm:block" :title="`Back ${BACK_SECONDS} seconds`" @click="skip(-BACK_SECONDS)">
          <RotateCcw :size="18" />
        </button>
        <button
          class="rounded-full bg-blue-600 p-2 text-white hover:bg-blue-500 disabled:opacity-50"
          :title="player.playing ? 'Pause' : 'Play'"
          :disabled="!!player.error"
          @click="toggle"
        >
          <Pause v-if="player.playing" :size="18" />
          <Play v-else :size="18" />
        </button>
        <button class="hidden rounded-full p-2 hover:bg-slate-200 sm:block" :title="`Forward ${FORWARD_SECONDS} seconds`" @click="skip(FORWARD_SECONDS)">
          <RotateCw :size="18" />
        </button>
        <button
          v-if="index >= 0"
          class="rounded-full p-2 hover:bg-slate-200 disabled:opacity-40"
          title="Next in playlist"
          :disabled="!nextInPlaylist()"
          @click="next"
        >
          <SkipForward :size="18" />
        </button>
      </div>

      <div class="hidden min-w-0 flex-1 items-center gap-2 text-xs text-slate-500 tabular-nums sm:flex">
        <span>{{ formatTime(player.position) }}</span>
        <input
          type="range"
          class="min-w-0 flex-1 accent-blue-600"
          min="0"
          :max="player.duration || 1"
          step="0.1"
          :value="player.position"
          :disabled="!player.duration"
          aria-label="Position"
          @input="seek(Number($event.target.value))"
        />
        <span>{{ player.duration ? formatTime(player.duration) : '--:--' }}</span>
      </div>

      <select
        class="hidden rounded-md border border-slate-200 bg-surface px-1 py-1 text-xs sm:block"
        title="Playback speed"
        aria-label="Playback speed"
        :value="player.speed"
        @change="setSpeed(Number($event.target.value))"
      >
        <option v-for="s in SPEEDS" :key="s" :value="s">{{ s }}×</option>
      </select>
      <a href="#/playlist" class="rounded-full p-2 hover:bg-slate-200" title="Playlist"><ListMusic :size="18" /></a>
      <button class="rounded-full p-2 hover:bg-slate-200" title="Close the player" @click="stop"><X :size="18" /></button>
    </div>
  </div>
</template>
