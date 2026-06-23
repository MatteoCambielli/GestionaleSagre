import { lazy, Suspense, useCallback, useEffect, useMemo, useRef, useState } from 'react'
import {
  Archive, ArrowLeft, Banknote, BarChart3, Beer, CalendarDays, Check, ChefHat, ChevronRight,
  Building2, CirclePlus, ClipboardCheck, Clock3, Cloud, CookingPot, Download, FolderPlus, Gauge, History, KeyRound, LayoutList,
  LockKeyhole, LogOut, Mail, Minus, Plus, Receipt, Search, Settings2, ShieldCheck, ShoppingCart,
  Smartphone, Sparkles, Trash2, TrendingUp, Trophy, WalletCards, X,
} from 'lucide-react'
import { isDemoMode, sagraApi } from './data/sagraApi.js'
const ManagerApp = lazy(() => import('./manager/ManagerApp.jsx'))

const SESSION_KEY = 'sagra-cloud-session-v2'
const ORDER_ACTIVITY_KEY = 'sagra-cloud-order-activity-v1'
const ORDER_IDLE_MS = 30 * 60 * 1000
const DRINK_CATEGORIES = new Set(['Bere', 'Bevande'])
const today = () => new Date().toISOString().slice(0, 10)
const euro = (value) => new Intl.NumberFormat('it-IT', { style: 'currency', currency: 'EUR' }).format(value || 0)
const slugify = (value) => value.toLowerCase().trim().replace(/[^a-z0-9]+/g, '-').replace(/(^-|-$)/g, '')
const compactId = (id) => String(id).slice(-5)
const orderOldestFirst = (orders) => [...orders].sort((a, b) => new Date(a.created_at) - new Date(b.created_at) || Number(a.id) - Number(b.id))
const dateDaysAgo = (days) => { const value = new Date(); value.setDate(value.getDate() - days); return value.toISOString().slice(0, 10) }

const viewTitles = {
  dashboard: 'Pannello Principale', order: 'Crea Nuova Ordinazione', command: 'Monitor Comande',
  kitchen: 'Produzione Cucina', bar: 'Monitor Ordinazioni Bere', cash: 'Punto Cassa',
  history: 'Archivio Storico Comande', menu: 'Configurazione Categorie e Piatti', stats: 'Statistiche e Incassi',
}

function loadSession() {
  try {
    const session = JSON.parse(localStorage.getItem(SESSION_KEY))
    if (!session?.festival || session.authenticatedDay !== today()) return null
    return session.festival
  } catch { return null }
}

function RecoveryFestivalCard({ festival, onOpen }) {
  const [pinType, setPinType] = useState('operational')
  const [newPin, setNewPin] = useState('')
  const [message, setMessage] = useState('')
  const [loading, setLoading] = useState(false)
  const reset = async () => {
    if (!/^[0-9]{4,12}$/.test(newPin)) { setMessage('Inserisci da 4 a 12 cifre'); return }
    setLoading(true); setMessage('')
    try { await sagraApi.resetFestivalPin(festival.id, pinType, newPin); setNewPin(''); setMessage('PIN aggiornato correttamente') } catch (error) { setMessage(error.message || 'Reset non riuscito') } finally { setLoading(false) }
  }
  return <article className="recovery-festival"><div className="recovery-festival-heading"><span><Building2 size={19} /></span><div><strong>{festival.name}</strong><code>{festival.slug}</code></div><button onClick={() => onOpen(festival)}>Apri</button></div><div className="reset-pin-form"><select aria-label={`Tipo PIN ${festival.name}`} value={pinType} onChange={(event) => setPinType(event.target.value)}><option value="operational">PIN operativo</option><option value="stats">PIN statistiche</option></select><input aria-label={`Nuovo PIN ${festival.name}`} type="password" inputMode="numeric" pattern="[0-9]{4,12}" minLength={4} maxLength={12} placeholder="Nuovo PIN" value={newPin} onChange={(event) => setNewPin(event.target.value)} /><button disabled={loading} onClick={reset}><KeyRound size={16} /> Reimposta</button></div>{message ? <p className={message.includes('correttamente') ? 'recovery-success' : 'form-error'}>{message}</p> : null}</article>
}

function RecoveryScreen({ onBack, onAuthenticated }) {
  const [email, setEmail] = useState('')
  const [sent, setSent] = useState(false)
  const [festivals, setFestivals] = useState([])
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(true)
  const loadOwned = useCallback(async () => {
    setLoading(true); setError('')
    try { setFestivals(await sagraApi.getOwnedFestivals()) } catch (errorValue) { setError(errorValue.message || 'Impossibile verificare l’account') } finally { setLoading(false) }
  }, [])
  useEffect(() => { loadOwned() }, [loadOwned])
  const sendLink = async (event) => {
    event.preventDefault(); setLoading(true); setError('')
    try { await sagraApi.sendRecoveryOtp(email); setSent(true) } catch (errorValue) { setError(errorValue.message || 'Invio non riuscito') } finally { setLoading(false) }
  }
  return <main className="auth-page"><section className="auth-card recovery-card"><div className="auth-icon recovery"><ShieldCheck size={31} /></div><h1>Recupera la tua sagra</h1>{festivals.length ? <><p>Account verificato. Puoi recuperare il codice o reimpostare i PIN.</p><div className="owned-festivals">{festivals.map((festival) => <RecoveryFestivalCard key={festival.id} festival={festival} onOpen={onAuthenticated} />)}</div></> : <>{sent ? <div className="recovery-sent"><Mail size={26} /><strong>Controlla la tua email</strong><p>Apri il link ricevuto, poi torna qui. Le tue sagre compariranno automaticamente.</p><button className="primary-button" disabled={loading} onClick={loadOwned}>Ho aperto il link</button></div> : <><p>Inserisci l’email verificata del proprietario. Ti invieremo un link sicuro.</p><form onSubmit={sendLink}><input aria-label="Email proprietario" type="email" placeholder="nome@email.it" value={email} onChange={(event) => setEmail(event.target.value)} required /><button className="primary-button" disabled={loading}>{loading ? 'Verifica…' : 'Invia link di recupero'}</button></form></>}{error ? <p className="form-error">{error}</p> : null}</>}<button className="demo-link" onClick={onBack}>Torna all’accesso</button></section></main>
}

