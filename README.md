# Ordiva

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
5. In **Authentication > Security** abilita la protezione password compromesse.
6. Copia `.env.example` in `.env.local` e inserisci Project URL e publishable key.
7. Riavvia Vite.

Ogni sagra è isolata tramite `festival_id`, membership e policy RLS. I PIN sono hash bcrypt e non sono leggibili dalla Data API. Gli ordini vengono creati tramite RPC atomica con prezzi riletti dal listino; storico e statistiche sono paginati/aggregati sul server.

## Manager

L’area privata è disponibile solo all’indirizzo `/manager`. Non è collegata nel gestionale cliente e richiede sia le credenziali Supabase Auth sia il ruolo `admin` verificato dalle RPC private.

Al primo accesso usa **Password dimenticata?** con l’email amministratore per impostare la password personale. Il recupero clienti usa invece l’email proprietario verificata solo per inviare un magic link; l’accesso operativo resta esclusivamente codice attività + PIN.

Le migrazioni in `supabase/migrations` sono già applicate al progetto configurato e costituiscono lo storico completo per riprodurre schema, RLS, licenze, limiti e hardening.

## Deploy su Vercel

1. Aggiungi le environment variables nelle impostazioni del progetto Vercel.
2. Non caricare `.env.local` o altri file `.env` nel repository.
3. Il routing SPA è gestito da `vercel.json`, che fa fallback a `index.html` per route come `/manager`, `/success` e `/cancel`.
4. Dopo il deploy usa `/manager` per accedere all'area manager privata.

Environment variables richieste:

- `VITE_SUPABASE_URL`
- `VITE_SUPABASE_ANON_KEY`
- `VITE_SUPABASE_PUBLISHABLE_KEY`, opzionale e mantenuta per compatibilità con installazioni esistenti
- `VITE_STRIPE_PUBLISHABLE_KEY`, solo se Stripe è usato nel frontend
- `STRIPE_SECRET_KEY`, solo per funzioni/backend Stripe lato server e mai nel frontend

In Supabase Auth aggiungi tra gli URL consentiti anche il dominio Vercel dell'app, ad esempio:

- `https://tuo-dominio.vercel.app`
- `https://tuo-dominio.vercel.app/manager`
