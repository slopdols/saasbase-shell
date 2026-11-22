<template>
  <div class="app-shell">
    <AppHeader />
    <main class="app-main">
      <div v-if="ui.toast" class="app-notice" :role="ui.toast.type === 'error' ? 'alert' : 'status'">
        <span>{{ ui.toast.message }}</span>
        <button type="button" @click="ui.clearToast()">{{ t('app.dismissNotice') }}</button>
      </div>
      <router-view />
    </main>
    <footer class="app-footer">
      <span>© {{ year }} Saasbase</span>
    </footer>
  </div>
</template>

<script setup>
import { computed } from 'vue'
import { useI18n } from 'vue-i18n'
import AppHeader from '@/components/AppHeader.vue'
import { useUiStore } from '@/stores/ui'

const year = computed(() => new Date().getFullYear())
const ui = useUiStore()
const { t } = useI18n()
</script>

<style>
* {
  box-sizing: border-box;
}

body {
  margin: 0;
  font-family: 'Segoe UI', system-ui, -apple-system, sans-serif;
  color: #1f2933;
  background: #f5f7fa;
}

.app-shell {
  min-height: 100vh;
  display: flex;
  flex-direction: column;
}

.app-main {
  flex: 1;
  max-width: 1080px;
  width: 100%;
  margin: 0 auto;
  padding: 2rem 1.5rem;
}

.app-footer {
  padding: 1rem;
  text-align: center;
  color: #7b8794;
  font-size: 0.85rem;
  border-top: 1px solid #e4e7eb;
}

.app-notice {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 1rem;
  padding: 1rem;
  margin-bottom: 1rem;
  background: #fff;
  border: 1px solid #cbd2d9;
  border-radius: 8px;
}

.app-notice[role='alert'] {
  border-color: #b91c1c;
}
</style>
