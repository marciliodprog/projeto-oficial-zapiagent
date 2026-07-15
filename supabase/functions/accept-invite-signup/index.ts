// Edge Function: accept-invite-signup
// Cria/recupera o usuário e aceita o convite em uma única chamada server-side.
import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
  const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  let payload: { token?: string; full_name?: string; password?: string };
  try {
    payload = await req.json();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }

  const token = (payload.token || "").trim();
  const fullName = (payload.full_name || "").trim();
  const password = payload.password || "";

  if (!token) return json({ error: "missing_token" }, 400);
  if (!fullName) return json({ error: "missing_name" }, 400);
  if (password.length < 6) return json({ error: "weak_password" }, 400);

  // 1) Validar convite
  const { data: inv, error: invErr } = await admin
    .from("team_invitations")
    .select("id, email, role, status, expires_at, organization_id")
    .eq("token", token)
    .maybeSingle();

  if (invErr) {
    console.error("[accept-invite-signup] invitation lookup error", invErr);
    return json({ error: "invitation_lookup_failed" }, 500);
  }
  if (!inv) return json({ error: "invitation_invalid" }, 404);
  if (inv.status !== "pending") return json({ error: "invitation_already_used" }, 409);
  if (new Date(inv.expires_at).getTime() < Date.now()) {
    return json({ error: "invitation_expired" }, 410);
  }

  const email = inv.email.toLowerCase();

  // 2) Pegar/Criar usuário Auth (admin API — sem envio de e-mail)
  let userId: string | null = null;

  // Tenta encontrar por e-mail (paginando — admin API não tem getUserByEmail)
  try {
    let page = 1;
    while (page <= 20 && !userId) {
      const { data, error } = await admin.auth.admin.listUsers({ page, perPage: 200 });
      if (error) throw error;
      const found = data.users.find((u) => (u.email || "").toLowerCase() === email);
      if (found) {
        userId = found.id;
        break;
      }
      if (data.users.length < 200) break;
      page++;
    }
  } catch (e) {
    console.error("[accept-invite-signup] listUsers failed", e);
  }

  if (!userId) {
    const { data: created, error: createErr } = await admin.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
      user_metadata: { full_name: fullName },
    });
    if (createErr || !created.user) {
      console.error("[accept-invite-signup] createUser failed", createErr);
      const msg = (createErr?.message || "").toLowerCase();
      if (msg.includes("already") || msg.includes("registered")) {
        return json({ error: "email_already_exists" }, 409);
      }
      if (msg.includes("password")) return json({ error: "weak_password" }, 400);
      return json({ error: "create_user_failed", detail: createErr?.message }, 500);
    }
    userId = created.user.id;
  } else {
    // Usuário já existia: atualiza senha + nome (idempotente em retries)
    const { error: updErr } = await admin.auth.admin.updateUserById(userId, {
      password,
      user_metadata: { full_name: fullName },
    });
    if (updErr) {
      console.warn("[accept-invite-signup] updateUserById warning", updErr);
    }
  }

  // 3) Remove papel "seller" semeado pelo trigger se o convite for de outro papel
  if (inv.role !== "seller") {
    const { error: delErr } = await admin
      .from("user_roles")
      .delete()
      .eq("user_id", userId)
      .eq("role", "seller");
    if (delErr) console.warn("[accept-invite-signup] cleanup seller role failed", delErr);
  }

  // 4) Aceita o convite (idempotente — se já foi aceito antes, ainda retorna sucesso)
  const { data: rpcResult, error: rpcErr } = await admin.rpc("accept_invitation", {
    invitation_token: token,
    user_id: userId,
  });

  if (rpcErr) {
    console.error("[accept-invite-signup] accept_invitation rpc error", rpcErr);
    return json({ error: "accept_failed", detail: rpcErr.message }, 500);
  }

  // Se rpcResult=false, o convite já tinha sido aceito anteriormente — também ok.
  return json({ ok: true, email, user_id: userId, applied: rpcResult === true });
});
