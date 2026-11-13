<script setup>
import { computed, ref } from 'vue'
import { api } from '../api'
import { formatSize } from '../format'
import { toast } from '../toast'
import Modal from './Modal.vue'

const GB = 1024 ** 3
// user: a row from the admin users list; defaultQuota: bytes, or null for unlimited
const props = defineProps({ user: Object, defaultQuota: Number })
const emit = defineEmits(['close', 'saved'])

const mode = ref(props.user.quota_mode)
const gb = ref(
  props.user.quota_mode === 'custom' ? +(props.user.quota_bytes / GB).toFixed(2) : Math.round((props.defaultQuota ?? 15 * GB) / GB),
)
const busy = ref(false)

const valid = computed(() => mode.value !== 'custom' || (Number(gb.value) > 0 && Number(gb.value) <= 1_000_000))
// What the quota would be after saving, to warn if it's below what they already use.
const newQuota = computed(() => {
  if (mode.value === 'unlimited') return null
  if (mode.value === 'default') return props.defaultQuota
  return Number(gb.value) * GB
})
const overAfterSave = computed(() => valid.value && newQuota.value != null && props.user.used_bytes > newQuota.value)

async function save() {
  if (!valid.value) return
  busy.value = true
  try {
    const body = mode.value === 'custom' ? { mode: 'custom', gb: Number(gb.value) } : { mode: mode.value }
    const updated = await api.setUserQuota(props.user.id, body)
    toast(`Quota for ${updated.username} is now ${updated.quota_bytes == null ? 'unlimited' : formatSize(updated.quota_bytes)}`)
    emit('saved', updated)
  } catch (e) {
    toast(e.message, 'error')
  } finally {
    busy.value = false
  }
}
</script>

<template>
  <Modal :title="`Storage quota for ${user.username}`" @close="emit('close')">
    <form id="quota-form" class="space-y-2 text-sm" @submit.prevent="save">
      <p class="mb-3 text-slate-600">Currently using {{ formatSize(user.used_bytes) }} in {{ user.file_count }} {{ user.file_count === 1 ? 'file' : 'files' }}.</p>
      <label
        v-for="option in [
          { key: 'default', label: `Default (${defaultQuota == null ? 'unlimited' : formatSize(defaultQuota)})`, help: 'Follows DEFAULT_QUOTA_GB in .env' },
          { key: 'custom', label: 'Custom', help: 'A quota just for this user' },
          { key: 'unlimited', label: 'Unlimited', help: 'No limit; only the disk’s free space' },
        ]"
        :key="option.key"
        class="flex cursor-pointer items-start gap-3 rounded-lg border p-3"
        :class="mode === option.key ? 'border-blue-500 bg-blue-50' : 'border-slate-200 hover:bg-slate-50'"
      >
        <input v-model="mode" type="radio" name="quota-mode" class="mt-0.5" :value="option.key" />
        <span class="flex-1">
          <span class="block font-medium">{{ option.label }}</span>
          <span class="block text-slate-500">{{ option.help }}</span>
          <span v-if="option.key === 'custom' && mode === 'custom'" class="mt-2 flex items-center gap-2">
            <input
              v-model="gb"
              type="number"
              min="0.01"
              step="any"
              class="input w-32"
              aria-label="Quota in GB"
              autofocus
            />
            <span class="text-slate-600">GB</span>
          </span>
        </span>
      </label>
      <p v-if="overAfterSave" class="rounded-md bg-amber-50 px-3 py-2 text-amber-800 dark:text-amber-200">
        {{ user.username }} already uses more than this. Their files are kept, but they won’t be able to upload
        until they free up space.
      </p>
    </form>
    <template #footer>
      <button class="btn btn-ghost" @click="emit('close')">Cancel</button>
      <button class="btn btn-primary" type="submit" form="quota-form" :disabled="busy || !valid">Save</button>
    </template>
  </Modal>
</template>
