// The audio player and the playlist, shared by the whole page: audio keeps
// playing while you browse, and the bar at the bottom shows what's playing.
//
// Kept in this browser (per account): where you stopped in each audio file,
// the playlist and the file you were on in it, and the playback speed.
import { reactive } from 'vue'
import { api, contentUrl } from './api'

export const SPEEDS = [1, 1.25, 1.5, 2]
export const BACK_SECONDS = 10
export const FORWARD_SECONDS = 30
const SAVE_EVERY_MS = 5000
const MIN_RESUME_SECONDS = 5 // positions this close to the start aren't worth resuming from

const storage = {
  get(key) {
    try {
      return localStorage.getItem(key)
    } catch {
      return null
    }
  },
  set(key, value) {
    try {
      if (value == null) localStorage.removeItem(key)
      else localStorage.setItem(key, value)
    } catch {
      // private browsing etc.: works for this visit only
    }
  },
}

function storedSpeed() {
  const speed = Number(storage.get('myfiles-audio-speed'))
  return SPEEDS.includes(speed) ? speed : 1
}

export const player = reactive({
  node: null, // { id, name, size } of the file playing (or paused)
  playing: false,
  loading: false,
  position: 0, // seconds
  duration: 0,
  speed: storedSpeed(),
  error: '',
  resumedFrom: null, // seconds, when playback picked up from a saved position
  playlist: [], // [{ id, name, size }]
  currentId: null, // the playlist file you were on
})

let userId = null
const audio = new Audio()
audio.preload = 'auto'

const posKey = (id) => `myfiles-audio-pos:${userId}:${id}`
const playlistKey = () => `myfiles-playlist:${userId}`

// ------------------------------------------------------------ account

// Called when someone signs in or out: stop, and load that account's playlist.
export function setPlayerUser(user) {
  const id = user?.id ?? null
  if (id === userId) return
  stop()
  userId = id
  player.playlist = []
  player.currentId = null
  if (id == null) return
  try {
    const saved = JSON.parse(storage.get(playlistKey()) || 'null')
    if (saved) {
      player.playlist = saved.entries ?? []
      player.currentId = saved.current ?? null
    }
  } catch {
    // unreadable: start again
  }
}

// ------------------------------------------------------------ positions

export function savedPosition(id) {
  const seconds = Number(storage.get(posKey(id)))
  return seconds >= MIN_RESUME_SECONDS ? seconds : null
}

let lastSave = 0

function savePosition() {
  const node = player.node
  // Only once the file playing is loaded (while another loads, the position isn't its).
  if (!node || !userId || player.error || audio.readyState < 1 || audio.ended) return
  lastSave = Date.now()
  const t = audio.currentTime
  storage.set(posKey(node.id), t >= MIN_RESUME_SECONDS ? t.toFixed(1) : null)
}

// Forget where you stopped in these files; one that's loaded goes back to the start too.
export function forgetPositions(ids) {
  for (const id of ids) storage.set(posKey(id), null)
  if (player.node && ids.includes(player.node.id)) seek(0)
}

// ------------------------------------------------------------ playing

export function inPlaylist(id) {
  return player.playlist.some((e) => e.id === id)
}

function neighbour(delta) {
  if (!player.node) return null
  const i = player.playlist.findIndex((e) => e.id === player.node.id)
  return i < 0 ? null : player.playlist[i + delta] ?? null
}
export const nextInPlaylist = () => neighbour(1)
export const previousInPlaylist = () => neighbour(-1)

// Play a file, continuing where it was left off. If it's already the current
// file, just make sure it's playing.
export function playFile(node) {
  if (inPlaylist(node.id)) setCurrent(node.id)
  if (player.node?.id === node.id && !player.error) {
    if (audio.paused) play()
    return
  }
  savePosition()
  const start = savedPosition(node.id) ?? 0
  player.node = { id: node.id, name: node.name, size: node.size }
  player.error = ''
  player.position = start
  player.duration = 0
  player.resumedFrom = start || null
  player.loading = true
  // "#t=" starts the file at the saved position.
  audio.src = contentUrl(node.id) + (start ? `#t=${start}` : '')
  audio.defaultPlaybackRate = player.speed
  audio.playbackRate = player.speed
  play()
  updateMediaSession()
}

export function play() {
  if (!player.node) return
  audio.play().catch((e) => {
    // AbortError: replaced by another file before it started. NotAllowedError:
    // the browser wants a click first (the play button then works).
    if (e.name !== 'AbortError' && e.name !== 'NotAllowedError') player.error = "This file can't be played"
  })
}

export function pause() {
  audio.pause()
}

export function toggle() {
  audio.paused ? play() : pause()
}

export function seek(seconds) {
  if (!player.node) return
  const max = player.duration || audio.duration || Infinity
  const t = Math.max(0, Math.min(seconds, max))
  audio.currentTime = t
  player.position = t
  player.resumedFrom = null
  savePosition()
}

export const skip = (seconds) => seek(audio.currentTime + seconds)
export const startOver = () => seek(0)

export function setSpeed(speed) {
  player.speed = speed
  audio.defaultPlaybackRate = speed
  audio.playbackRate = speed
  storage.set('myfiles-audio-speed', String(speed))
}

export function next() {
  const entry = nextInPlaylist()
  if (entry) playFile(entry)
}

// Back to the start of this file or, if it's only just started, the previous one.
export function previous() {
  const entry = previousInPlaylist()
  if (entry && audio.currentTime < 5) playFile(entry)
  else seek(0)
}

