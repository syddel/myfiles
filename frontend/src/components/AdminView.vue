<script setup>
// Admin page: every user's storage use and quota, with a way to change quotas.
import { computed, onMounted, ref } from 'vue'
import { Pencil, ShieldCheck } from 'lucide-vue-next'
import { api } from '../api'
import { formatDate, formatSize } from '../format'
import { toast } from '../toast'
import QuotaDialog from './QuotaDialog.vue'

defineProps({ me: Object })

const users = ref([])
const defaultQuota = ref(null)
const loading = ref(true)
const editing = ref(null)

async function load() {
  try {
    const data = await api.adminUsers()
    users.value = data.users
    defaultQuota.value = data.default_quota_bytes
  } catch (e) {
    toast(e.message, 'error')
  } finally {
    loading.value = false
  }
}
onMounted(load)

const totals = computed(() => ({
  used: users.value.reduce((t, u) => t + u.used_bytes, 0),
  files: users.value.reduce((t, u) => t + u.file_count, 0),
}))

function plural(n, word) {
  return `${n} ${word}${n === 1 ? '' : 's'}`
}

function percent(u) {
  return u.quota_bytes ? Math.min(100, (u.used_bytes / u.quota_bytes) * 100) : 0
}

function quotaLabel(u) {
  if (u.quota_mode === 'unlimited') return 'Unlimited'
  return formatSize(u.quota_bytes) + (u.quota_mode === 'default' ? ' (default)' : '')
}

function onSaved(updated) {
  users.value = users.value.map((u) => (u.id === updated.id ? updated : u))
  editing.value = null
}
</script>

<template>
  <div class="flex min-h-0 flex-1 flex-col">
    <div class="flex min-h-14 flex-wrap items-center gap-2 border-b border-slate-200 px-3 py-2 sm:px-5">
      <div class="flex-1">
        <h1 class="text-sm font-medium text-slate-900">Users and storage</h1>
        <p class="text-xs text-slate-500">
          Default quota: {{ defaultQuota == null ? 'unlimited' : formatSize(defaultQuota) }} (DEFAULT_QUOTA_GB in .env).
          {{ plural(users.length, 'user') }} · {{ formatSize(totals.used) }} in {{ plural(totals.files, 'file') }}.
        </p>
      </div>
    </div>

    <main class="min-h-0 flex-1 overflow-auto">
      <table v-if="users.length" class="w-full table-fixed border-collapse text-sm">
        <thead class="sticky top-0 z-10 bg-surface text-left text-xs text-slate-500">
          <tr class="border-b border-slate-200">
            <th class="px-3 py-2 font-medium sm:pl-5">User</th>
            <th class="hidden w-20 px-2 py-2 text-right font-medium md:table-cell">Files</th>
            <th class="w-36 px-2 py-2 font-medium sm:w-64">Storage used</th>
            <th class="hidden w-40 px-2 py-2 font-medium lg:table-cell">Quota</th>
            <th class="hidden w-32 px-2 py-2 font-medium xl:table-cell">Joined</th>
            <th class="w-12 px-2 py-2 pr-3 sm:w-44 sm:pr-5"></th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="u in users" :key="u.id" class="border-b border-slate-100 hover:bg-slate-50">
            <td class="px-3 py-2 sm:pl-5">
              <div class="flex min-w-0 items-center gap-1.5">
                <span class="truncate font-medium text-slate-800">{{ u.username }}</span>
                <ShieldCheck v-if="u.is_admin" :size="14" class="shrink-0 text-blue-600" aria-label="Administrator" />
                <span v-if="u.id === me.id" class="shrink-0 text-xs text-slate-400">(you)</span>
              </div>
            </td>
            <td class="hidden px-2 py-2 text-right text-slate-500 tabular-nums md:table-cell">{{ u.file_count }}</td>
            <td class="px-2 py-2">
              <div class="text-xs text-slate-600 tabular-nums">
                {{ formatSize(u.used_bytes) }}<template v-if="u.quota_bytes != null"> of {{ formatSize(u.quota_bytes) }}</template>
                <span v-if="u.quota_bytes != null && u.used_bytes >= u.quota_bytes" class="font-medium text-red-600"> · full</span>
              </div>
              <div v-if="u.quota_bytes != null" class="mt-1 h-1.5 overflow-hidden rounded-full bg-slate-200">
                <div
                  class="h-full rounded-full"
                  :class="percent(u) >= 95 ? 'bg-red-500' : percent(u) >= 80 ? 'bg-amber-500' : 'bg-blue-500'"
                  :style="{ width: percent(u) + '%' }"
                />
              </div>
              <div class="mt-0.5 text-xs text-slate-400 lg:hidden">Quota: {{ quotaLabel(u) }}</div>
            </td>
            <td class="hidden px-2 py-2 text-slate-600 lg:table-cell">{{ quotaLabel(u) }}</td>
            <td class="hidden px-2 py-2 whitespace-nowrap text-slate-500 xl:table-cell">{{ formatDate(u.created_at).split(',').slice(0, 2).join(',') }}</td>
            <td class="px-2 py-2 pr-3 text-right sm:pr-5">
              <button class="btn btn-ghost px-2 whitespace-nowrap" :title="`Change ${u.username}'s quota`" @click="editing = u">
                <Pencil :size="16" /><span class="hidden sm:inline">Change quota</span>
              </button>
            </td>
          </tr>
        </tbody>
      </table>
      <p v-else-if="!loading" class="px-5 py-10 text-center text-sm text-slate-500">No users.</p>
    </main>

    <QuotaDialog v-if="editing" :user="editing" :default-quota="defaultQuota" @close="editing = null" @saved="onSaved" />
  </div>
</template>
