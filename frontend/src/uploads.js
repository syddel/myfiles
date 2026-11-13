// Upload queue shared by the file browser and the upload panel.
import { reactive } from 'vue'
import { uploadFile } from './api'

const MAX_PARALLEL = 3
let nextId = 1
let active = 0
const finishedListeners = new Set()

export const uploads = reactive({ items: [] })

export function onUploadFinished(fn) {
  finishedListeners.add(fn)
  return () => finishedListeners.delete(fn)
}

// entries: [{ file, relativeDir }]; endpoint differs for uploads through a share link.
export function enqueueUploads(entries, parentId, endpoint = 'api/upload') {
  for (const { file, relativeDir = '' } of entries) {
    uploads.items.push({
      id: nextId++,
      file,
      name: relativeDir ? `${relativeDir}/${file.name}` : file.name,
      size: file.size,
      loaded: 0,
      parentId,
      relativeDir,
      endpoint,
      status: 'queued', // queued | uploading | done | error | cancelled
      error: '',
      abort: null,
    })
  }
  pump()
}

function pump() {
  while (active < MAX_PARALLEL) {
    const item = uploads.items.find((i) => i.status === 'queued')
    if (!item) return
    start(item)
  }
}

function start(item) {
  active++
  item.status = 'uploading'
  const { promise, abort } = uploadFile(item, (loaded) => (item.loaded = loaded))
  item.abort = abort
  promise
    .then((node) => {
      item.status = 'done'
      item.loaded = item.size
      finishedListeners.forEach((fn) => fn(item, node))
    })
    .catch((err) => {
      if (item.status === 'cancelled') return
      item.status = 'error'
      item.error = err.message
    })
    .finally(() => {
      item.abort = null
      item.file = null // let the browser release the File
      active--
      pump()
    })
}

export function cancelUpload(item) {
  if (item.status === 'queued' || item.status === 'uploading') {
    const abort = item.abort
    item.status = 'cancelled'
    abort?.()
  }
}

export function cancelAll() {
  uploads.items.forEach(cancelUpload)
}

export function clearFinished() {
  uploads.items = uploads.items.filter((i) => i.status === 'queued' || i.status === 'uploading')
}

// Collect files from a drag-and-drop, descending into dropped folders.
export async function filesFromDrop(dataTransfer) {
  // Entries must be read synchronously, before the first await.
  const entries = [...dataTransfer.items].map((i) => i.webkitGetAsEntry?.()).filter(Boolean)
  if (!entries.length) return [...dataTransfer.files].map((file) => ({ file, relativeDir: '' }))
  const out = []
  async function walk(entry, dir) {
    if (entry.isFile) {
      const file = await new Promise((res, rej) => entry.file(res, rej))
      out.push({ file, relativeDir: dir })
    } else if (entry.isDirectory) {
      const reader = entry.createReader()
      const sub = dir ? `${dir}/${entry.name}` : entry.name
      let batch
      do {
        batch = await new Promise((res, rej) => reader.readEntries(res, rej))
        for (const child of batch) await walk(child, sub)
      } while (batch.length)
    }
  }
  for (const entry of entries) await walk(entry, '')
  return out
}

// Files chosen with <input webkitdirectory> carry their path in webkitRelativePath.
export function filesFromInput(fileList) {
  return [...fileList].map((file) => {
    const path = file.webkitRelativePath || ''
    return { file, relativeDir: path.includes('/') ? path.slice(0, path.lastIndexOf('/')) : '' }
  })
}
