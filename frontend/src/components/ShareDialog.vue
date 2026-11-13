<script setup>
import { computed, onMounted, ref } from 'vue'
import { Check, Copy, ExternalLink, Eye, EyeOff, Lock } from 'lucide-vue-next'
import { api, shareLink } from '../api'
import { toast } from '../toast'
import { ROOT_NAME, SHARE_MODES, copyText } from '../utils'
import Modal from './Modal.vue'

// node: the folder or file to share ({ id, name, is_dir }). Files can only be shared read-only.
const props = defineProps({ node: Object })
const emit = defineEmits(['close', 'changed'])

const share = ref(null)
const loading = ref(true)
const busy = ref(false)
const mode = ref('read')
const copied = ref(false)
const confirmStop = ref(false)

// Optional password: visitors then need the link and the password.
const MIN_PASSWORD = 4
const usePassword = ref(false) // "Require a password" ticked (no password set yet)
const changingPassword = ref(false) // replacing an existing password
const password = ref('')
const showPassword = ref(false)
const passwordValid = computed(() => password.value.length >= MIN_PASSWORD)

const link = computed(() => (share.value ? shareLink(share.value) : ''))
const title = computed(() => `Share "${props.node.name || ROOT_NAME}"`)

onMounted(async () => {
  try {
    share.value = await api.getShare(props.node.id)
    if (share.value) mode.value = share.value.mode
  } catch (e) {
    toast(e.message, 'error')
    emit('close')
  } finally {
    loading.value = false
  }
})

async function save(newMode) {
  const wasShared = !!share.value
  if (!wasShared && usePassword.value && !passwordValid.value) {
    toast(`The password must be at least ${MIN_PASSWORD} characters`, 'error')
    return
  }
  busy.value = true
  try {
    share.value = await api.setShare(props.node.id, newMode)
    if (!wasShared && usePassword.value) {
      share.value = await api.setSharePassword(props.node.id, password.value)
      resetPasswordForm()
    }
    mode.value = share.value.mode
    emit('changed')
    if (!wasShared) await copy()
    else toast(`Link is now ${SHARE_MODES[newMode].label.toLowerCase()}`)
  } catch (e) {
    toast(e.message, 'error')
  } finally {
    busy.value = false
  }
}

function resetPasswordForm() {
  usePassword.value = false
  changingPassword.value = false
  password.value = ''
  showPassword.value = false
}

async function savePassword() {
  if (!passwordValid.value) return
  const changing = share.value.has_password
  busy.value = true
  try {
    share.value = await api.setSharePassword(props.node.id, password.value)
    resetPasswordForm()
    emit('changed')
    toast(changing ? 'Password changed; anyone using the old one must enter the new one' : 'Password set')
  } catch (e) {
    toast(e.message, 'error')
  } finally {
    busy.value = false
  }
}

async function removePassword() {
  busy.value = true
  try {
    share.value = await api.setSharePassword(props.node.id, null)
    resetPasswordForm()
    emit('changed')
    toast('Password removed; anyone with the link can open it')
  } catch (e) {
    toast(e.message, 'error')
  } finally {
    busy.value = false
  }
}

async function stop() {
  busy.value = true
  try {
    await api.stopSharing(props.node.id)
    emit('changed')
    toast('Sharing turned off; the old link no longer works')
    // Close rather than fall back to the "Create link" view, which would be confusing here.
    emit('close')
  } catch (e) {
    toast(e.message, 'error')
  } finally {
    busy.value = false
  }
}

async function copy() {
  try {
    await copyText(link.value)
    copied.value = true
    toast('Link copied')
    setTimeout(() => (copied.value = false), 2000)
  } catch {
    toast('Couldn’t copy automatically; select the link and copy it', 'error')
  }
}

function onModeChange(m) {
  mode.value = m
  if (share.value && share.value.mode !== m) save(m)
}
</script>

