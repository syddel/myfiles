<script setup>
import { nextTick, onMounted, ref } from 'vue'
import Modal from './Modal.vue'

const props = defineProps({ title: String, label: String, initial: { type: String, default: '' }, confirmText: String })
const emit = defineEmits(['close', 'submit'])
const value = ref(props.initial)
const input = ref(null)

onMounted(async () => {
  await nextTick()
  input.value.focus()
  // Select the name without its extension, like a file explorer does.
  const dot = props.initial.lastIndexOf('.')
  input.value.setSelectionRange(0, dot > 0 ? dot : props.initial.length)
})

function submit() {
  if (value.value.trim()) emit('submit', value.value.trim())
}
</script>

<template>
  <Modal :title="title" @close="emit('close')">
    <form @submit.prevent="submit">
      <label class="block text-sm">
        <span class="mb-1 block text-slate-600">{{ label }}</span>
        <input ref="input" v-model="value" class="input" />
      </label>
    </form>
    <template #footer>
      <button class="btn btn-ghost" @click="emit('close')">Cancel</button>
      <button class="btn btn-primary" :disabled="!value.trim()" @click="submit">{{ confirmText }}</button>
    </template>
  </Modal>
</template>
