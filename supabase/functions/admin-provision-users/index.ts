import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders });

  try {
    const { organization_id, password, emails } = await req.json();
    if (!organization_id || !password || !Array.isArray(emails)) {
      return new Response(JSON.stringify({ error: "missing params" }), { status: 400, headers: corsHeaders });
    }

    const admin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
      { auth: { autoRefreshToken: false, persistSession: false } }
    );

    const results: any[] = [];

    for (const email of emails as string[]) {
      try {
        // find pending invite
        const { data: invite } = await admin
          .from("team_invitations")
          .select("*")
          .eq("email", email.toLowerCase())
          .eq("organization_id", organization_id)
          .eq("status", "pending")
          .maybeSingle();

        if (!invite) {
          results.push({ email, status: "no_invite" });
          continue;
        }

        // create user (or find existing)
        let userId: string | null = null;
        const { data: created, error: createErr } = await admin.auth.admin.createUser({
          email,
          password,
          email_confirm: true,
          user_metadata: { full_name: email.split("@")[0] },
        });

        if (createErr) {
          // maybe already exists -> look up
          const { data: list } = await admin.auth.admin.listUsers({ page: 1, perPage: 1000 });
          const existing = list?.users?.find((u) => u.email?.toLowerCase() === email.toLowerCase());
          if (existing) {
            userId = existing.id;
            await admin.auth.admin.updateUserById(existing.id, { password, email_confirm: true });
          } else {
            results.push({ email, status: "error", error: createErr.message });
            continue;
          }
        } else {
          userId = created.user!.id;
        }

        // upsert profile + garante organization_id mesmo se já existir
        await admin.from("profiles").upsert({
          id: userId!,
          full_name: email.split("@")[0],
          email,
          organization_id,
        });
        await admin
          .from("profiles")
          .update({ organization_id })
          .eq("id", userId!);

        // role
        await admin.from("user_roles").upsert({ user_id: userId!, role: invite.role });

        // squad
        if (invite.squad_id) {
          await admin
            .from("squad_members")
            .upsert({ squad_id: invite.squad_id, user_id: userId! }, { onConflict: "squad_id,user_id" });
        }

        // mark invite accepted
        await admin
          .from("team_invitations")
          .update({ status: "accepted" })
          .eq("id", invite.id);

        results.push({ email, status: "ok", user_id: userId });
      } catch (e: any) {
        results.push({ email, status: "error", error: e.message });
      }
    }

    return new Response(JSON.stringify({ results }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (e: any) {
    return new Response(JSON.stringify({ error: e.message }), { status: 500, headers: corsHeaders });
  }
});