<template>
  <Modal :title="title" wide @close="emit('close')">
    <div v-if="loading" class="py-6 text-center text-sm text-slate-400">Loading…</div>
    <div v-else class="space-y-4 text-sm">
      <p v-if="!share" class="text-slate-600">
        <template v-if="node.is_dir">
          Create a link that lets anyone open this folder, including everything inside it. No account is needed.
        </template>
        <template v-else>Create a link that lets anyone view and download this file. No account is needed.</template>
      </p>

      <p v-if="!node.is_dir" class="rounded-md bg-slate-50 px-3 py-2 text-slate-600">
        People with the link can <b>view and download</b> this file. They can’t change it.
      </p>
      <fieldset v-else class="space-y-2">
        <legend class="mb-1 font-medium text-slate-700">People with the link can</legend>
        <label
          v-for="(info, key) in SHARE_MODES"
          :key="key"
          class="flex cursor-pointer items-start gap-3 rounded-lg border p-3"
          :class="mode === key ? 'border-blue-500 bg-blue-50' : 'border-slate-200 hover:bg-slate-50'"
        >
          <input type="radio" name="share-mode" class="mt-0.5" :value="key" :checked="mode === key" :disabled="busy" @change="onModeChange(key)" />
          <span>
            <span class="block font-medium">{{ info.label }}</span>
            <span class="block text-slate-500">{{ info.help }}</span>
          </span>
        </label>
      </fieldset>

      <div class="rounded-lg border border-slate-200 p-3">
        <div v-if="share?.has_password && !changingPassword" class="flex items-center gap-2">
          <Lock :size="16" class="shrink-0 text-slate-500" />
          <span class="flex-1"><b>Password protected.</b> Visitors need the link and the password.</span>
          <button class="btn btn-ghost px-2" :disabled="busy" @click="changingPassword = true">Change</button>
          <button class="btn btn-ghost-danger px-2" :disabled="busy" @click="removePassword">Remove</button>
        </div>
        <template v-else>
          <label v-if="!share?.has_password" class="flex cursor-pointer items-center gap-2">
            <input v-model="usePassword" type="checkbox" :disabled="busy" />
            <span class="font-medium">Require a password</span>
          </label>
          <div v-if="usePassword || changingPassword" class="mt-2 flex gap-2">
            <input
              v-model="password"
              :type="showPassword ? 'text' : 'password'"
              class="input"
              :placeholder="`${changingPassword ? 'New password' : 'Password'} (at least ${MIN_PASSWORD} characters)`"
              autocomplete="new-password"
              @keydown.enter.prevent="share && savePassword()"
            />
            <button
              type="button"
              class="btn btn-ghost shrink-0 px-2"
              :title="showPassword ? 'Hide password' : 'Show password'"
              @click="showPassword = !showPassword"
            >
              <EyeOff v-if="showPassword" :size="16" /><Eye v-else :size="16" />
            </button>
            <button v-if="share" class="btn btn-primary shrink-0" :disabled="busy || !passwordValid" @click="savePassword">
              Save
            </button>
            <button v-if="changingPassword" class="btn btn-ghost shrink-0" @click="resetPasswordForm">Cancel</button>
          </div>
          <p v-if="usePassword || changingPassword" class="mt-2 text-xs text-slate-500">
            Send the password separately from the link (for example by text message).
          </p>
        </template>
      </div>

      <template v-if="share">
        <div>
          <div class="mb-1 font-medium text-slate-700">Link</div>
          <div class="flex gap-2">
            <input :value="link" readonly class="input font-mono text-xs" @focus="$event.target.select()" />
            <button class="btn btn-primary shrink-0" @click="copy">
              <Check v-if="copied" :size="16" /><Copy v-else :size="16" /> {{ copied ? 'Copied' : 'Copy' }}
            </button>
            <a :href="link" target="_blank" rel="noopener" class="btn btn-ghost shrink-0" title="Open link in a new tab">
              <ExternalLink :size="16" />
            </a>
          </div>
        </div>
        <p v-if="share.mode === 'readwrite'" class="rounded-md bg-amber-50 px-3 py-2 text-amber-800 dark:text-amber-200">
          Visitors can add files to this folder, but they can’t delete, rename or move anything.
        </p>
      </template>
    </div>

    <template #footer>
      <template v-if="share">
        <template v-if="confirmStop">
          <span class="mr-auto self-center text-sm text-slate-600">The link will stop working.</span>
          <button class="btn btn-ghost" @click="confirmStop = false">Keep sharing</button>
          <button class="btn btn-danger" :disabled="busy" @click="stop">Stop sharing</button>
        </template>
        <template v-else>
          <button class="btn btn-ghost-danger mr-auto" :disabled="busy" @click="confirmStop = true">
            Stop sharing
          </button>
          <button class="btn btn-ghost" @click="emit('close')">Done</button>
        </template>
      </template>
      <template v-else-if="!loading">
        <button class="btn btn-ghost" @click="emit('close')">Cancel</button>
        <button class="btn btn-primary" :disabled="busy" @click="save(mode)">Create link</button>
      </template>
    </template>
  </Modal>
</template>
