import { defineStore } from 'pinia'

export const useUiStore = defineStore('ui', {
  state: () => ({
    toast: null
  }),

  actions: {
    showToast(message, type = 'info') {
      this.toast = { message, type, id: Date.now() }
    },
    clearToast() {
      this.toast = null
    }
  }
})
