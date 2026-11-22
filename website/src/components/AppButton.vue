<template>
  <button class="app-button" :class="variant" :disabled="disabled" @click="$emit('click')">
    <slot />
  </button>
</template>

<script setup>
defineProps({
  variant: {
    type: String,
    default: 'primary'
  },
  disabled: {
    type: Boolean,
    default: false
  }
})

defineEmits(['click'])
</script>

<style scoped>
.app-button {
  border: none;
  border-radius: 8px;
  padding: 0.6rem 1.1rem;
  font-size: 0.95rem;
  font-weight: 600;
  cursor: pointer;
  transition: background 0.15s ease;
}

.app-button:disabled {
  opacity: 0.5;
  cursor: not-allowed;
}

.primary {
  background: #2563eb;
  color: #fff;
}

.primary:hover:not(:disabled) {
  background: #1d4ed8;
}

.secondary {
  background: #e4e7eb;
  color: #3e4c59;
}

.secondary:hover:not(:disabled) {
  background: #d4d9df;
}

.danger {
  background: #d64545;
  color: #fff;
}

.danger:hover:not(:disabled) {
  background: #b83434;
}
</style>
