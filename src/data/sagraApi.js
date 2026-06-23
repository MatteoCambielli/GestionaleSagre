import { createClient } from '@supabase/supabase-js'
import { demoStore } from './demoStore.js'

const url = import.meta.env.VITE_SUPABASE_URL
const key = import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY
export const supabaseClient = url && key ? createClient(url, key, {
  auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true },
}) : null
const supabase = supabaseClient
const DEVICE_KEY = 'ordiva-device-id-v1'

export function getDeviceId() {
  let id = localStorage.getItem(DEVICE_KEY)
  if (!id) {
    id = globalThis.crypto?.randomUUID?.() || `device-${Date.now()}-${Math.random().toString(36).slice(2)}`
    localStorage.setItem(DEVICE_KEY, id)
  }
  return id
}

const localDate = (value = new Date()) => {
  const year = value.getFullYear()
  const month = String(value.getMonth() + 1).padStart(2, '0')
  const day = String(value.getDate()).padStart(2, '0')
  return `${year}-${month}-${day}`
}

async function ensureSession() {
  if (!supabase) return
  const { data, error } = await supabase.auth.getSession()
  if (error) throw error
  if (!data.session) {
    const { error: signInError } = await supabase.auth.signInAnonymously()
    if (signInError) throw signInError
  }
}

function normalizeOrder(order) {
  return { ...order, total: Number(order.total), items: order.order_items ?? order.items ?? [] }
}

async function fetchAllOrders(buildQuery) {
  const pageSize = 1000
  const rows = []
  for (let from = 0; ; from += pageSize) {
    const { data, error } = await buildQuery().range(from, from + pageSize - 1)
    if (error) throw error
    rows.push(...data)
    if (data.length < pageSize) return rows.map(normalizeOrder)
  }
}

export const isDemoMode = !supabase

