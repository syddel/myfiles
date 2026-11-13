<script setup>
import Modal from './Modal.vue'

defineProps({ title: String, message: String, confirmText: String })
const emit = defineEmits(['close', 'confirm'])
</script>

<template>
  <Modal :title="title" @close="emit('close')">
    <p class="text-sm text-slate-600">{{ message }}</p>
    <template #footer>
      <button class="btn btn-ghost" @click="emit('close')">Cancel</button>
      <button class="btn btn-danger" autofocus @click="emit('confirm')">{{ confirmText }}</button>
    </template>
  </Modal>
</template>
