<script setup>
import { ref } from 'vue'
import { api } from '../api'

const props = defineProps({ config: Object })
const emit = defineEmits(['signed-in'])

const mode = ref('login')
const username = ref('')
const password = ref('')
const password2 = ref('')
const inviteCode = ref('')
const error = ref('')
const busy = ref(false)

function switchMode(m) {
  mode.value = m
  error.value = ''
}

async function submit() {
  error.value = ''
  if (mode.value === 'register' && password.value !== password2.value) {
    error.value = "Passwords don't match"
    return
  }
  busy.value = true
  try {
    const user = mode.value === 'login'
      ? await api.login(username.value, password.value)
      : await api.register(username.value, password.value, inviteCode.value)
    emit('signed-in', user)
  } catch (e) {
    error.value = e.message
  } finally {
    busy.value = false
  }
}
</script>

<template>
  <div class="flex min-h-full items-center justify-center bg-slate-50 px-4">
    <div class="w-full max-w-sm">
      <div class="mb-6 flex items-center justify-center gap-2 text-2xl font-semibold">
        <img :src="'favicon.svg'" class="h-8 w-8" alt="" />
        {{ props.config.app_name }}
      </div>
      <form class="space-y-4 rounded-xl border border-slate-200 bg-surface p-6 shadow-sm" @submit.prevent="submit">
        <h1 class="text-lg font-medium">{{ mode === 'login' ? 'Sign in' : 'Create an account' }}</h1>
        <label class="block text-sm">
          <span class="mb-1 block text-slate-600">Username</span>
          <input v-model="username" class="input" autocomplete="username" required autofocus />
        </label>
        <label class="block text-sm">
          <span class="mb-1 block text-slate-600">Password</span>
          <input
            v-model="password" type="password" class="input" required
            :autocomplete="mode === 'login' ? 'current-password' : 'new-password'"
            :minlength="mode === 'register' ? 8 : undefined"
          />
        </label>
        <template v-if="mode === 'register'">
          <label class="block text-sm">
            <span class="mb-1 block text-slate-600">Repeat password</span>
            <input v-model="password2" type="password" class="input" autocomplete="new-password" required />
          </label>
          <label v-if="props.config.invite_required" class="block text-sm">
            <span class="mb-1 block text-slate-600">Invite code</span>
            <input v-model="inviteCode" class="input" required />
          </label>
        </template>
        <p v-if="error" class="rounded-md bg-red-50 px-3 py-2 text-sm text-red-700 dark:text-red-300">{{ error }}</p>
        <button class="btn btn-primary w-full justify-center py-2" :disabled="busy">
          {{ mode === 'login' ? 'Sign in' : 'Create account' }}
        </button>
      </form>
      <p v-if="props.config.registration_open" class="mt-4 text-center text-sm text-slate-600">
        <template v-if="mode === 'login'">
          No account yet?
          <button class="text-blue-600 hover:underline" @click="switchMode('register')">Register</button>
        </template>
        <template v-else>
          Already registered?
          <button class="text-blue-600 hover:underline" @click="switchMode('login')">Sign in</button>
        </template>
      </p>
    </div>
  </div>
</template>
