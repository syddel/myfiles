<script setup>
import { onMounted, ref, watch } from 'vue'
import { SHARE_TOKEN_RE, api, onUnauthorized } from './api'
import { applyUserPrefs } from './prefs'
import { toasts } from './toast'
import AuthScreen from './components/AuthScreen.vue'
import FileBrowser from './components/FileBrowser.vue'
import ShareView from './components/ShareView.vue'

// A share link is <app address>/<token>: show that shared folder, no sign-in needed.
const lastSegment = location.pathname.split('/').pop()
const shareToken = SHARE_TOKEN_RE.test(lastSegment) ? lastSegment : null

const user = ref(null)
const config = ref(null)
const loading = ref(true)

onUnauthorized(() => (user.value = null))
watch(user, applyUserPrefs)

onMounted(async () => {
  if (shareToken) return
  config.value = await api.config()
  document.title = config.value.app_name
  try {
    user.value = await api.me()
  } catch {
    user.value = null
  }
  loading.value = false
})

async function logout() {
  await api.logout().catch(() => {})
  // Forget the folder/page in the address (#/folder/…, #/shared), so whoever signs in
  // next starts at their own Home rather than at this user's folder.
  history.replaceState(null, '', location.pathname + location.search)
  user.value = null
}
</script>

<template>
  <ShareView v-if="shareToken" :token="shareToken" />
  <div v-else-if="loading" class="flex h-full items-center justify-center text-slate-400">Loading…</div>
  <AuthScreen v-else-if="!user" :config="config" @signed-in="user = $event" />
  <FileBrowser v-else :user="user" :config="config" @logout="logout" />

  <div class="pointer-events-none fixed top-4 left-1/2 z-[60] flex -translate-x-1/2 flex-col items-center gap-2">
    <TransitionGroup name="toast">
      <div
        v-for="t in toasts.items"
        :key="t.id"
        class="pointer-events-auto rounded-lg px-4 py-2 text-sm shadow-lg"
        :class="t.type === 'error' ? 'bg-red-600 text-white' : 'keep-colors bg-slate-800 text-white'"
      >
        {{ t.message }}
      </div>
    </TransitionGroup>
  </div>
</template>

<style>
.toast-enter-active, .toast-leave-active { transition: all 0.2s ease; }
.toast-enter-from, .toast-leave-to { opacity: 0; transform: translateY(-8px); }
</style>
