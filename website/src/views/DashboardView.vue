<template>
  <section class="dashboard">
    <h1>{{ t('dashboard.title') }}</h1>
    <p class="welcome">{{ t('dashboard.welcome', { email: auth.email }) }}</p>

    <form class="create-form" @submit.prevent="createItem">
      <input
        v-model.trim="newName"
        :placeholder="t('dashboard.itemNamePlaceholder')"
        aria-label="name"
        required
      />
      <AppButton type="submit" :disabled="!newName">{{ t('dashboard.create') }}</AppButton>
    </form>

    <p v-if="error" class="error">{{ error }}</p>

    <ul class="items" v-if="items.length">
      <li v-for="item in items" :key="item.id" class="item">
        <div>
          <span class="name">{{ item.name }}</span>
          <span class="status">{{ statusLabel(item.status) }}</span>
        </div>
        <AppButton variant="danger" @click="deleteItem(item)">{{ t('dashboard.delete') }}</AppButton>
      </li>
    </ul>
    <p v-else-if="!loading" class="empty">{{ t('dashboard.itemsEmpty') }}</p>
  </section>
</template>

<script setup>
import { onMounted, ref } from 'vue'
import { useI18n } from 'vue-i18n'
import AppButton from '@/components/AppButton.vue'
import api from '@/api/client'
import { useAuthStore } from '@/stores/auth'
import { useUiStore } from '@/stores/ui'
import { useStatusLabel } from '@/composables/useStatusLabel'
import { errorMessage } from '@/utils/api-errors'

const { t } = useI18n()
const auth = useAuthStore()
const ui = useUiStore()
const statusLabel = useStatusLabel()

const items = ref([])
const loading = ref(true)
const error = ref('')
const newName = ref('')

onMounted(loadItems)

async function loadItems() {
  loading.value = true
  error.value = ''
  try {
    const { data } = await api.get('/v1/items')
    items.value = data
  } catch (err) {
    error.value = errorMessage(err, t('dashboard.itemsError'))
  } finally {
    loading.value = false
  }
}

async function createItem() {
  try {
    await api.post('/v1/items', { name: newName.value })
    newName.value = ''
    ui.showToast(t('dashboard.created'), 'success')
    await loadItems()
  } catch (err) {
    error.value = errorMessage(err)
  }
}

async function deleteItem(item) {
  try {
    await api.delete(`/v1/items/${item.id}`)
    ui.showToast(t('dashboard.deleted'), 'success')
    await loadItems()
  } catch (err) {
    error.value = errorMessage(err)
  }
}
</script>

<style scoped>
.welcome {
  color: #52606d;
}

.create-form {
  display: flex;
  gap: 0.75rem;
  margin-bottom: 1.5rem;
}

.create-form input {
  flex: 1;
  padding: 0.65rem 0.8rem;
  border: 1px solid #cbd2d9;
  border-radius: 8px;
  font-size: 1rem;
}

.error {
  color: #d64545;
}

.items {
  list-style: none;
  margin: 0;
  padding: 0;
  display: flex;
  flex-direction: column;
  gap: 0.75rem;
}

.item {
  display: flex;
  align-items: center;
  justify-content: space-between;
  background: #fff;
  border: 1px solid #e4e7eb;
  border-radius: 10px;
  padding: 1rem 1.25rem;
}

.name {
  font-weight: 600;
}

.status {
  margin-left: 0.75rem;
  font-size: 0.8rem;
  color: #3e8e41;
  background: #e6f4ea;
  border-radius: 999px;
  padding: 0.15rem 0.6rem;
}

.empty {
  color: #7b8794;
  text-align: center;
  padding: 2rem 0;
}
</style>
