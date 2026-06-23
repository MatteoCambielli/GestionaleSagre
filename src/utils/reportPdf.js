import { jsPDF } from 'jspdf'
import { autoTable } from 'jspdf-autotable'

const formatMoney = (value) => `${new Intl.NumberFormat('it-IT', { minimumFractionDigits: 2, maximumFractionDigits: 2 }).format(Number(value || 0))} EUR`
const formatNumber = (value) => new Intl.NumberFormat('it-IT').format(Number(value || 0))
const safeName = (value) => String(value || 'evento').toLowerCase().normalize('NFD').replace(/[\u0300-\u036f]/g, '').replace(/[^a-z0-9]+/g, '-').replace(/(^-|-$)/g, '')

const addSectionTitle = (doc, title, subtitle, y) => {
  doc.setTextColor(16, 27, 51)
  doc.setFont('helvetica', 'bold')
  doc.setFontSize(15)
  doc.text(title, 14, y)
  doc.setTextColor(104, 117, 141)
  doc.setFont('helvetica', 'normal')
  doc.setFontSize(8)
  if (subtitle) doc.text(subtitle, 14, y + 5)
}

const addDailyChart = (doc, days, y) => {
  const chart = { x: 14, y, width: 182, height: 50 }
  doc.setFillColor(248, 250, 252)
  doc.roundedRect(chart.x, chart.y, chart.width, chart.height, 3, 3, 'F')
  if (!days.length) {
    doc.setTextColor(104, 117, 141); doc.setFontSize(9); doc.text('Nessun dato giornaliero nel periodo.', 20, y + 27)
    return
  }
  const max = Math.max(1, ...days.map((item) => Number(item.revenue || 0)))
  const gap = 2
  const barWidth = Math.max(2, Math.min(14, (chart.width - 16 - gap * (days.length - 1)) / days.length))
  const totalWidth = barWidth * days.length + gap * (days.length - 1)
  const startX = chart.x + (chart.width - totalWidth) / 2
  days.forEach((item, index) => {
    const height = Math.max(1, Number(item.revenue || 0) / max * 34)
    doc.setFillColor(255, 79, 22)
    doc.roundedRect(startX + index * (barWidth + gap), chart.y + 40 - height, barWidth, height, 1, 1, 'F')
  })
  doc.setTextColor(104, 117, 141); doc.setFontSize(7)
  doc.text(`Picco: ${formatMoney(max)}`, chart.x + 5, chart.y + 47)
}