function AuthScreen({ onAuthenticated }) {
  const [mode, setMode] = useState('login')
  const [form, setForm] = useState({ slug: '', pin: '' })
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(false)
  const submit = async (event) => {
    event.preventDefault(); setError(''); setLoading(true)
    try {
      let festival
      festival = await sagraApi.loginFestival(slugify(form.slug), form.pin.trim())
      onAuthenticated(festival, '')
    } catch (errorValue) { setError(errorValue.message || 'Operazione non riuscita') } finally { setLoading(false) }
  }
  if (mode === 'recover') return <RecoveryScreen onBack={() => setMode('login')} onAuthenticated={onAuthenticated} />
  return <main className="auth-page"><section className="auth-card"><div className="auth-icon"><Smartphone size={32} /></div><h1>Ordiva</h1><p>Inserisci codice attività e PIN operativo</p><form onSubmit={submit}><input aria-label="Codice attività" autoComplete="username" placeholder="Codice attività (es. sagra-orio)" value={form.slug} onChange={(event) => setForm({ ...form, slug: event.target.value })} required /><input aria-label="PIN operativo" autoComplete="current-password" type="password" inputMode="numeric" pattern="[0-9]{4,12}" placeholder="PIN operativo (da 4 cifre)" value={form.pin} onChange={(event) => setForm({ ...form, pin: event.target.value })} minLength={4} maxLength={12} required />{error ? <p className="form-error">{error}</p> : null}<button className="primary-button" disabled={loading}>{loading ? 'Attendi…' : 'Accedi'}</button></form><button className="recovery-link" onClick={() => setMode('recover')}><KeyRound size={15} /> Hai dimenticato codice o PIN?</button>{isDemoMode ? <button className="demo-link" onClick={() => setForm({ slug: 'sagra-demo', pin: '12345' })}>Demo: sagra-demo · PIN 12345</button> : null}</section></main>
}

function UpgradeRequestButton({ request, requesting, onRequest }) {
  if (request?.status === 'pending') return <div className="upgrade-request-sent"><Check size={18} /><span><strong>Richiesta inviata</strong><small>Proposta: passaggio da {request.current_plan} a {request.suggested_plan}. Riceverai il nuovo plafond dopo l&apos;approvazione.</small></span></div>
  return <button className="upgrade-request-button" disabled={requesting} onClick={onRequest}><CirclePlus size={18} />{requesting ? 'Invio richiesta…' : 'Richiedi aggiunta ordini'}</button>
}

function LicenseBlocked({ message, onLogout, onBack, upgradeRequest, requestingUpgrade, onRequestUpgrade }) {
  return <main className="auth-page"><section className="auth-card license-blocked"><div className="auth-icon"><LockKeyhole size={30} /></div><h1>Funzioni operative bloccate</h1><p>{message}</p>{onRequestUpgrade ? <div className="upgrade-request-box"><h3>Passa al piano superiore</h3><p>L&apos;aggiunta di ordini comporta il passaggio all&apos;abbonamento successivo e una variazione di prezzo. La richiesta sarà valutata dal Manager prima dell&apos;attivazione.</p><UpgradeRequestButton request={upgradeRequest} requesting={requestingUpgrade} onRequest={onRequestUpgrade} /></div> : null}<div>{onBack ? <button className="demo-link" onClick={onBack}>Torna alla dashboard</button> : null}<button className="primary-button" onClick={onLogout}>Esci</button></div></section></main>
}

function Header({ festival, view, setView, onLogout }) {
  return <header className="app-header"><div className="header-inner">{view !== 'dashboard' ? <button className="icon-button" aria-label="Indietro" onClick={() => setView('dashboard')}><ArrowLeft size={19} /></button> : null}<div className="brand-block"><h1>Ordiva</h1><p>{festival.name} · {viewTitles[view]}</p></div><div className="live-status"><span /> REALTIME</div><button className="icon-button" aria-label="Esci" onClick={onLogout}><LogOut size={18} /></button></div></header>
}

function EmptyState({ icon: Icon, title, description }) {
  return <div className="empty-state"><Icon size={44} /><h3>{title}</h3><p>{description}</p></div>
}

function PinGate({ title, description, onUnlock, buttonLabel = 'Sblocca' }) {
  const [pin, setPin] = useState('')
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(false)
  const submit = async (event) => {
    event.preventDefault(); setLoading(true); setError('')
    try { const valid = await onUnlock(pin); if (!valid) setError('PIN non corretto') } catch { setError('PIN non corretto') } finally { setLoading(false) }
  }
  return <div className="pin-gate"><div className="pin-gate-icon"><LockKeyhole size={28} /></div><h2>{title}</h2><p>{description}</p><form onSubmit={submit}><input autoFocus aria-label="PIN di sblocco" type="password" inputMode="numeric" placeholder="••••" value={pin} onChange={(event) => setPin(event.target.value)} minLength={4} required />{error ? <span>{error}</span> : null}<button className="primary-button" disabled={loading}>{loading ? 'Verifica…' : buttonLabel}</button></form></div>
}

function Dashboard({ stats, setView }) {
  const actions = [
    ['command', ClipboardCheck, 'Comande', 'amber', stats.commands], ['kitchen', CookingPot, 'Cucina rapida', 'orange', stats.kitchenItems],
    ['bar', Beer, 'Schermo Bere', 'blue', stats.bar], ['cash', WalletCards, 'Punto Cassa', 'emerald', stats.toPay],
    ['history', History, 'Storico Ordini', 'slate', 0], ['menu', Settings2, 'Configura Listino', 'indigo', 0],
    ['stats', BarChart3, 'Statistiche', 'violet', 0],
  ]
  return <div className="stack-lg"><section className="welcome-panel"><div><p>Benvenuto</p><h2>Gestisci la tua sagra in tempo reale</h2></div><Cloud size={38} /></section><section className="stats-grid operational"><article className="stat-card slate"><p>Ordini oggi</p><strong>{stats.orders}</strong></article><article className="stat-card amber"><p>Comande aperte</p><strong>{stats.commands}</strong></article><article className="stat-card blue"><p>Al bar</p><strong>{stats.bar}</strong></article></section><button className="new-order-button" onClick={() => setView('order')}><span><Receipt size={24} /> Prendi Ordine</span><ChevronRight size={22} /></button><section className="action-grid">{actions.map(([id, Icon, label, tone, count]) => <button key={id} className={`action-card ${tone}`} onClick={() => setView(id)}><span className="action-icon"><Icon size={24} /></span><span>{label}</span>{count > 0 ? <b>{count}</b> : null}</button>)}</section></div>
}

