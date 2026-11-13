// Copy text to the clipboard. navigator.clipboard only exists on HTTPS (or
// localhost), so fall back to the old execCommand trick for plain-HTTP testing.
export async function copyText(text) {
  if (navigator.clipboard && window.isSecureContext) {
    await navigator.clipboard.writeText(text)
    return
  }
  const el = document.createElement('textarea')
  el.value = text
  el.setAttribute('readonly', '')
  el.style.position = 'fixed'
  el.style.opacity = '0'
  document.body.appendChild(el)
  el.select()
  const ok = document.execCommand('copy')
  el.remove()
  if (!ok) throw new Error('Copy failed')
}

// Folder icon colors a user can choose (keys match FOLDER_COLORS in the backend).
// Full class names are spelled out so Tailwind includes them in the build.
export const FOLDER_COLORS = {
  amber: { label: 'Yellow', icon: 'text-amber-500 fill-amber-400/80', swatch: 'bg-amber-400' },
  yellow: { label: 'Lemon', icon: 'text-yellow-500 fill-yellow-300/80', swatch: 'bg-yellow-300' },
  orange: { label: 'Orange', icon: 'text-orange-500 fill-orange-400/80', swatch: 'bg-orange-400' },
  red: { label: 'Red', icon: 'text-red-500 fill-red-400/80', swatch: 'bg-red-400' },
  rose: { label: 'Rose', icon: 'text-rose-500 fill-rose-400/80', swatch: 'bg-rose-400' },
  pink: { label: 'Pink', icon: 'text-pink-500 fill-pink-400/80', swatch: 'bg-pink-400' },
  fuchsia: { label: 'Magenta', icon: 'text-fuchsia-500 fill-fuchsia-400/80', swatch: 'bg-fuchsia-400' },
  purple: { label: 'Purple', icon: 'text-purple-500 fill-purple-400/80', swatch: 'bg-purple-400' },
  violet: { label: 'Violet', icon: 'text-violet-500 fill-violet-400/80', swatch: 'bg-violet-400' },
  indigo: { label: 'Indigo', icon: 'text-indigo-500 fill-indigo-400/80', swatch: 'bg-indigo-400' },
  blue: { label: 'Blue', icon: 'text-blue-500 fill-blue-400/80', swatch: 'bg-blue-400' },
  sky: { label: 'Sky', icon: 'text-sky-500 fill-sky-400/80', swatch: 'bg-sky-400' },
  cyan: { label: 'Cyan', icon: 'text-cyan-500 fill-cyan-400/80', swatch: 'bg-cyan-400' },
  teal: { label: 'Teal', icon: 'text-teal-500 fill-teal-400/80', swatch: 'bg-teal-400' },
  emerald: { label: 'Emerald', icon: 'text-emerald-600 fill-emerald-500/80', swatch: 'bg-emerald-500' },
  green: { label: 'Green', icon: 'text-green-600 fill-green-500/80', swatch: 'bg-green-500' },
  lime: { label: 'Lime', icon: 'text-lime-600 fill-lime-400/80', swatch: 'bg-lime-400' },
  brown: { label: 'Brown', icon: 'text-amber-800 fill-amber-700/80', swatch: 'bg-amber-700' },
  gray: { label: 'Gray', icon: 'text-zinc-500 fill-zinc-400/80', swatch: 'bg-zinc-400' },
  charcoal: { label: 'Charcoal', icon: 'text-zinc-700 fill-zinc-600/80', swatch: 'bg-zinc-600' },
}

// Display name of each user's top-level folder (matches ROOT_NAME in the backend).
export const ROOT_NAME = 'Home'

export const SHARE_MODES = {
  read: { label: 'Read only', help: 'Anyone with the link can view and download files.' },
  readwrite: { label: 'Read & write', help: 'Anyone with the link can view, download and upload files.' },
}
