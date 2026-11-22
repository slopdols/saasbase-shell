<template>
  <section class="not-found">
    <h1>404</h1>
    <p>{{ t('notFound.title') }}</p>
    <router-link to="/" class="link">{{ t('notFound.back') }}</router-link>
  </section>
</template>

<script setup>
import { useI18n } from 'vue-i18n'

const { t } = useI18n()
</script>

<style scoped>
.not-found {
  text-align: center;
  padding: 4rem 0;
}

.not-found h1 {
  font-size: 4rem;
  margin: 0;
  color: #2563eb;
}

.link {
  color: #2563eb;
}
</style>