export const sagraApi = supabase ? {
  async signInAccount(email, password) {
    const { error } = await supabase.auth.signInWithPassword({ email: email.trim().toLowerCase(), password })
    if (error) throw error
    const { data, error: eventError } = await supabase.rpc('get_my_festivals')
    if (eventError) throw eventError
    if (!data?.length) throw new Error('Nessun evento associato a questo account')
    return data[0]
  },
  async linkOwnerEmail(email) {
    await ensureSession()
    const { error } = await supabase.auth.updateUser({ email: email.trim().toLowerCase() })
    if (error) throw error
  },
  async sendRecoveryOtp(email) {
    const { error } = await supabase.auth.signInWithOtp({
      email: email.trim().toLowerCase(),
      options: { shouldCreateUser: false, emailRedirectTo: window.location.origin },
    })
    if (error) throw error
  },
  async verifyRecoveryOtp(email, token) {
    const { error } = await supabase.auth.verifyOtp({ email: email.trim().toLowerCase(), token: token.trim(), type: 'email' })
    if (error) throw error
  },
  async getOwnedFestivals() {
    await ensureSession()
    const { data, error } = await supabase.rpc('get_owned_festivals')
    if (error) throw error
    return data || []
  },
  async resetFestivalPin(festivalId, pinType, newPin) {
    const { error } = await supabase.rpc('reset_festival_pin', { p_festival_id: festivalId, p_pin_type: pinType, p_new_pin: newPin })
    if (error) throw error
  },
  async registerFestival(name, slug, pin, statsPin) {
    await ensureSession()
    const { data, error } = await supabase.rpc('register_festival', { p_name: name, p_slug: slug, p_pin: pin, p_stats_pin: statsPin })
    if (error) throw error
    if (!data?.ok) throw new Error(data?.error || 'Registrazione non riuscita')
    return data.festival
  },
  async loginFestival(slug, pin) {
    await ensureSession()
    const { data, error } = await supabase.rpc('login_festival', { p_slug: slug, p_pin: pin })
    if (error) throw error
    if (!data?.ok) throw new Error(data?.error || 'Attività o PIN non validi')
    return data.festival
  },
  async verifyStatsPin(festivalId, pin) {
    const { data, error } = await supabase.rpc('verify_stats_pin', { p_festival_id: festivalId, p_pin: pin })
    if (error) throw error
    return data
  },
  async load(festivalId) {
    const serviceDate = localDate()
    const [categories, products, membership, orderCount, orders] = await Promise.all([
      supabase.from('categories').select('*').eq('festival_id', festivalId).order('sort_order'),
      supabase.from('products').select('*').eq('festival_id', festivalId).eq('active', true).order('name'),
      supabase.from('festival_members').select('role').eq('festival_id', festivalId).maybeSingle(),
      supabase.from('orders').select('id', { count: 'exact', head: true }).eq('festival_id', festivalId).eq('service_date', serviceDate),
      fetchAllOrders(() => supabase.from('orders')
        .select('*, order_items(*)')
        .eq('festival_id', festivalId)
        .eq('service_date', serviceDate)
        .or('paid.eq.false,kitchen_done.eq.false,bar_done.eq.false')
        .order('created_at', { ascending: true })
        .order('id', { ascending: true })),
    ])
    const failure = [categories, products, membership, orderCount].find((result) => result.error)
    if (failure) throw failure.error
    return { categories: categories.data, products: products.data, membership: membership.data, orders, orderCount: orderCount.count || 0 }
  },
  async loadOrderHistory(festivalId, date, table = '', cursor = null, limit = 200) {
    let query = supabase.from('orders')
      .select('*, order_items(*)')
      .eq('festival_id', festivalId)
      .eq('service_date', date)
      .order('created_at', { ascending: true })
      .order('id', { ascending: true })
      .limit(limit)
    if (table.trim()) query = query.ilike('table_number', `%${table.trim()}%`)
    if (cursor) query = query.or(`created_at.gt.${cursor.created_at},and(created_at.eq.${cursor.created_at},id.gt.${cursor.id})`)
    const { data, error } = await query
    if (error) throw error
    return data.map(normalizeOrder)
  },
  async loadAnalytics(festivalId, from, to) {
    const { data, error } = await supabase.rpc('get_festival_analytics', { p_festival_id: festivalId, p_from: from, p_to: to })
    if (error) throw error
    return data
  },
  async requestOrderUpgrade(festivalId) {
    const { data, error } = await supabase.rpc('request_order_upgrade', { p_festival_id: festivalId })
    if (error) throw error
    return data
  },
  async getOrderUpgradeRequest(festivalId) {
    const { data, error } = await supabase.rpc('get_my_order_upgrade_request', { p_festival_id: festivalId })
    if (error) throw error
    return data
  },
  async createCategory(festivalId, name) {
    const { error } = await supabase.from('categories').insert({ festival_id: festivalId, name })
    if (error) throw error
  },
  async deleteCategory(festivalId, name) {
    const { error } = await supabase.from('categories').delete().eq('festival_id', festivalId).eq('name', name)
    if (error) throw error
  },
  async createProduct(festivalId, product) {
    const { data, error } = await supabase.rpc('create_product', {
      p_festival_id: festivalId,
      p_name: product.name,
      p_price: product.price,
      p_category: product.category,
    })
    if (error) throw error
    return data
  },
  async deleteProduct(id) {
    const { error } = await supabase.from('products').update({ active: false }).eq('id', id)
    if (error) throw error
  },
  async createOrder(festivalId, order) {
    const { data, error } = await supabase.rpc('create_order', {
      p_festival_id: festivalId,
      p_table_number: order.table_number,
      p_notes: order.notes,
      p_items: order.items.map(({ product_id, quantity }) => ({ product_id, quantity })),
      p_device_id: getDeviceId(),
    })
    if (error) throw error
    return data
  },
  async openSession(festivalId) {
    const { data, error } = await supabase.rpc('register_device_session', {
      p_festival_id: festivalId,
      p_device_id: getDeviceId(),
      p_device_name: `${navigator.platform || 'Browser'} · ${navigator.language || 'it'}`,
      p_user_agent: navigator.userAgent,
    })
    if (error) throw error
    return data
  },
  async closeSession(festivalId) {
    const { error } = await supabase.rpc('release_device_session', { p_festival_id: festivalId, p_device_id: getDeviceId() })
    if (error) throw error
  },
  async updateOrder(id, changes) {
    const status = changes.paid ? 'paid' : changes.kitchen_done ? 'kitchen_done' : changes.bar_done ? 'bar_done' : null
    if (!status) throw new Error('Aggiornamento ordine non consentito')
    const { error } = await supabase.rpc('set_order_status', { p_order_id: id, p_status: status })
    if (error) throw error
  },
  async completeKitchenProduct(festivalId, productName, quantity) {
    const { error } = await supabase.rpc('complete_kitchen_product', { p_festival_id: festivalId, p_product_name: productName, p_quantity: quantity })
    if (error) throw error
  },
  subscribe(festivalId, callback) {
    let active = true
    let channel
    let refreshTimer
    const scheduleRefresh = () => {
      window.clearTimeout(refreshTimer)
      refreshTimer = window.setTimeout(callback, 120)
    }
    Promise.resolve(supabase.realtime.setAuth()).then(() => {
      if (!active) return
      channel = supabase
        .channel(`festival:${festivalId}`, { config: { private: true } })
        .on('broadcast', { event: 'db-change' }, scheduleRefresh)
        .subscribe()
    })
    return () => {
      active = false
      window.clearTimeout(refreshTimer)
      if (channel) supabase.removeChannel(channel)
    }
  },
} : {
  ...demoStore,
  async load(festivalId) {
    return { ...await demoStore.load(festivalId), membership: { role: 'owner' } }
  },
  async linkOwnerEmail() {},
  async sendRecoveryOtp() {},
  async verifyRecoveryOtp() {},
  async getOwnedFestivals() {
    const festival = await demoStore.loginFestival('sagra-demo', '12345')
    return [festival]
  },
  async resetFestivalPin() {},
  async signInAccount() { return demoStore.loginFestival('sagra-demo', '12345') },
  async openSession() { return { allowed: true, status: 'active', orders_used: 0, max_orders: 500, orders_remaining: 500, active_devices: 1, max_devices: 5 } },
  async closeSession() {},
  async loadOrderHistory(festivalId, date, table = '', cursor = null, limit = 200) {
    const { orders } = await demoStore.load(festivalId)
    return orders
      .filter((order) => order.created_at.slice(0, 10) === date)
      .filter((order) => !table || String(order.table_number).includes(table))
      .filter((order) => !cursor || order.created_at > cursor.created_at || (order.created_at === cursor.created_at && Number(order.id) > Number(cursor.id)))
      .sort((a, b) => new Date(a.created_at) - new Date(b.created_at))
      .slice(0, limit)
  },
  async loadAnalytics(festivalId, from, to) {
    const { orders } = await demoStore.load(festivalId)
    return { rawOrders: orders.filter((order) => order.created_at.slice(0, 10) >= from && order.created_at.slice(0, 10) <= to) }
  },
}
