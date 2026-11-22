// Mock fixtures for the generic item entity.
const now = new Date().toISOString()

export const itemsFixtures = {
  list: [
    {
      id: 'mock-item-1',
      name: 'Ítem de ejemplo 1',
      status: 'active',
      owner_sub: 'mock-user',
      created_at: now,
      updated_at: now,
      version: 0
    },
    {
      id: 'mock-item-2',
      name: 'Ítem de ejemplo 2',
      status: 'active',
      owner_sub: 'mock-user',
      created_at: now,
      updated_at: now,
      version: 0
    }
  ]
}
