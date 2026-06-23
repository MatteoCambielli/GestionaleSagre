import { supabaseClient } from './sagraApi.js'

const requireClient = () => {
  if (!supabaseClient) throw new Error('Supabase non è configurato')
  return supabaseClient
}

const rpc = async (name, args = {}) => {
  const { data, error } = await requireClient().rpc(name, args)
  if (error) throw error
  return data
}

export const managerApi = {
  async session() {
    const { data, error } = await requireClient().auth.getSession()
    if (error) throw error
    return data.session
  },
  async sendMagicLink(email) {
    const { error } = await requireClient().auth.signInWithOtp({
      email: email.trim().toLowerCase(),
      options: { shouldCreateUser: false, emailRedirectTo: `${window.location.origin}/manager` },
    })
    if (error) throw error
  },
  async signIn(email, password) {
    const { error } = await requireClient().auth.signInWithPassword({ email: email.trim().toLowerCase(), password })
    if (error) throw error
  },
  async sendPasswordRecovery(email) {
    const { error } = await requireClient().auth.resetPasswordForEmail(email.trim().toLowerCase(), {
      redirectTo: `${window.location.origin}/manager?reset=1`,
    })
    if (error) throw error
  },
  async updatePassword(password) {
    const { error } = await requireClient().auth.updateUser({ password })
    if (error) throw error
  },
  async isAdmin() { return Boolean(await rpc('is_platform_admin')) },
  async load() {
    const [dashboard, events, extensions, requests] = await Promise.all([
      rpc('manager_dashboard'), rpc('manager_list_events'), rpc('manager_list_order_extensions'),
      rpc('manager_list_order_upgrade_requests', { p_status: 'pending' }),
    ])
    const extensionMap = new Map()
    for (const extension of extensions || []) {
      const current = extensionMap.get(extension.festival_id) || { orders_extended: 0, supplement_due: 0, extensions_count: 0 }
      current.orders_extended += Number(extension.added_orders || 0)
      current.extensions_count += 1
      if (extension.payment_status === 'pending') current.supplement_due += Number(extension.supplement_amount || 0)
      extensionMap.set(extension.festival_id, current)
    }
    const requestMap = new Map((requests || []).map((request) => [request.festival_id, request]))
    return {
      dashboard: { ...dashboard, requests_pending: requests?.length || 0 },
      requests: requests || [],
      events: (events || []).map((event) => ({ ...event, ...(extensionMap.get(event.id) || {}), pending_upgrade_request: requestMap.get(event.id) || null })),
    }
  },
  async detail(eventId) {
    const [detail, extensions, requests] = await Promise.all([
      rpc('manager_get_event', { p_festival_id: eventId }),
      rpc('manager_list_order_extensions', { p_festival_id: eventId }),
      rpc('manager_list_order_upgrade_requests', { p_festival_id: eventId }),
    ])
    return { ...detail, extensions: extensions || [], upgrade_requests: requests || [] }
  },
  createEvent(data) { return rpc('manager_create_event', { p_data: data }) },
  updateEvent(eventId, data) { return rpc('manager_update_event', { p_festival_id: eventId, p_data: data }) },
  action(eventId, action, value = null) { return rpc('manager_event_action', { p_festival_id: eventId, p_action: action, p_value: value }) },
  addOrders(eventId, addedOrders, supplementAmount, notes = '') { return rpc('manager_add_orders', { p_festival_id: eventId, p_added_orders: addedOrders, p_supplement_amount: supplementAmount, p_notes: notes }) },
  markOrderExtensionPaid(extensionId) { return rpc('manager_mark_order_extension_paid', { p_extension_id: extensionId }) },
  approveOrderUpgrade(requestId, addedOrders, supplementAmount, notes = '') { return rpc('manager_approve_order_upgrade_request', { p_request_id: requestId, p_added_orders: addedOrders, p_supplement_amount: supplementAmount, p_notes: notes }) },
  rejectOrderUpgrade(requestId, notes = '') { return rpc('manager_reject_order_upgrade_request', { p_request_id: requestId, p_notes: notes }) },
  clearEventData(eventId, confirmationSlug) { return rpc('manager_clear_event_data', { p_festival_id: eventId, p_confirmation_slug: confirmationSlug }) },
  resetPins(eventId, operationalPin, statsPin) { return rpc('manager_reset_event_pins', { p_festival_id: eventId, p_operational_pin: operationalPin, p_stats_pin: statsPin }) },
  async linkRecovery(payload) {
    const { data, error } = await requireClient().functions.invoke('manager-users', { body: { action: 'link_recovery', ...payload } })
    if (error) throw error
    if (data?.error) throw new Error(data.error)
    return data
  },
  async createUser(payload) {
    const { data, error } = await requireClient().functions.invoke('manager-users', { body: { action: 'create', ...payload } })
    if (error) throw error
    if (data?.error) throw new Error(data.error)
    return data
  },
  async resetPassword(authUserId, password) {
    const { data, error } = await requireClient().functions.invoke('manager-users', { body: { action: 'reset', auth_user_id: authUserId, password } })
    if (error) throw error
    if (data?.error) throw new Error(data.error)
    return data
  },
  async signOut() {
    const { error } = await requireClient().auth.signOut({ scope: 'local' })
    if (error) throw error
  },
}
