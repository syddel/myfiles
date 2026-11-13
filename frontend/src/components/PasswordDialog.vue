<script setup>
import { ref } from 'vue'
import { api } from '../api'
import { toast } from '../toast'
import Modal from './Modal.vue'

const emit = defineEmits(['close'])
const current = ref('')
const next = ref('')
const repeat = ref('')
const error = ref('')

async function submit() {
  error.value = ''
  if (next.value !== repeat.value) {
    error.value = "New passwords don't match"
    return
  }
  try {
    await api.changePassword(current.value, next.value)
    toast('Password changed')
    emit('close')
  } catch (e) {
    error.value = e.message
  }
}
</script>

<template>
  <Modal title="Change password" @close="emit('close')">
    <form id="pw-form" class="space-y-3" @submit.prevent="submit">
      <label class="block text-sm">
        <span class="mb-1 block text-slate-600">Current password</span>
        <input v-model="current" type="password" class="input" autocomplete="current-password" required autofocus />
      </label>
      <label class="block text-sm">
        <span class="mb-1 block text-slate-600">New password</span>
        <input v-model="next" type="password" class="input" autocomplete="new-password" minlength="8" required />
      </label>
      <label class="block text-sm">
        <span class="mb-1 block text-slate-600">Repeat new password</span>
        <input v-model="repeat" type="password" class="input" autocomplete="new-password" required />
      </label>
      <p v-if="error" class="rounded-md bg-red-50 px-3 py-2 text-sm text-red-700 dark:text-red-300">{{ error }}</p>
    </form>
    <template #footer>
      <button class="btn btn-ghost" @click="emit('close')">Cancel</button>
      <button class="btn btn-primary" type="submit" form="pw-form">Change password</button>
    </template>
  </Modal>
</template>
