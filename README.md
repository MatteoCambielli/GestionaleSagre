# Sagra Cloud

Gestionale React/Vite per sagre: ordinazioni, monitor cucina e bar, cassa, storico e configurazione listino, con sincronizzazione Supabase Realtime.

## Avvio

```bash
npm install
npm run dev
```

Senza variabili d'ambiente l'app usa una demo persistente nel browser (`sagra-demo`, PIN `12345`).

## Supabase

Per un progetto Supabase vuoto:

1. Abilita `Anonymous Sign-Ins` in **Authentication > Providers**.
2. Esegui [production_schema.sql](supabase/production_schema.sql) nel SQL Editor.
3. Disabilita **Allow public access** in **Realtime > Settings**: l'app usa canali Broadcast privati.
4. Configura CAPTCHA e i rate limit Auth prima della messa in produzione.
5. Copia `.env.example` in `.env.local` e inserisci Project URL e publishable key.
6. Riavvia Vite.

Ogni sagra è isolata tramite `festival_id`, membership e policy RLS. I PIN sono hash bcrypt e non sono leggibili dalla Data API. Gli ordini vengono creati tramite RPC atomica con prezzi riletti dal listino; storico e statistiche sono paginati/aggregati sul server.