function OrderScreen({ categories, products, onSubmit, onActivity }) {
  const [table, setTable] = useState('')
  const [notes, setNotes] = useState('')
  const [cart, setCart] = useState([])
  const [category, setCategory] = useState(categories[0]?.name || '')
  const [open, setOpen] = useState(false)
  const total = cart.reduce((sum, item) => sum + item.price * item.quantity, 0)
  const quantity = (id) => cart.find((item) => item.product_id === id)?.quantity || 0
  const add = (product) => setCart((current) => current.some((item) => item.product_id === product.id) ? current.map((item) => item.product_id === product.id ? { ...item, quantity: item.quantity + 1 } : item) : [...current, { product_id: product.id, name: product.name, price: Number(product.price), category: product.category, quantity: 1 }])
  const remove = (productId) => setCart((current) => current.flatMap((item) => item.product_id !== productId ? [item] : item.quantity > 1 ? [{ ...item, quantity: item.quantity - 1 }] : []))
  const send = async () => { if (!table.trim() || !cart.length) return; await onSubmit({ table_number: table.trim(), notes: notes.trim(), total, items: cart }); setTable(''); setNotes(''); setCart([]) }
  return <div className="order-layout" onPointerDown={onActivity} onKeyDown={onActivity}><section className="panel order-form original"><label>Tavolo<input value={table} onChange={(event) => setTable(event.target.value)} inputMode="numeric" placeholder="N°" /></label><label>Note ordine<input value={notes} onChange={(event) => setNotes(event.target.value)} placeholder="Varianti o intolleranze…" /></label></section><section className="menu-launch"><div><strong>Seleziona Piatti</strong><span>{cart.reduce((sum, item) => sum + item.quantity, 0)} prodotti inseriti</span></div><button onClick={() => { setOpen(true); setCategory(category || categories[0]?.name || '') }}><LayoutList size={18} /> Apri Menu</button></section><section className="cart-box"><header><span>Elementi nel Carrello</span><strong>{euro(total)}</strong></header><div className="cart-scroll">{cart.length ? cart.map((item) => <div className="cart-item" key={item.product_id}><div><strong>{item.name}</strong><small>{euro(item.price)} cad.</small></div><div className="stepper"><button aria-label={`Rimuovi ${item.name}`} onClick={() => remove(item.product_id)}><Minus size={14} /></button><b>{item.quantity}</b><button aria-label={`Aggiungi ${item.name}`} onClick={() => add({ id: item.product_id, ...item })}><Plus size={14} /></button></div></div>) : <div className="cart-empty"><ShoppingCart size={42} /><b>Nessun piatto selezionato</b></div>}</div><footer><button disabled={!table.trim() || !cart.length} onClick={send}><Receipt size={19} /> Invia Comanda</button></footer></section>{open ? <div className="modal-backdrop" onMouseDown={(event) => event.target === event.currentTarget && setOpen(false)}><section className="menu-modal original-menu"><div className="modal-header"><div><h2>Scegli dal Listino</h2><p>Tocca i piatti per aggiungerli alla comanda</p></div><button className="icon-button" onClick={() => setOpen(false)}><X size={20} /></button></div><div className="menu-browser"><nav>{categories.map((item) => <button className={category === item.name ? 'active' : ''} onClick={() => setCategory(item.name)} key={item.id}>{item.name}</button>)}</nav><div className="menu-products">{products.filter((item) => item.category === category).map((product) => <button className="menu-product" key={product.id} onClick={() => add(product)}><span>{product.name}</span><strong>{euro(product.price)}</strong><i><Plus size={14} /></i>{quantity(product.id) > 0 ? <b>{quantity(product.id)}</b> : null}</button>)}</div></div><footer className="menu-total"><div><span>Totale provvisorio</span><strong>{euro(total)}</strong></div><button onClick={() => setOpen(false)}>Conferma <Check size={16} /></button></footer></section></div> : null}</div>
}

function TableFilter({ value, onChange, count }) {
  return <div className="table-filter"><Search size={18} /><input aria-label="Filtra per tavolo" placeholder="Cerca tavolo…" value={value} onChange={(event) => onChange(event.target.value)} /><span>{count}</span></div>
}

