const STORAGE_KEY = 'sagra-cloud-demo-v2'

const starterProducts = [
  ['Panino con salamella', 6, 'Cucina'],
  ['Patatine fritte', 4, 'Cucina'],
  ['Risotto alla lodigiana', 7.5, 'Primi'],
  ['Acqua naturale', 1.5, 'Bere'],
  ['Birra alla spina', 4, 'Bere'],
  ['Coca-Cola', 3, 'Bere'],
]

function initialState() {
  const festivalId = crypto.randomUUID()
  return {
    festivals: [{ id: festivalId, name: 'Sagra Demo', slug: 'sagra-demo', pin: '12345', stats_pin: '9999' }],
    categories: [
      { id: crypto.randomUUID(), festival_id: festivalId, name: 'Bere', sort_order: 0 },
      { id: crypto.randomUUID(), festival_id: festivalId, name: 'Cucina', sort_order: 1 },
      { id: crypto.randomUUID(), festival_id: festivalId, name: 'Primi', sort_order: 2 },
    ],
    products: starterProducts.map(([name, price, category]) => ({ id: crypto.randomUUID(), festival_id: festivalId, name, price, category, active: true })),
    orders: [],
    upgradeRequests: [],
  }
}

function read() {
  const stored = localStorage.getItem(STORAGE_KEY)
  if (!stored) {
    const state = initialState()
    localStorage.setItem(STORAGE_KEY, JSON.stringify(state))
    return state
  }
  try { const state = JSON.parse(stored); state.upgradeRequests ||= []; return state } catch { return initialState() }
}

function write(state) {
  localStorage.setItem(STORAGE_KEY, JSON.stringify(state))
  window.dispatchEvent(new Event('sagra-demo-change'))
}

export const demoStore = {
  async registerFestival(name, slug, pin, statsPin) {
    const state = read()
    if (state.festivals.some((festival) => festival.slug === slug)) throw new Error('Codice attività già utilizzato')
    const festival = { id: crypto.randomUUID(), name, slug, pin, stats_pin: statsPin }
    state.festivals.push(festival)
    state.categories.push(
      { id: crypto.randomUUID(), festival_id: festival.id, name: 'Cucina', sort_order: 0 },
      { id: crypto.randomUUID(), festival_id: festival.id, name: 'Bere', sort_order: 1 },
    )
    write(state)
    return festival
  },
  async loginFestival(slug, pin) {
    const festival = read().festivals.find((item) => item.slug === slug && item.pin === pin)
    if (!festival) throw new Error('Attività o PIN non validi')
    return festival
  },
  async verifyStatsPin(festivalId, pin) {
    return read().festivals.some((festival) => festival.id === festivalId && festival.stats_pin === pin)
  },
  async requestOrderUpgrade(festivalId) {
    const state = read()
    let request = state.upgradeRequests.find((item) => item.festival_id === festivalId && item.status === 'pending')
    if (!request) {
      request = { id: crypto.randomUUID(), festival_id: festivalId, status: 'pending', current_plan: 'starter', suggested_plan: 'pro', suggested_additional_orders: 4500, requested_at: new Date().toISOString(), message: 'La richiesta comporta il passaggio al piano superiore e una variazione di prezzo.' }
      state.upgradeRequests.push(request)
      write(state)
    }
    return request
  },
  async getOrderUpgradeRequest(festivalId) {
    return read().upgradeRequests.find((item) => item.festival_id === festivalId && item.status === 'pending') || null
  },
  async load(festivalId) {
    const state = read()
    return {
      categories: state.categories.filter((item) => item.festival_id === festivalId),
      products: state.products.filter((item) => item.festival_id === festivalId),
      orders: state.orders.filter((item) => item.festival_id === festivalId),
    }
  },
  async createCategory(festivalId, name) {
    const state = read()
    state.categories.push({ id: crypto.randomUUID(), festival_id: festivalId, name, sort_order: state.categories.length })
    write(state)
  },
  async deleteCategory(festivalId, name) {
    const state = read()
    state.categories = state.categories.filter((item) => !(item.festival_id === festivalId && item.name === name))
    state.products = state.products.filter((item) => !(item.festival_id === festivalId && item.category === name))
    write(state)
  },
  async createProduct(festivalId, product) {
    const state = read()
    const created = { id: crypto.randomUUID(), festival_id: festivalId, active: true, ...product }
    state.products.push(created)
    write(state)
    return created
  },
  async deleteProduct(id) {
    const state = read()
    state.products = state.products.filter((item) => item.id !== id)
    write(state)
  },
  async createOrder(festivalId, order) {
    const state = read()
    state.orders.push({
      id: Date.now(), festival_id: festivalId, paid: false, kitchen_done: false, bar_done: false,
      created_at: new Date().toISOString(), ...order,
      items: order.items.map((item) => ({ ...item, prepared_quantity: 0 })),
    })
    write(state)
  },
  async updateOrder(id, changes) {
    const state = read()
    state.orders = state.orders.map((item) => item.id === id ? { ...item, ...changes } : item)
    write(state)
  },
  async completeKitchenProduct(festivalId, productName, quantity) {
    const state = read()
    let remainingToPrepare = Math.max(0, Number(quantity) || 0)
    const orderedOrders = state.orders
      .filter((order) => order.festival_id === festivalId && !order.kitchen_done)
      .sort((a, b) => new Date(a.created_at) - new Date(b.created_at) || Number(a.id) - Number(b.id))

    for (const queuedOrder of orderedOrders) {
      if (remainingToPrepare <= 0) break
      const order = state.orders.find((item) => item.id === queuedOrder.id)
      order.items = order.items.map((item) => {
        if (remainingToPrepare <= 0 || item.name !== productName || ['Bere', 'Bevande'].includes(item.category)) return item
        const available = Math.max(0, item.quantity - Number(item.prepared_quantity || 0))
        const preparedNow = Math.min(available, remainingToPrepare)
        remainingToPrepare -= preparedNow
        return { ...item, prepared_quantity: Number(item.prepared_quantity || 0) + preparedNow }
      })
    }

    state.orders = state.orders.map((order) => {
      if (order.festival_id !== festivalId || order.kitchen_done) return order
      const kitchenDone = order.items
        .filter((item) => !['Bere', 'Bevande'].includes(item.category))
        .every((item) => Number(item.prepared_quantity || 0) >= item.quantity)
      return { ...order, kitchen_done: kitchenDone }
    })
    write(state)
  },
  subscribe(_festivalId, callback) {
    const handler = () => callback()
    window.addEventListener('storage', handler)
    window.addEventListener('sagra-demo-change', handler)
    return () => { window.removeEventListener('storage', handler); window.removeEventListener('sagra-demo-change', handler) }
  },
}
