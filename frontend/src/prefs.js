// The signed-in user's display preferences, shared by every component.
import { reactive } from 'vue'
import { api } from './api'
import { toast } from './toast'

// The theme is also kept in this browser, so the login page and share links use it,
// and index.html can apply it before the page is drawn (no white flash in dark mode).
const THEME_KEY = 'myfiles-theme'
const darkQuery = window.matchMedia('(prefers-color-scheme: dark)')

function storedTheme() {
  try {
    return localStorage.getItem(THEME_KEY) || 'system'
  } catch {
    return 'system'
  }
}

export const prefs = reactive({ folderColor: 'amber', theme: storedTheme() })

function updateDocumentTheme() {
  const dark = prefs.theme === 'dark' || (prefs.theme === 'system' && darkQuery.matches)
  document.documentElement.classList.toggle('dark', dark)
}

// theme: "system" (follow the device), "light" or "dark"
export function setTheme(theme) {
  prefs.theme = theme
  try {
    localStorage.setItem(THEME_KEY, theme)
  } catch {
    // private browsing etc.: the theme still applies for this visit
  }
  updateDocumentTheme()
}

darkQuery.addEventListener('change', updateDocumentTheme)
updateDocumentTheme()

// Saves go out one at a time, in order, so quick successive changes can't land out of order.
let saving = Promise.resolve()

// fields: e.g. { theme: 'dark' }. undo() puts the previous value back if the save fails.
export function savePrefs(fields, undo) {
  saving = saving.then(async () => {
    try {
      await api.setPreferences(fields)
    } catch (e) {
      undo()
      toast(e.message, 'error')
    }
  })
  return saving
}

export function applyUserPrefs(user) {
  prefs.folderColor = user?.folder_color || 'amber'
  if (user?.theme) setTheme(user.theme)
}
