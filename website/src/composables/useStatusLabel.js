import { useI18n } from 'vue-i18n'

const LABELS = {
  active: 'Activo',
  deleted: 'Eliminado'
}

export function useStatusLabel() {
  const { t } = useI18n()
  return (status) => LABELS[status] || t(status) || status
}