function StationScreen({ type, orders, onDone }) {
  const [table, setTable] = useState('')
  const isBar = type === 'bar'
  const visible = orderOldestFirst(orders.filter((order) => !table || String(order.table_number).toLowerCase().includes(table.toLowerCase())))
  const title = isBar ? 'Nessuna bevanda da preparare' : 'Nessuna comanda aperta'
  const Icon = isBar ? Beer : ChefHat
  return <div className="station-view"><TableFilter value={table} onChange={setTable} count={visible.length} />{!visible.length ? <EmptyState icon={Icon} title={title} description="Le nuove ordinazioni compariranno automaticamente qui." /> : <div className="orders-rail">{visible.map((order) => <article className={`station-card ${isBar ? 'blue' : 'amber'}`} key={order.id}><header><strong>Tavolo {order.table_number}</strong><span>{new Date(order.created_at).toLocaleTimeString('it-IT', { hour: '2-digit', minute: '2-digit' })}</span></header><div className="station-items">{order.items.filter((item) => isBar ? DRINK_CATEGORIES.has(item.category) : !DRINK_CATEGORIES.has(item.category)).map((item) => <div key={`${order.id}-${item.name}`}><b>{item.quantity}</b><span>{item.name}</span></div>)}</div>{!isBar && order.notes ? <p className="order-notes">Nota cucina: {order.notes}</p> : null}<footer><small>#{compactId(order.id)}</small><button onClick={() => onDone(order.id, isBar ? { bar_done: true } : { kitchen_done: true })}>{isBar ? 'Pronto Bar' : 'Evadi Comanda'}</button></footer></article>)}</div>}</div>
}

function ProductionRow({ item, max, onComplete }) {
  const [selected, setSelected] = useState(item.quantity)
  useEffect(() => setSelected(item.quantity), [item.quantity])
  return <article><div className="production-qty">{item.quantity}</div><div className="production-main"><div><strong>{item.name}</strong><span>{item.orders} {item.orders === 1 ? 'comanda' : 'comande'}</span></div><div className="production-progress"><i style={{ width: `${Math.max(8, item.quantity / max * 100)}%` }} /></div><small>Da evadere ora</small><div className="production-stepper"><button aria-label={`Riduci quantità ${item.name}`} onClick={() => setSelected((value) => Math.max(1, value - 1))}><Minus size={16} /></button><b>{selected}</b><button aria-label={`Aumenta quantità ${item.name}`} onClick={() => setSelected((value) => Math.min(item.quantity, value + 1))}><Plus size={16} /></button></div></div><button onClick={() => onComplete(item.name, selected)}><Check size={18} /> Evadi {selected}</button></article>
}

function AggregateKitchen({ items, onComplete }) {
  if (!items.length) return <EmptyState icon={CookingPot} title="Produzione completata" description="Non ci sono piatti da preparare in questo momento." />
  const max = Math.max(...items.map((item) => item.quantity), 1)
  return <div className="aggregate-kitchen"><header><div><Sparkles size={20} /><span>Aggiornamento automatico realtime · priorità alle comande più vecchie</span></div><strong>{items.reduce((sum, item) => sum + item.quantity, 0)} porzioni da preparare</strong></header><div className="production-list">{items.map((item) => <ProductionRow key={item.name} item={item} max={max} onComplete={onComplete} />)}</div></div>
}

function CashScreen({ orders, onPaid }) {
  const [table, setTable] = useState('')
  const visible = orderOldestFirst(orders.filter((order) => !table || String(order.table_number).toLowerCase().includes(table.toLowerCase())))
  return <div className="station-view cash-view"><TableFilter value={table} onChange={setTable} count={visible.length} />{!visible.length ? <EmptyState icon={Banknote} title="Nessun conto trovato" description="Tutti i tavoli visibili hanno saldato." /> : <div className="orders-rail">{visible.map((order) => <article className="station-card cash" key={order.id}><header><strong>Tavolo {order.table_number}</strong><span className={order.kitchen_done ? 'ready' : ''}>{order.kitchen_done ? 'Pronto' : 'In lavorazione'}</span></header><div className="station-items receipt">{order.items.map((item) => <div key={`${order.id}-${item.name}`}><b>{item.quantity}</b><span>{item.name}</span><small>{euro(item.price * item.quantity)}</small></div>)}</div>{order.notes ? <p className="order-notes neutral">Note: {order.notes}</p> : null}<footer className="cash-footer"><strong>{euro(order.total)}</strong><button onClick={() => onPaid(order.id)}><WalletCards size={17} /> Incassa</button></footer></article>)}</div>}</div>
}

function HistoryScreen({ orders, onLoad }) {
  const [date, setDate] = useState(today()); const [table, setTable] = useState('')
  const [remoteOrders, setRemoteOrders] = useState([]); const [loading, setLoading] = useState(false); const [hasMore, setHasMore] = useState(false)
  const loadPage = useCallback(async (append = false) => {
    if (!onLoad) return
    setLoading(true)
    try {
      const current = append ? remoteOrders : []
      const page = await onLoad(date, table, current.at(-1) || null)
      setRemoteOrders(append ? [...current, ...page] : page)
      setHasMore(page.length === 200)
    } finally { setLoading(false) }
  }, [date, onLoad, remoteOrders, table])
  useEffect(() => {
    if (!onLoad) return undefined
    let active = true
    const timer = window.setTimeout(async () => {
      setLoading(true)
      try {
        const page = await onLoad(date, table, null)
        if (active) { setRemoteOrders(page); setHasMore(page.length === 200) }
      } finally { if (active) setLoading(false) }
    }, 220)
    return () => { active = false; window.clearTimeout(timer) }
  }, [date, onLoad, table])
  const filtered = onLoad ? remoteOrders : orderOldestFirst(orders.filter((order) => order.created_at.slice(0, 10) === date && (!table || String(order.table_number).toLowerCase().includes(table.toLowerCase()))))
  return <div className="history-wrap"><section className="panel filters"><label>Seleziona giorno archivio<input type="date" value={date} onChange={(event) => setDate(event.target.value)} /></label><label>Cerca tavolo<input placeholder="Numero tavolo" value={table} onChange={(event) => setTable(event.target.value)} /></label></section>{loading && !filtered.length ? <div className="loading compact"><span /></div> : !filtered.length ? <EmptyState icon={Archive} title="Nessun ordine trovato" description="Prova a cambiare giorno o numero del tavolo." /> : <><div className="history-list">{filtered.map((order) => <article className="history-card" key={order.id}><header className="history-summary"><div><h3>Tavolo {order.table_number} <small>#{compactId(order.id)}</small></h3><p>{new Date(order.created_at).toLocaleTimeString('it-IT', { hour: '2-digit', minute: '2-digit' })} · {order.paid ? 'Pagato' : 'Da pagare'}</p></div><strong>{euro(order.total)}</strong></header><div className="history-items">{order.items.map((item) => <div key={`${order.id}-${item.id || item.name}`}><b>{item.quantity}×</b><span>{item.name}<small>{item.category}</small></span><strong>{euro(Number(item.price) * item.quantity)}</strong></div>)}</div>{order.notes ? <p className="history-notes"><b>Note:</b> {order.notes}</p> : null}</article>)}</div>{hasMore ? <button className="load-more" disabled={loading} onClick={() => loadPage(true)}>{loading ? 'Caricamento…' : 'Carica altre 200 comande'}</button> : null}</>}</div>
}

function MenuScreen({ categories, products, isOwner, onLinkOwnerEmail, onAddCategory, onDeleteCategory, onAddProduct, onDeleteProduct }) {
  const [categoryName, setCategoryName] = useState(''); const [product, setProduct] = useState({ name: '', price: '5.00', category: categories[0]?.name || '' })
  const [ownerEmail, setOwnerEmail] = useState(''); const [ownerMessage, setOwnerMessage] = useState('')
  useEffect(() => { if (!product.category && categories[0]) setProduct((current) => ({ ...current, category: categories[0].name })) }, [categories, product.category])
  return <div className="menu-manager stack-lg">{isOwner ? <section className="panel account-protection"><h3><ShieldCheck size={18} /> Protezione e recupero account</h3><p>Collega un’email verificata per recuperare codice sagra e PIN.</p><div className="inline-form"><input type="email" placeholder="Email del proprietario" value={ownerEmail} onChange={(event) => setOwnerEmail(event.target.value)} /><button aria-label="Collega email proprietario" onClick={async () => { if (!ownerEmail.trim()) return; try { await onLinkOwnerEmail(ownerEmail); setOwnerMessage('Email inviata: apri il link per confermarla.') } catch (error) { setOwnerMessage(error.message || 'Invio non riuscito') } }}><Mail size={18} /></button></div>{ownerMessage ? <small>{ownerMessage}</small> : null}</section> : null}<section className="panel"><h3><FolderPlus size={18} /> Crea Nuova Categoria</h3><div className="inline-form"><input placeholder="Es: Dolci, Bere, Primi Piatti…" value={categoryName} onChange={(event) => setCategoryName(event.target.value)} /><button onClick={async () => { if (categoryName.trim()) { await onAddCategory(categoryName.trim()); setCategoryName('') } }}><Plus size={18} /></button></div></section><section className="panel"><h3><CirclePlus size={18} /> Aggiungi Piatto nel Listino</h3><input placeholder="Nome piatto" value={product.name} onChange={(event) => setProduct({ ...product, name: event.target.value })} /><div className="two-cols"><input type="number" step="0.5" placeholder="Prezzo €" value={product.price} onChange={(event) => setProduct({ ...product, price: event.target.value })} /><select value={product.category} onChange={(event) => setProduct({ ...product, category: event.target.value })}>{categories.map((item) => <option key={item.id}>{item.name}</option>)}</select></div><button className="success-button" onClick={async () => { if (product.name && product.category) { await onAddProduct({ ...product, price: Number(product.price) }); setProduct({ ...product, name: '' }) } }}>Salva nel Listino</button></section>{categories.map((category) => <section className="category-section" key={category.id}><header><h3>{category.name}</h3><button aria-label={`Elimina categoria ${category.name}`} onClick={() => onDeleteCategory(category.name)}><Trash2 size={16} /></button></header><div>{products.filter((item) => item.category === category.name).map((item) => <article key={item.id}><div><strong>{item.name}</strong><span>{euro(item.price)}</span></div><button onClick={() => onDeleteProduct(item.id)}><Minus size={14} /></button></article>)}</div></section>)}</div>
}

function RevenueTrend({ data }) {
  if (!data.length) return <p className="chart-empty">Nessun dato nel periodo selezionato.</p>
  const max = Math.max(...data.map((item) => item.revenue), 1)
  const points = data.map((item, index) => ({ x: data.length === 1 ? 320 : 22 + index * (596 / (data.length - 1)), y: 184 - (item.revenue / max) * 146, ...item }))
  const line = points.map((point) => `${point.x},${point.y}`).join(' ')
  const area = `22,184 ${line} ${points.at(-1).x},184`
  return <div className="trend-chart"><svg viewBox="0 0 640 210" role="img" aria-label="Andamento degli incassi"><defs><linearGradient id="revenue-fill" x1="0" x2="0" y1="0" y2="1"><stop offset="0" stopColor="#7c3aed" stopOpacity=".3" /><stop offset="1" stopColor="#7c3aed" stopOpacity="0" /></linearGradient></defs><g className="chart-grid-lines"><line x1="22" x2="618" y1="38" y2="38" /><line x1="22" x2="618" y1="111" y2="111" /><line x1="22" x2="618" y1="184" y2="184" /></g><polygon points={area} fill="url(#revenue-fill)" /><polyline points={line} fill="none" stroke="#6d5dfc" strokeWidth="4" strokeLinecap="round" strokeLinejoin="round" pathLength="1" />{points.map((point) => <circle key={point.date} cx={point.x} cy={point.y} r="5" fill="white" stroke="#6d5dfc" strokeWidth="3"><title>{point.label}: {euro(point.revenue)}</title></circle>)}</svg><div className="trend-labels">{points.map((point) => <span key={point.date}>{point.shortLabel}</span>)}</div></div>
}

function HourlyChart({ data }) {
  const max = Math.max(...data.map((item) => item.value), 1)
  return <div className="hourly-chart">{data.map((item) => <div className="hour-column" key={item.hour} title={`${item.hour}:00 · ${item.value} ordini`}><b style={{ height: `${Math.max(4, item.value / max * 100)}%` }} /><span>{item.hour % 4 === 0 ? `${String(item.hour).padStart(2, '0')}` : ''}</span></div>)}</div>
}

function CategoryDonut({ data, total }) {
  const colors = ['#4f46e5', '#7c3aed', '#22c55e', '#f59e0b', '#0ea5e9', '#ef4444']
  let cursor = 0
  const stops = data.map((item, index) => { const start = cursor; cursor += total ? item.value / total * 100 : 0; return `${colors[index % colors.length]} ${start}% ${cursor}%` })
  return <div className="donut-layout"><div className="donut" style={{ background: stops.length ? `conic-gradient(${stops.join(',')})` : '#e2e8f0' }}><div><strong>{euro(total)}</strong><span>incasso</span></div></div><div className="donut-legend">{data.map((item, index) => <div key={item.label}><i style={{ background: colors[index % colors.length] }} /><span>{item.label}</span><b>{total ? Math.round(item.value / total * 100) : 0}%</b></div>)}</div></div>
}

function StatsScreen({ festivalName, orders, menuProducts = [], onLoad }) {
  const [preset, setPreset] = useState('7d')
  const [startDate, setStartDate] = useState(dateDaysAgo(6))
  const [endDate, setEndDate] = useState(today())
  const [serverData, setServerData] = useState(null)
  const [loading, setLoading] = useState(false)
  const [exporting, setExporting] = useState(false)
  const selectPreset = (next) => {
    setPreset(next)
    if (next === 'today') setStartDate(today())
    if (next === '7d') setStartDate(dateDaysAgo(6))
    if (next === '30d') setStartDate(dateDaysAgo(29))
    if (next !== 'all') setEndDate(today())
    if (next === 'all') { setStartDate('2000-01-01'); setEndDate(today()) }
  }
  useEffect(() => {
    if (!onLoad || !startDate || !endDate) return undefined
    let active = true
    setLoading(true)
    onLoad(startDate, endDate)
      .then((result) => { if (active) setServerData(result) })
      .catch(() => { if (active) setServerData(null) })
      .finally(() => { if (active) setLoading(false) })
    return () => { active = false }
  }, [endDate, onLoad, startDate])
  const filteredOrders = useMemo(() => (serverData?.rawOrders || orders).filter((order) => {
    const date = order.created_at.slice(0, 10)
    return (!startDate || date >= startDate) && (!endDate || date <= endDate)
  }), [orders, serverData, startDate, endDate])
  const analytics = useMemo(() => {
    if (serverData && !serverData.rawOrders) {
      const ranked = (serverData.ranked || []).map((item) => ({ ...item, quantity: Number(item.quantity), revenue: Number(item.revenue) }))
      const hourly = (serverData.hourly || []).map((item) => ({ hour: Number(item.hour), value: Number(item.value) }))
      const totalRevenue = Number(serverData.totalRevenue || 0)
      const orderCount = Number(serverData.orderCount || 0)
      const paidCount = Number(serverData.paidCount || 0)
      const foods = ranked.filter((item) => !DRINK_CATEGORIES.has(item.category)); const drinks = ranked.filter((item) => DRINK_CATEGORIES.has(item.category))
      const days = (serverData.days || []).map((item) => ({ ...item, revenue: Number(item.revenue), orders: Number(item.orders), label: new Date(`${item.date}T12:00:00`).toLocaleDateString('it-IT', { weekday: 'long', day: '2-digit', month: 'short' }), shortLabel: new Date(`${item.date}T12:00:00`).toLocaleDateString('it-IT', { day: '2-digit', month: 'short' }) }))
      const peakHour = hourly.reduce((best, item) => item.value > best.value ? item : best, hourly[0] || { hour: 0, value: 0 })
      return { totalRevenue, orderCount, average: paidCount ? totalRevenue / paidCount : 0, paidRate: orderCount ? paidCount / orderCount * 100 : 0, portions: Number(serverData.portions || 0), ranked, foods, drinks, days, hourly, peakHour, categories: (serverData.categories || []).map((item) => ({ ...item, value: Number(item.value) })), open: Number(serverData.open || 0), openAmount: Number(serverData.openAmount || 0), ready: Number(serverData.ready || 0) }
    }
    const paid = filteredOrders.filter((order) => order.paid)
    const products = new Map(); const daily = new Map(); const hourly = Array.from({ length: 24 }, (_, hour) => ({ hour, value: 0 })); const categories = new Map()
    let portions = 0
    for (const order of filteredOrders) {
      const day = order.created_at.slice(0, 10)
      const currentDay = daily.get(day) || { revenue: 0, orders: 0 }
      currentDay.orders += 1; if (order.paid) currentDay.revenue += Number(order.total); daily.set(day, currentDay)
      hourly[new Date(order.created_at).getHours()].value += 1
      for (const item of order.items) {
        const current = products.get(item.name) || { quantity: 0, revenue: 0, category: item.category }
        current.quantity += item.quantity; current.revenue += Number(item.price) * item.quantity; products.set(item.name, current); portions += item.quantity
        if (order.paid) categories.set(item.category, (categories.get(item.category) || 0) + Number(item.price) * item.quantity)
      }
    }
    const ranked = [...products].map(([name, value]) => ({ name, ...value })).sort((a, b) => b.quantity - a.quantity)
    const foods = ranked.filter((item) => !DRINK_CATEGORIES.has(item.category)); const drinks = ranked.filter((item) => DRINK_CATEGORIES.has(item.category))
    const days = [...daily].sort(([a], [b]) => a.localeCompare(b)).map(([date, value]) => ({ date, ...value, label: new Date(`${date}T12:00:00`).toLocaleDateString('it-IT', { weekday: 'long', day: '2-digit', month: 'short' }), shortLabel: new Date(`${date}T12:00:00`).toLocaleDateString('it-IT', { day: '2-digit', month: 'short' }) }))
    const totalRevenue = paid.reduce((sum, order) => sum + Number(order.total), 0)
    const peakHour = hourly.reduce((best, item) => item.value > best.value ? item : best, hourly[0])
    return { totalRevenue, orderCount: filteredOrders.length, average: paid.length ? totalRevenue / paid.length : 0, paidRate: filteredOrders.length ? paid.length / filteredOrders.length * 100 : 0, portions, ranked, foods, drinks, days, hourly, peakHour, categories: [...categories].map(([label, value]) => ({ label, value })).sort((a, b) => b.value - a.value), open: filteredOrders.length - paid.length, openAmount: filteredOrders.filter((order) => !order.paid).reduce((sum, order) => sum + Number(order.total), 0), ready: filteredOrders.filter((order) => order.kitchen_done).length }
  }, [filteredOrders, serverData])
  const downloadReport = async () => {
    setExporting(true)
    try {
      const { downloadStatsPdf } = await import('./utils/reportPdf.js')
      downloadStatsPdf({ festivalName, startDate, endDate, analytics, menuProducts })
    } finally { setExporting(false) }
  }
  if (loading && !serverData) return <div className="loading"><span /></div>
  return <div className="stats-page"><section className="stats-toolbar"><div><CalendarDays size={18} /><strong>Periodo</strong></div><div className="period-presets">{[['today', 'Oggi'], ['7d', '7 giorni'], ['30d', '30 giorni'], ['all', 'Tutto']].map(([value, label]) => <button className={preset === value ? 'active' : ''} key={value} onClick={() => selectPreset(value)}>{label}</button>)}</div><label>Da<input type="date" value={startDate} onChange={(event) => { setStartDate(event.target.value); setPreset('custom') }} /></label><label>A<input type="date" value={endDate} onChange={(event) => { setEndDate(event.target.value); setPreset('custom') }} /></label><button className="pdf-report-button" disabled={exporting} onClick={downloadReport}><Download size={16} />{exporting ? 'Creazione…' : 'Scarica report PDF'}</button></section><section className="stats-hero"><div><p>Incasso nel periodo</p><h2>{euro(analytics.totalRevenue)}</h2><span>{analytics.orderCount} ordini · {analytics.portions} prodotti venduti</span></div><div className="hero-trend"><TrendingUp size={30} /><span>{analytics.paidRate.toFixed(0)}% incassato</span></div></section><section className="metric-grid expanded"><article><Banknote /><span>Incasso</span><strong>{euro(analytics.totalRevenue)}</strong></article><article><Receipt /><span>Ordini</span><strong>{analytics.orderCount}</strong></article><article><Gauge /><span>Scontrino medio</span><strong>{euro(analytics.average)}</strong></article><article><WalletCards /><span>Ordini pagati</span><strong>{analytics.paidRate.toFixed(1)}%</strong></article><article><ChefHat /><span>Porzioni vendute</span><strong>{analytics.portions}</strong></article><article><Clock3 /><span>Ora più attiva</span><strong>{String(analytics.peakHour.hour).padStart(2, '0')}:00</strong><small>{analytics.peakHour.value} ordini</small></article></section><section className="chart-grid analytics-grid"><article className="chart-card trend-card"><header><div><h3>Andamento incassi</h3><p>Ricavi giornalieri degli ordini pagati</p></div><TrendingUp /></header><RevenueTrend data={analytics.days} /></article><article className="chart-card hourly-card"><header><div><h3>Ordini per ora</h3><p>Distribuzione nell’arco della giornata</p></div><Clock3 /></header><HourlyChart data={analytics.hourly} /></article><article className="chart-card category-card"><header><div><h3>Incasso per categoria</h3><p>Peso sul totale del periodo</p></div><BarChart3 /></header><CategoryDonut data={analytics.categories.slice(0, 6)} total={analytics.totalRevenue} /></article><article className="chart-card ranking-card"><header><div><h3>Prodotti più venduti</h3><p>Quantità e fatturato generato</p></div><Trophy /></header>{analytics.ranked.length ? <div className="product-ranking">{analytics.ranked.slice(0, 7).map((item, index) => <div key={item.name}><b>{index + 1}</b><span><strong>{item.name}</strong><small>{item.quantity} unità</small></span><em>{euro(item.revenue)}</em></div>)}</div> : <p className="chart-empty">Nessun prodotto nel periodo.</p>}</article><article className="chart-card insights-card"><header><div><h3>Riepilogo operativo</h3><p>Stato degli ordini selezionati</p></div><Sparkles /></header><div className="insight-grid"><div><span>Da incassare</span><strong>{analytics.open}</strong><small>{euro(analytics.openAmount)}</small></div><div><span>Cucina completata</span><strong>{analytics.ready}</strong><small>su {analytics.orderCount} ordini</small></div><div><span>Top piatto</span><strong>{analytics.foods[0]?.name || '—'}</strong><small>{analytics.foods[0]?.quantity || 0} porzioni</small></div><div><span>Top bevanda</span><strong>{analytics.drinks[0]?.name || '—'}</strong><small>{analytics.drinks[0]?.quantity || 0} unità</small></div></div></article></section></div>
}

function Toast({ message }) { return message ? <div className="toast">{message}</div> : null }

function OperationalApp() {
  const [festival, setFestival] = useState(loadSession)
  const [view, setViewState] = useState('dashboard')
  const [data, setData] = useState({ categories: [], products: [], orders: [], orderCount: 0, membership: null })
  const [message, setMessage] = useState('')
  const [loading, setLoading] = useState(Boolean(festival))
  const [orderLocked, setOrderLocked] = useState(false)
  const [statsUnlocked, setStatsUnlocked] = useState(false)
  const [license, setLicense] = useState(null)
  const [upgradeRequest, setUpgradeRequest] = useState(null)
  const [requestingUpgrade, setRequestingUpgrade] = useState(false)
  const activityRef = useRef(Number(localStorage.getItem(ORDER_ACTIVITY_KEY) || 0))
  const notify = useCallback((text) => { setMessage(text); window.setTimeout(() => setMessage(''), 2200) }, [])
  const refresh = useCallback(async () => { if (!festival?.id) return; try { setData(await sagraApi.load(festival.id)) } catch (error) { notify(error.message) } finally { setLoading(false) } }, [festival?.id, notify])
  const loadHistory = useCallback((date, table, cursor) => sagraApi.loadOrderHistory(festival.id, date, table, cursor), [festival?.id])
  const loadAnalytics = useCallback((from, to) => sagraApi.loadAnalytics(festival.id, from, to), [festival?.id])
  useEffect(() => { refresh() }, [refresh])
  useEffect(() => festival?.id ? sagraApi.subscribe(festival.id, refresh) : undefined, [festival?.id, refresh])
  useEffect(() => {
    if (!festival?.id) return undefined
    let active = true
    const heartbeat = async () => { try { const result = await sagraApi.openSession(festival.id); if (!active) return; setLicense(result); if (Number(result.orders_used) >= Number(result.max_orders)) { const pending = await sagraApi.getOrderUpgradeRequest(festival.id); if (active) setUpgradeRequest(pending) } else setUpgradeRequest(null) } catch (error) { if (active) setLicense({ allowed: false, message: error.message }) } }
    heartbeat()
    const timer = window.setInterval(heartbeat, 30_000)
    const release = () => { sagraApi.closeSession(festival.id).catch(() => {}) }
    window.addEventListener('pagehide', release)
    return () => { active = false; window.clearInterval(timer); window.removeEventListener('pagehide', release) }
  }, [festival?.id])
  useEffect(() => { if (view !== 'order') return undefined; const timer = window.setInterval(() => { if (Date.now() - activityRef.current > ORDER_IDLE_MS) setOrderLocked(true) }, 60_000); return () => window.clearInterval(timer) }, [view])
  const touchOrder = useCallback(() => { const now = Date.now(); if (now - activityRef.current < 10_000) return; activityRef.current = now; localStorage.setItem(ORDER_ACTIVITY_KEY, String(now)) }, [])
  const setView = (nextView) => { if (nextView === 'order') setOrderLocked(Date.now() - activityRef.current > ORDER_IDLE_MS); setViewState(nextView) }
  const authenticated = (selected, successMessage = '') => { const safeFestival = { id: selected.id, name: selected.name, slug: selected.slug }; localStorage.setItem(SESSION_KEY, JSON.stringify({ festival: safeFestival, authenticatedDay: today() })); const now = Date.now(); localStorage.setItem(ORDER_ACTIVITY_KEY, String(now)); activityRef.current = now; setFestival(safeFestival); if (successMessage) notify(successMessage) }
  const logout = () => { if (festival?.id) sagraApi.closeSession(festival.id).catch(() => {}); localStorage.removeItem(SESSION_KEY); sessionStorage.removeItem('sagra-stats-unlocked'); setFestival(null); setLicense(null); setViewState('dashboard'); setData({ categories: [], products: [], orders: [], orderCount: 0, membership: null }) }
  const mutate = async (action, success) => { try { await action(); await refresh(); notify(success) } catch (error) { notify(error.message) } }
  const createProduct = async (product) => {
    try {
      const created = await sagraApi.createProduct(festival.id, product)
      if (created) setData((current) => ({ ...current, products: [...current.products.filter((item) => item.id !== created.id), created].sort((a, b) => a.name.localeCompare(b.name, 'it')) }))
      else await refresh()
      notify('Piatto aggiunto')
    } catch (error) { notify(error.message) }
  }
  const requestOrderUpgrade = async () => {
    setRequestingUpgrade(true)
    try { setUpgradeRequest(await sagraApi.requestOrderUpgrade(festival.id)); notify('Richiesta inviata al Manager') } catch (error) { notify(error.message) } finally { setRequestingUpgrade(false) }
  }
  const todayOrders = useMemo(() => orderOldestFirst(data.orders.filter((order) => order.created_at.slice(0, 10) === today())), [data.orders])
  const hasKitchen = (order) => order.items.some((item) => !DRINK_CATEGORIES.has(item.category))
  const hasBar = (order) => order.items.some((item) => DRINK_CATEGORIES.has(item.category))
  const commandOrders = todayOrders.filter((order) => hasKitchen(order) && !order.kitchen_done)
  const barOrders = todayOrders.filter((order) => hasBar(order) && !order.bar_done)
  const toPay = todayOrders.filter((order) => !order.paid)
  const kitchenItems = useMemo(() => {
    const aggregate = new Map()
    for (const order of commandOrders) for (const item of order.items) if (!DRINK_CATEGORIES.has(item.category)) {
      const remaining = Math.max(0, item.quantity - Number(item.prepared_quantity || 0)); if (!remaining) continue
      const current = aggregate.get(item.name) || { name: item.name, quantity: 0, orderIds: new Set() }
      current.quantity += remaining; current.orderIds.add(order.id); aggregate.set(item.name, current)
    }
    return [...aggregate.values()].map((item) => ({ ...item, orders: item.orderIds.size })).sort((a, b) => b.quantity - a.quantity || a.name.localeCompare(b.name))
  }, [commandOrders])
  const operationalStats = { orders: data.orderCount ?? todayOrders.length, commands: commandOrders.length, kitchenItems: kitchenItems.reduce((sum, item) => sum + item.quantity, 0), bar: barOrders.length, toPay: toPay.length }
  if (!festival) return <AuthScreen onAuthenticated={authenticated} />
  if (!license) return <div className="loading"><span /></div>
  if (!license.allowed) return <LicenseBlocked message={license.message} onLogout={logout} />
  const orderGate = view === 'order' && orderLocked
  const statsGate = view === 'stats' && !statsUnlocked
  const orderLimit = Number(license.orders_used) >= Number(license.max_orders)
  return <div className="app-shell"><Header festival={festival} view={view} setView={setView} onLogout={logout} /><main className="app-main">{orderLimit ? <div className="license-alert"><span>Limite massimo di ordini raggiunto. Non è possibile aggiungere altri ordini.</span><UpgradeRequestButton request={upgradeRequest} requesting={requestingUpgrade} onRequest={requestOrderUpgrade} /></div> : null}{isDemoMode ? <div className="demo-banner">Modalità demo locale · PIN statistiche <code>9999</code></div> : null}{loading ? <div className="loading"><span /></div> : null}{!loading && view === 'dashboard' ? <Dashboard stats={operationalStats} setView={setView} /> : null}{!loading && orderGate ? <PinGate title="Sessione ordini scaduta" description="Sono passati 30 minuti di inattività. Inserisci il PIN operativo per continuare a prendere ordini." onUnlock={async (pin) => { try { await sagraApi.loginFestival(festival.slug, pin); const now = Date.now(); activityRef.current = now; localStorage.setItem(ORDER_ACTIVITY_KEY, String(now)); setOrderLocked(false); return true } catch { return false } }} /> : null}{!loading && view === 'order' && !orderGate && orderLimit ? <LicenseBlocked message="Limite massimo di ordini raggiunto. Non è possibile aggiungere altri ordini." onLogout={logout} onBack={() => setView('dashboard')} upgradeRequest={upgradeRequest} requestingUpgrade={requestingUpgrade} onRequestUpgrade={requestOrderUpgrade} /> : null}{!loading && view === 'order' && !orderGate && !orderLimit ? <OrderScreen categories={data.categories} products={data.products} onActivity={touchOrder} onSubmit={(order) => mutate(() => sagraApi.createOrder(festival.id, order), 'Ordinazione inviata!')} /> : null}{!loading && view === 'command' ? <StationScreen type="command" orders={commandOrders} onDone={(id, changes) => mutate(() => sagraApi.updateOrder(id, changes), 'Comanda completata')} /> : null}{!loading && view === 'kitchen' ? <AggregateKitchen items={kitchenItems} onComplete={(name, quantity) => mutate(() => sagraApi.completeKitchenProduct(festival.id, name, quantity), `${quantity} × ${name} evasi`)} /> : null}{!loading && view === 'bar' ? <StationScreen type="bar" orders={barOrders} onDone={(id, changes) => mutate(() => sagraApi.updateOrder(id, changes), 'Comanda bar completata')} /> : null}{!loading && view === 'cash' ? <CashScreen orders={toPay} onPaid={(id) => mutate(() => sagraApi.updateOrder(id, { paid: true }), 'Conto incassato')} /> : null}{!loading && view === 'history' ? <HistoryScreen orders={data.orders} onLoad={loadHistory} /> : null}{!loading && view === 'menu' ? <MenuScreen categories={data.categories} products={data.products} isOwner={data.membership?.role === 'owner'} onLinkOwnerEmail={(email) => sagraApi.linkOwnerEmail(email)} onAddCategory={(name) => mutate(() => sagraApi.createCategory(festival.id, name), 'Categoria aggiunta')} onDeleteCategory={(name) => mutate(() => sagraApi.deleteCategory(festival.id, name), 'Categoria rimossa')} onAddProduct={createProduct} onDeleteProduct={(id) => mutate(() => sagraApi.deleteProduct(id), 'Piatto rimosso')} /> : null}{!loading && statsGate ? <PinGate title="Statistiche riservate" description="Questa sezione contiene incassi e dati economici. Inserisci il PIN statistiche." onUnlock={async (pin) => { const valid = await sagraApi.verifyStatsPin(festival.id, pin); if (valid) setStatsUnlocked(true); return valid }} buttonLabel="Apri statistiche" /> : null}{!loading && view === 'stats' && !statsGate ? <StatsScreen festivalName={festival.name} orders={data.orders} menuProducts={data.products} onLoad={loadAnalytics} /> : null}</main><Toast message={message} /></div>
}

export default function App() {
  return window.location.pathname.startsWith('/manager') ? <Suspense fallback={<div className="loading"><span /></div>}><ManagerApp /></Suspense> : <OperationalApp />
}
