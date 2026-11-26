// "3:07" / "1:02:09"
export function formatTime(seconds) {
  const s = Math.max(0, Math.floor(seconds || 0))
  const two = (n) => String(n).padStart(2, '0')
  return s >= 3600 ? `${Math.floor(s / 3600)}:${two(Math.floor(s / 60) % 60)}:${two(s % 60)}` : `${Math.floor(s / 60)}:${two(s % 60)}`
}

const plural = (n, word) => `${n} ${word}${n === 1 ? '' : 's'}`

// The message after "Add to playlist": { found, added } from addToPlaylist().
export function playlistAddedMessage({ found, added }) {
  if (!found) return 'There are no audio files to add'
  if (!added) return found === 1 ? 'Already in the playlist' : 'Those are all in the playlist already'
  const already = found - added
  return `Added ${plural(added, 'file')} to the playlist${already ? ` (${already} already in it)` : ''}`
}
