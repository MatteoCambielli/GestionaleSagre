// Configurazione di Supabase
const SUPABASE_URL = 'https://hlmjxqwcqqmhgnlczqwr.supabase.co';
const SUPABASE_KEY = 'sb_publishable_uyjq49inGHkYGDlZUik7tw_ypkah7nC';

// Inizializzazione del client globale
const supabaseClient = window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY);