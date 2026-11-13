import { reactive } from 'vue'

let nextId = 1
export const toasts = reactive({ items: [] })

export function toast(message, type = 'info') {
  const id = nextId++
  toasts.items.push({ id, message, type })
  setTimeout(() => {
    toasts.items = toasts.items.filter((t) => t.id !== id)
  }, type === 'error' ? 6000 : 3000)
}
