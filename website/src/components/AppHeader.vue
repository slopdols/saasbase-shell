<template>
  <header class="app-header">
    <router-link to="/" class="brand">{{ t('app.name') }}</router-link>
    <nav class="nav">
      <router-link to="/">{{ t('nav.home') }}</router-link>
      <router-link to="/dashboard" v-if="auth.isAuthenticated">
        {{ t('nav.dashboard') }}
      </router-link>
      <template v-if="auth.isAuthenticated">
        <span class="user" v-if="auth.email">{{ auth.email }}</span>
        <button class="link-button" @click="logout">{{ t('nav.logout') }}</button>
      </template>
      <router-link to="/login" v-else>{{ t('nav.login') }}</router-link>
    </nav>
  </header>
</template>

<script setup>
import { useRouter } from 'vue-router'
import { useI18n } from 'vue-i18n'
import { useAuthStore } from '@/stores/auth'

const { t } = useI18n()
const router = useRouter()
const auth = useAuthStore()

function logout() {
  auth.logout()
  router.push({ name: 'home' })
}
</script>

<style scoped>
.app-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 1rem 1.5rem;
  background: #ffffff;
  border-bottom: 1px solid #e4e7eb;
  position: sticky;
  top: 0;
}

.brand {
  font-weight: 700;
  font-size: 1.15rem;
  color: #2563eb;
  text-decoration: none;
}

.nav {
  display: flex;
  align-items: center;
  gap: 1.25rem;
}

.nav a {
  color: #3e4c59;
  text-decoration: none;
}

.nav a.router-link-exact-active {
  color: #2563eb;
  font-weight: 600;
}

.user {
  color: #7b8794;
  font-size: 0.9rem;
}

.link-button {
  background: none;
  border: none;
  color: #3e4c59;
  cursor: pointer;
  font-size: 0.95rem;
  padding: 0;
}

.link-button:hover {
  color: #d64545;
}
</style>
