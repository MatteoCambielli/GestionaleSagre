import "jsr:@supabase/functions-js/edge-runtime.d.ts"
import { createClient } from "npm:@supabase/supabase-js@2"

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
}

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status,
  headers: { ...corsHeaders, "Content-Type": "application/json" },
})

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders })
  if (request.method !== "POST") return json({ error: "Metodo non consentito" }, 405)

  try {
    const authHeader = request.headers.get("Authorization") ?? ""
    const token = authHeader.replace(/^Bearer\s+/i, "")
    if (!token) return json({ error: "Autenticazione richiesta" }, 401)

    const adminClient = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
      { auth: { autoRefreshToken: false, persistSession: false } },
    )
    const { data: authData, error: authError } = await adminClient.auth.getUser(token)
    if (authError || !authData.user) return json({ error: "Sessione non valida" }, 401)

    const { data: profile } = await adminClient
      .from("profiles")
      .select("role")
      .eq("auth_user_id", authData.user.id)
      .maybeSingle()
    if (profile?.role !== "admin") return json({ error: "Accesso amministratore richiesto" }, 403)

    const body = await request.json()
    const action = String(body.action ?? "create")

    if (action === "link_recovery") {
      const email = String(body.email ?? "").trim().toLowerCase()
      const eventId = String(body.event_id ?? "")
      if (!email || !eventId) return json({ error: "Email o evento non validi" }, 400)
      const { data: linkData, error: linkError } = await adminClient.auth.admin.generateLink({
        type: "magiclink",
        email,
        options: { data: { recovery_only: true } },
      })
      if (linkError || !linkData.user) throw linkError ?? new Error("Associazione email non riuscita")
      const { error: profileError } = await adminClient.from("profiles").upsert({
        auth_user_id: linkData.user.id,
        role: "cliente",
        name: String(body.name ?? "").trim(),
        email,
        updated_at: new Date().toISOString(),
      }, { onConflict: "auth_user_id" })
      if (profileError) throw profileError
      const { error: memberError } = await adminClient.from("festival_members").upsert({
        festival_id: eventId,
        user_id: linkData.user.id,
        role: "owner",
        event_role: "owner",
        username: email,
        stats_access_until: "infinity",
      }, { onConflict: "festival_id,user_id" })
      if (memberError) throw memberError
      return json({ ok: true, email, auth_user_id: linkData.user.id })
    }

    const password = String(body.password ?? "")
    if (password.length < 8) return json({ error: "La password deve avere almeno 8 caratteri" }, 400)

    if (action === "reset") {
      if (!body.auth_user_id) return json({ error: "Utente mancante" }, 400)
      const { error } = await adminClient.auth.admin.updateUserById(body.auth_user_id, {
        password,
        user_metadata: { must_change_password: true },
      })
      if (error) throw error
      return json({ ok: true })
    }

    const email = String(body.email ?? "").trim().toLowerCase()
    const eventId = String(body.event_id ?? "")
    const eventRole = String(body.role ?? "staff")
    const allowedRoles = new Set(["owner", "cassiere", "cucina", "bar", "staff"])
    if (!email || !eventId || !allowedRoles.has(eventRole)) {
      return json({ error: "Email, evento o ruolo non validi" }, 400)
    }

    const { data: created, error: createError } = await adminClient.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
      user_metadata: { must_change_password: true, event_role: eventRole },
    })
    if (createError || !created.user) throw createError ?? new Error("Creazione utente non riuscita")

    try {
      const { error: profileError } = await adminClient.from("profiles").upsert({
        auth_user_id: created.user.id,
        role: eventRole === "owner" ? "cliente" : "operatore",
        name: String(body.name ?? "").trim(),
        email,
        updated_at: new Date().toISOString(),
      }, { onConflict: "auth_user_id" })
      if (profileError) throw profileError

      const { error: memberError } = await adminClient.from("festival_members").upsert({
        festival_id: eventId,
        user_id: created.user.id,
        role: eventRole === "owner" ? "owner" : "operator",
        event_role: eventRole,
        username: email,
        stats_access_until: eventRole === "owner" ? "infinity" : null,
      }, { onConflict: "festival_id,user_id" })
      if (memberError) throw memberError
    } catch (error) {
      await adminClient.auth.admin.deleteUser(created.user.id)
      throw error
    }

    return json({ ok: true, auth_user_id: created.user.id, email, role: eventRole })
  } catch (error) {
    console.error(error)
    return json({ error: error instanceof Error ? error.message : "Operazione non riuscita" }, 400)
  }
})
