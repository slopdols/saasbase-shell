<template>
  <section class="login">
    <form class="card" @submit.prevent="submit">
      <h1>{{ t(mode === 'register' ? 'login.registerTitle' : mode === 'confirm' ? 'login.confirmTitle' : 'login.title') }}</h1>

      <label for="email">{{ t('login.emailLabel') }}</label>
      <input
        id="email"
        v-model.trim="email"
        type="email"
        required
        :disabled="loading"
        :placeholder="t('login.emailPlaceholder', { at: '@' })"
      />

      <template v-if="!config.mocksEnabled && mode !== 'confirm'">
        <label for="password">{{ t('login.passwordLabel') }}</label>
        <input id="password" v-model="password" type="password" required :disabled="loading"
          :autocomplete="mode === 'register' ? 'new-password' : 'current-password'" />
        <p v-if="mode === 'register'" class="note">{{ t('login.passwordHelp') }}</p>
      </template>
      <template v-if="mode === 'confirm'">
        <p class="note">{{ t('login.confirmHelp') }}</p>
        <label for="code">{{ t('login.codeLabel') }}</label>
        <input id="code" v-model.trim="code" autocomplete="one-time-code" required :disabled="loading" />
        <button type="button" :disabled="loading" @click="resend">{{ t('login.resend') }}</button>
      </template>
      <AppButton type="submit" :disabled="loading || !email">
        {{ loading ? '…' : t(mode === 'register' ? 'login.register' : mode === 'confirm' ? 'login.confirm' : 'login.submit') }}
      </AppButton>
      <button v-if="!config.mocksEnabled" type="button" :disabled="loading" @click="switchMode">
        {{ t(mode === 'login' ? 'login.register' : 'login.backToLogin') }}
      </button>
      <p v-if="config.mocksEnabled" class="note">{{ t('login.mockNote') }}</p>
    </form>
  </section>
</template>

<script setup>
import { ref } from 'vue'
import { useRouter, useRoute } from 'vue-router'
import { useI18n } from 'vue-i18n'
import AppButton from '@/components/AppButton.vue'
import { useAuthStore } from '@/stores/auth'
import { useUiStore } from '@/stores/ui'
import { config } from '@/config'

const { t } = useI18n()
const router = useRouter()
const route = useRoute()
const auth = useAuthStore()
const ui = useUiStore()

const email = ref('')
const password = ref('')
const code = ref('')
const mode = ref('login')
const loading = ref(false)

async function submit() {
  ui.clearToast()
  loading.value = true
  try {
    if (mode.value === 'register') {
      const result = await auth.register(email.value, password.value)
      mode.value = result.UserConfirmed ? 'login' : 'confirm'
      ui.showToast(t(result.UserConfirmed ? 'login.confirmed' : 'login.codeSent'), 'success')
      return
    }
    if (mode.value === 'confirm') {
      await auth.confirmRegistration(email.value, code.value)
      code.value = ''
      mode.value = 'login'
      ui.showToast(t('login.confirmed'), 'success')
      return
    }
    await auth.login(email.value, password.value)
    ui.showToast(t('login.success'), 'success')
    const requested = route.query.redirect
    const redirect = typeof requested === 'string' && requested.startsWith('/') && !requested.startsWith('//')
      ? requested : { name: 'dashboard' }
    router.push(redirect)
  } catch (err) {
    if (err?.code === 'UserNotConfirmedException') { mode.value = 'confirm' }
    ui.showToast(err?.message || t('errors.generic'), 'error')
  } finally {
    password.value = ''
    loading.value = false
  }
}

function switchMode() {
  ui.clearToast()
  mode.value = mode.value === 'login' ? 'register' : 'login'
  password.value = ''
  code.value = ''
}

async function resend() {
  ui.clearToast()
  loading.value = true
  try {
    await auth.resendConfirmation(email.value)
    ui.showToast(t('login.codeSent'), 'success')
  } catch (err) {
    ui.showToast(err?.message || t('errors.generic'), 'error')
  } finally {
    loading.value = false
  }
}
</script>

<style scoped>
.login {
  display: flex;
  justify-content: center;
  padding-top: 2rem;
}

.card {
  background: #fff;
  border: 1px solid #e4e7eb;
  border-radius: 12px;
  padding: 2rem;
  width: 100%;
  max-width: 380px;
  display: flex;
  flex-direction: column;
  gap: 0.75rem;
}

.card h1 {
  margin: 0 0 0.5rem;
  font-size: 1.5rem;
}

label {
  font-weight: 600;
  color: #3e4c59;
}

input {
  padding: 0.65rem 0.8rem;
  border: 1px solid #cbd2d9;
  border-radius: 8px;
  font-size: 1rem;
}

.note {
  color: #7b8794;
  font-size: 0.85rem;
  margin: 0;
}
</style>
