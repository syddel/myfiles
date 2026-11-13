// Thin wrapper around the backend's JSON API. All paths are relative so the
// app works when served under a sub-path (e.g. https://example.com/files/).

export class ApiError extends Error {
  constructor(status, message) {
    super(message)
    this.status = status
  }
}

let unauthorizedHandler = () => {}
export function onUnauthorized(handler) {
  unauthorizedHandler = handler
}

function errorMessage(data, fallback) {
  const detail = data?.detail
  if (Array.isArray(detail)) return detail[0]?.msg ?? fallback
  return detail || fallback
}

async function request(method, path, body) {
  const headers = { 'X-Requested-With': 'myfiles' }
  if (body !== undefined) headers['Content-Type'] = 'application/json'
  const res = await fetch('api/' + path, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
    credentials: 'same-origin',
  })
  if (res.status === 204) return null
  const data = await res.json().catch(() => null)
  if (!res.ok) {
    // On share links (s/…) a 401 means "password needed", not "signed out".
    if (res.status === 401 && !path.startsWith('auth/') && !path.startsWith('s/')) unauthorizedHandler()
    throw new ApiError(res.status, errorMessage(data, res.statusText))
  }
  return data
}

export const api = {
  config: () => request('GET', 'config'),
  me: () => request('GET', 'auth/me'),
  login: (username, password) => request('POST', 'auth/login', { username, password }),
  register: (username, password, invite_code) =>
    request('POST', 'auth/register', { username, password, invite_code }),
  logout: () => request('POST', 'auth/logout'),
  setPreferences: (prefs) => request('PUT', 'auth/preferences', prefs),
  changePassword: (current_password, new_password) =>
    request('POST', 'auth/password', { current_password, new_password }),

  folder: (id) => request('GET', `folders/${id}`),
  allFolders: () => request('GET', 'folders'),
  search: (q) => request('GET', `search?q=${encodeURIComponent(q)}`),
  stats: () => request('GET', 'stats'),

  adminUsers: () => request('GET', 'admin/users'),
  // quota: { mode: 'default' | 'unlimited' } or { mode: 'custom', gb: 50 }
  setUserQuota: (userId, quota) => request('PUT', `admin/users/${userId}/quota`, quota),

  shares: () => request('GET', 'shares'),
  getShare: (folderId) => request('GET', `shares/${folderId}`),
  setShare: (folderId, mode) => request('PUT', `shares/${folderId}`, { mode }),
  stopSharing: (folderId) => request('DELETE', `shares/${folderId}`),
  // password: a string to set or change it, null to remove it
  setSharePassword: (nodeId, password) => request('PUT', `shares/${nodeId}/password`, { password }),

  createFolder: (parent_id, name) => request('POST', 'folders', { parent_id, name }),
  rename: (id, name) => request('PATCH', `nodes/${id}`, { name }),
  move: (ids, target_id) => request('POST', 'nodes/move', { ids, target_id }),
  remove: (ids) => request('POST', 'nodes/delete', { ids }),
}

// Endpoints used by visitors of a share link (no account needed).
export function shareApi(token) {
  const base = `s/${encodeURIComponent(token)}`
  return {
    info: () => request('GET', base),
    unlock: (password) => request('POST', `${base}/unlock`, { password }),
    folder: (id) => request('GET', `${base}/folders/${id}`),
    contentUrl: (id, download = false) => `api/${base}/files/${id}/content${download ? '?download=1' : ''}`,
    zipUrl: (ids) => `api/${base}/zip?${ids.map((id) => `ids=${id}`).join('&')}`,
    uploadEndpoint: `api/${base}/upload`,
  }
}

// Share tokens are 32 URL-safe characters; a share link is <app address>/<token>.
export const SHARE_TOKEN_RE = /^[A-Za-z0-9_-]{32}$/

export function shareLink(share) {
  if (share.url) return share.url
  // BASE_URL isn't configured: build the link from the address the app is running at.
  return location.origin + location.pathname.replace(/[^/]*$/, '') + share.token
}

export function zipUrl(ids) {
  return `api/zip?${ids.map((id) => `ids=${id}`).join('&')}`
}

export function contentUrl(id, download = false) {
  return `api/files/${id}/content${download ? '?download=1' : ''}`
}

// Upload one file with progress reporting. fetch() can't report upload
// progress, so this uses XMLHttpRequest. Returns { promise, abort }.
export function uploadFile({ file, parentId, relativeDir = '', endpoint = 'api/upload' }, onProgress) {
  const xhr = new XMLHttpRequest()
  const params = new URLSearchParams({ parent_id: parentId, name: file.name, relative_dir: relativeDir })
  const promise = new Promise((resolve, reject) => {
    xhr.open('POST', `${endpoint}?${params}`)
    xhr.setRequestHeader('X-Requested-With', 'myfiles')
    xhr.setRequestHeader('Content-Type', 'application/octet-stream')
    xhr.upload.onprogress = (e) => e.lengthComputable && onProgress(e.loaded)
    xhr.onload = () => {
      let data = null
      try { data = JSON.parse(xhr.responseText) } catch { /* not JSON */ }
      if (xhr.status >= 200 && xhr.status < 300) resolve(data)
      else {
        if (xhr.status === 401) unauthorizedHandler()
        reject(new ApiError(xhr.status, errorMessage(data, `Upload failed (${xhr.status})`)))
      }
    }
    xhr.onerror = () => reject(new ApiError(0, 'Network error'))
    xhr.onabort = () => reject(new ApiError(0, 'Cancelled'))
    xhr.send(file)
  })
  return { promise, abort: () => xhr.abort() }
}