export function buildStatsPdf({ festivalName, startDate, endDate, analytics, menuProducts = [] }) {
  const doc = new jsPDF({ unit: 'mm', format: 'a4', compress: true })
  const generatedAt = new Date().toLocaleString('it-IT')

  doc.setFillColor(6, 26, 54)
  doc.rect(0, 0, 210, 45, 'F')
  doc.setTextColor(255, 255, 255)
  doc.setFont('helvetica', 'bold'); doc.setFontSize(25); doc.text('Ordiva', 14, 19)
  doc.setFontSize(15); doc.text('Report completo evento', 14, 30)
  doc.setTextColor(197, 211, 229); doc.setFont('helvetica', 'normal'); doc.setFontSize(9)
  doc.text(`${festivalName}  |  ${startDate} - ${endDate}`, 14, 38)

  const metrics = [
    ['Incasso pagato', formatMoney(analytics.totalRevenue)],
    ['Ordini', formatNumber(analytics.orderCount)],
    ['Scontrino medio', formatMoney(analytics.average)],
    ['Prodotti venduti', formatNumber(analytics.portions)],
    ['Ordini pagati', `${Number(analytics.paidRate || 0).toFixed(1)}%`],
    ['Da incassare', `${formatNumber(analytics.open)} (${formatMoney(analytics.openAmount)})`],
  ]
  metrics.forEach(([label, value], index) => {
    const column = index % 3; const row = Math.floor(index / 3)
    const x = 14 + column * 61; const y = 54 + row * 22
    doc.setFillColor(248, 250, 252); doc.roundedRect(x, y, 57, 17, 2, 2, 'F')
    doc.setTextColor(104, 117, 141); doc.setFontSize(7); doc.text(label.toUpperCase(), x + 4, y + 5)
    doc.setTextColor(16, 27, 51); doc.setFont('helvetica', 'bold'); doc.setFontSize(11); doc.text(String(value), x + 4, y + 12)
    doc.setFont('helvetica', 'normal')
  })

  addSectionTitle(doc, 'Andamento giornaliero', 'Incassi degli ordini pagati nel periodo', 104)
  addDailyChart(doc, analytics.days || [], 113)

  autoTable(doc, {
    startY: 169,
    head: [['Giorno', 'Ordini', 'Incasso pagato', 'Media ordine']],
    body: (analytics.days || []).map((item) => [item.date, formatNumber(item.orders), formatMoney(item.revenue), formatMoney(item.orders ? Number(item.revenue) / Number(item.orders) : 0)]),
    theme: 'grid',
    styles: { font: 'helvetica', fontSize: 8, cellPadding: 2.4, lineColor: [226, 232, 240], lineWidth: .2 },
    headStyles: { fillColor: [6, 26, 54], textColor: 255, fontStyle: 'bold' },
    alternateRowStyles: { fillColor: [248, 250, 252] },
  })

  doc.addPage()
  addSectionTitle(doc, 'Listino menu', `${formatNumber(menuProducts.length)} prodotti configurati nell'evento`, 18)
  autoTable(doc, {
    startY: 27,
    head: [['#', 'Prodotto', 'Categoria', 'Prezzo']],
    body: [...menuProducts].sort((a, b) => String(a.category).localeCompare(String(b.category), 'it') || String(a.name).localeCompare(String(b.name), 'it')).map((item, index) => [index + 1, item.name, item.category, formatMoney(item.price)]),
    theme: 'striped',
    styles: { font: 'helvetica', fontSize: 8, cellPadding: 2.4 },
    headStyles: { fillColor: [255, 79, 22], textColor: 255 },
  })

  doc.addPage()
  addSectionTitle(doc, 'Prodotti piu venduti', 'Top 20 per quantita e ricavo teorico generato', 18)
  autoTable(doc, {
    startY: 27,
    head: [['#', 'Prodotto', 'Categoria', 'Quantita', 'Ricavo']],
    body: (analytics.ranked || []).slice(0, 20).map((item, index) => [index + 1, item.name, item.category, formatNumber(item.quantity), formatMoney(item.revenue)]),
    theme: 'striped',
    styles: { font: 'helvetica', fontSize: 8, cellPadding: 2.2 },
    headStyles: { fillColor: [255, 79, 22], textColor: 255 },
  })

  const nextY = Math.min(250, (doc.lastAutoTable?.finalY || 35) + 13)
  if (nextY > 220) doc.addPage()
  const categoryY = nextY > 220 ? 18 : nextY
  addSectionTitle(doc, 'Categorie e fasce orarie', 'Distribuzione economica e carico operativo', categoryY)
  autoTable(doc, {
    startY: categoryY + 9,
    margin: { right: 109 },
    head: [['Categoria', 'Incasso']],
    body: (analytics.categories || []).slice(0, 10).map((item) => [item.label, formatMoney(item.value)]),
    theme: 'grid', styles: { fontSize: 8, cellPadding: 2 }, headStyles: { fillColor: [37, 99, 235] },
  })
  autoTable(doc, {
    startY: categoryY + 9,
    margin: { left: 109 },
    head: [['Ora', 'Ordini']],
    body: (analytics.hourly || []).filter((item) => Number(item.value) > 0).sort((a, b) => Number(b.value) - Number(a.value)).slice(0, 10).map((item) => [`${String(item.hour).padStart(2, '0')}:00`, formatNumber(item.value)]),
    theme: 'grid', styles: { fontSize: 8, cellPadding: 2 }, headStyles: { fillColor: [124, 58, 237] },
  })

  doc.addPage()
  addSectionTitle(doc, 'Riepilogo operativo', 'Indicatori conclusivi e stato delle lavorazioni', 18)
  autoTable(doc, {
    startY: 28,
    body: [
      ['Ordini complessivi', formatNumber(analytics.orderCount)],
      ['Ordini aperti / non pagati', formatNumber(analytics.open)],
      ['Valore ancora da incassare', formatMoney(analytics.openAmount)],
      ['Ordini con cucina completata', formatNumber(analytics.ready)],
      ['Ora piu attiva', `${String(analytics.peakHour?.hour || 0).padStart(2, '0')}:00 (${formatNumber(analytics.peakHour?.value || 0)} ordini)`],
      ['Piatto piu venduto', analytics.foods?.[0]?.name || 'Nessun dato'],
      ['Bevanda piu venduta', analytics.drinks?.[0]?.name || 'Nessun dato'],
    ],
    theme: 'grid', styles: { fontSize: 9, cellPadding: 3 }, columnStyles: { 0: { fontStyle: 'bold', fillColor: [248, 250, 252] } },
  })
  doc.setTextColor(104, 117, 141); doc.setFontSize(8)
  doc.text('Note sul calcolo', 14, (doc.lastAutoTable?.finalY || 75) + 16)
  doc.text('Gli incassi includono esclusivamente gli ordini segnati come pagati. Il ricavo prodotti e calcolato usando il prezzo registrato nella singola comanda.', 14, (doc.lastAutoTable?.finalY || 75) + 22, { maxWidth: 182 })

  const pages = doc.getNumberOfPages()
  for (let page = 1; page <= pages; page += 1) {
    doc.setPage(page)
    doc.setDrawColor(226, 232, 240); doc.line(14, 286, 196, 286)
    doc.setTextColor(104, 117, 141); doc.setFontSize(7)
    doc.text(`Generato da Ordiva il ${generatedAt}`, 14, 291)
    doc.text(`Pagina ${page} di ${pages}`, 196, 291, { align: 'right' })
  }
  return doc
}

export function downloadStatsPdf(payload) {
  const doc = buildStatsPdf(payload)
  doc.save(`ordiva-report-${safeName(payload.festivalName)}-${payload.startDate}-${payload.endDate}.pdf`)
}
