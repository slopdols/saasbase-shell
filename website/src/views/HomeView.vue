<template>
  <section class="home">
    <div class="hero">
      <h1>{{ t('home.title') }}</h1>
      <p class="subtitle">{{ t('home.subtitle') }}</p>
      <div class="actions">
        <router-link to="/dashboard" class="btn primary">{{ t('home.ctaDashboard') }}</router-link>
        <router-link to="/login" class="btn secondary">{{ t('home.ctaLogin') }}</router-link>
      </div>
    </div>

    <div class="features">
      <div class="feature" v-for="f in features" :key="f.title">
        <h3>{{ f.title }}</h3>
        <p>{{ f.text }}</p>
      </div>
    </div>
  </section>
</template>

<script setup>
import { useI18n } from 'vue-i18n'

const { t } = useI18n()

const features = [
  { title: t('home.feature1Title'), text: t('home.feature1Text') },
  { title: t('home.feature2Title'), text: t('home.feature2Text') },
  { title: t('home.feature3Title'), text: t('home.feature3Text') }
]
</script>

<style scoped>
.home {
  display: flex;
  flex-direction: column;
  gap: 2.5rem;
}

.hero {
  text-align: center;
  padding: 3rem 1rem;
  background: linear-gradient(135deg, #eff6ff, #ffffff);
  border-radius: 16px;
}

.hero h1 {
  font-size: 2.25rem;
  margin: 0 0 0.75rem;
  color: #1f2933;
}

.subtitle {
  color: #52606d;
  font-size: 1.1rem;
  max-width: 560px;
  margin: 0 auto 1.75rem;
}

.actions {
  display: flex;
  justify-content: center;
  gap: 1rem;
}

.btn {
  text-decoration: none;
  padding: 0.7rem 1.4rem;
  border-radius: 8px;
  font-weight: 600;
}

.btn.primary {
  background: #2563eb;
  color: #fff;
}

.btn.secondary {
  background: #e4e7eb;
  color: #3e4c59;
}

.features {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(240px, 1fr));
  gap: 1.25rem;
}

.feature {
  background: #fff;
  border: 1px solid #e4e7eb;
  border-radius: 12px;
  padding: 1.5rem;
}

.feature h3 {
  margin: 0 0 0.5rem;
  color: #2563eb;
}

.feature p {
  margin: 0;
  color: #52606d;
}
</style>
