export function formatSize(bytes) {
  if (bytes == null) return ''
  if (bytes < 1024) return `${bytes} B`
  const units = ['KB', 'MB', 'GB', 'TB']
  let value = bytes / 1024
  let i = 0
  while (value >= 1024 && i < units.length - 1) {
    value /= 1024
    i++
  }
  return `${value < 10 ? value.toFixed(1) : Math.round(value)} ${units[i]}`
}

const dateFormat = new Intl.DateTimeFormat(undefined, {
  year: 'numeric', month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit',
})

export function formatDate(iso) {
  return dateFormat.format(new Date(iso))
}

const KIND_LABELS = {
  folder: 'Folder', pdf: 'PDF document', image: 'image', audio: 'audio', video: 'video',
  text: 'text', archive: 'archive', other: 'file',
}

export function typeLabel(node) {
  if (node.is_dir) return 'Folder'
  if (node.kind === 'pdf') return KIND_LABELS.pdf
  const dot = node.name.lastIndexOf('.')
  const ext = dot > 0 ? node.name.slice(dot + 1).toUpperCase() : ''
  const label = KIND_LABELS[node.kind] ?? 'file'
  return ext ? `${ext} ${label}` : label.charAt(0).toUpperCase() + label.slice(1)
}

export const PREVIEWABLE = new Set(['pdf', 'image', 'audio', 'video', 'text'])