// Close the player (the position is kept).
export function stop() {
  savePosition()
  audio.pause()
  audio.removeAttribute('src')
  audio.load()
  Object.assign(player, { node: null, playing: false, loading: false, position: 0, duration: 0, error: '', resumedFrom: null })
  if ('mediaSession' in navigator) navigator.mediaSession.metadata = null
}

audio.addEventListener('play', () => (player.playing = true))
audio.addEventListener('pause', () => {
  player.playing = false
  savePosition()
})
audio.addEventListener('waiting', () => (player.loading = true))
audio.addEventListener('playing', () => (player.loading = false))
audio.addEventListener('canplay', () => (player.loading = false))
audio.addEventListener('durationchange', () => (player.duration = Number.isFinite(audio.duration) ? audio.duration : 0))
audio.addEventListener('timeupdate', () => {
  player.position = audio.currentTime
  if (Date.now() - lastSave >= SAVE_EVERY_MS) savePosition()
  updatePositionState()
})
audio.addEventListener('ended', () => {
  // Finished: next time it starts from the beginning. In the playlist: on to the next file.
  if (player.node) storage.set(posKey(player.node.id), null)
  player.playing = false
  player.resumedFrom = null
  if (player.node && inPlaylist(player.node.id) && nextInPlaylist()) next()
})
audio.addEventListener('error', () => {
  // (Replacing the file mid-load aborts it; that's not an error.)
  if (!player.node || !audio.error || audio.error.code === MediaError.MEDIA_ERR_ABORTED) return
  player.loading = false
  player.error = "This file can't be played"
})
window.addEventListener('pagehide', savePosition)

// ------------------------------------------------------------ media keys, lock screen

function updateMediaSession() {
  if (!('mediaSession' in navigator) || !player.node) return
  navigator.mediaSession.metadata = new MediaMetadata({ title: player.node.name, album: document.title })
  const handlers = {
    play,
    pause,
    seekbackward: () => skip(-BACK_SECONDS),
    seekforward: () => skip(FORWARD_SECONDS),
    seekto: (e) => seek(e.seekTime),
    previoustrack: previousInPlaylist() ? previous : null,
    nexttrack: nextInPlaylist() ? next : null,
  }
  for (const [action, handler] of Object.entries(handlers)) {
    try {
      navigator.mediaSession.setActionHandler(action, handler)
    } catch {
      // not supported by this browser
    }
  }
}

let lastPositionState = 0
function updatePositionState() {
  if (!('mediaSession' in navigator) || !navigator.mediaSession.setPositionState || Date.now() - lastPositionState < 1000) return
  lastPositionState = Date.now()
  if (!Number.isFinite(audio.duration) || audio.duration <= 0) return
  try {
    navigator.mediaSession.setPositionState({
      duration: audio.duration,
      playbackRate: audio.playbackRate,
      position: Math.min(audio.currentTime, audio.duration),
    })
  } catch {
    // ignore
  }
}

// ------------------------------------------------------------ playlist

function savePlaylist() {
  if (!userId) return
  storage.set(
    playlistKey(),
    player.playlist.length ? JSON.stringify({ entries: player.playlist, current: player.currentId }) : null,
  )
  updateMediaSession() // previous / next may have changed
}

function setCurrent(id) {
  if (player.currentId === id) return
  player.currentId = id
  savePlaylist()
}

// The file "Play" continues from.
export function currentEntry() {
  return player.playlist.find((e) => e.id === player.currentId) ?? player.playlist[0] ?? null
}

const collator = new Intl.Collator(undefined, { numeric: true, sensitivity: 'base' })

// Add the audio files among `nodes` to the end of the playlist; a folder adds the
// audio files directly inside it, by name. Returns { found, added }.
export async function addToPlaylist(nodes) {
  const files = []
  for (const node of nodes) {
    if (node.is_dir) {
      const { items } = await api.folder(node.id)
      files.push(...items.filter((i) => !i.is_dir && i.kind === 'audio').sort((a, b) => collator.compare(a.name, b.name)))
    } else if (node.kind === 'audio') files.push(node)
  }
  let added = 0
  for (const f of files) {
    if (inPlaylist(f.id)) continue
    player.playlist.push({ id: f.id, name: f.name, size: f.size })
    added++
  }
  if (added) savePlaylist()
  return { found: files.length, added }
}

export function removeFromPlaylist(id) {
  player.playlist = player.playlist.filter((e) => e.id !== id)
  if (player.currentId === id) player.currentId = null
  savePlaylist()
}

export function moveInPlaylist(from, to) {
  if (from === to) return
  const [entry] = player.playlist.splice(from, 1)
  player.playlist.splice(to, 0, entry)
  savePlaylist()
}

// Random order; the file you're on moves to the top, so playback carries on from there.
export function shufflePlaylist() {
  const list = [...player.playlist]
  for (let i = list.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1))
    ;[list[i], list[j]] = [list[j], list[i]]
  }
  const keep = player.currentId != null ? currentEntry() : null
  player.playlist = keep ? [keep, ...list.filter((e) => e !== keep)] : list
  savePlaylist()
}

export function clearPlaylist() {
  player.playlist = []
  player.currentId = null
  savePlaylist()
}

// Play the playlist from the file you were on (at its saved position), or from `entry`.
export function playPlaylist(entry) {
  const start = entry ?? currentEntry()
  if (start) playFile(start)
}
