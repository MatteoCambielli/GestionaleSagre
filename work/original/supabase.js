// Configurazione di Supabase
const SUPABASE_URL = window.__ORDIVA_SUPABASE_URL__ || '';
const SUPABASE_KEY = window.__ORDIVA_SUPABASE_PUBLISHABLE_KEY__ || '';

// Inizializzazione del client globale
const supabaseClient = window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
