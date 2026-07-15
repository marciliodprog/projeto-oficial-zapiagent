// Helper to send Web Push notifications to one or more users.
// Used by webhooks/edges that want to notify sellers in real-time.

import webpush from "npm:web-push@3.6.7";

const VAPID_PUBLIC = Deno.env.get("VAPID_PUBLIC_KEY") || "";
const VAPID_PRIVATE = Deno.env.get("VAPID_PRIVATE_KEY") || "";
const VAPID_SUBJECT = Deno.env.get("VAPID_SUBJECT") || "mailto:noreply@vendus.com.br";

let vapidReady = false;
function ensureVapid() {
  if (vapidReady) return true;
  if (!VAPID_PUBLIC || !VAPID_PRIVATE) {
    console.warn("[push] VAPID keys missing — push disabled");
    return false;
  }
  webpush.setVapidDetails(VAPID_SUBJECT, VAPID_PUBLIC, VAPID_PRIVATE);
  vapidReady = true;
  return true;
}

export type PushPreferenceKey =
  | "push_new_message"
  | "push_queue_lead"
  | "push_assigned_lead"
  | "push_booking_reminder"
  | "push_sale_won"
  | "push_new_booking";


export interface PushPayload {
  title: string;
  body: string;
  url?: string;
  tag?: string;
  icon?: string;
  badge?: string;
  data?: Record<string, unknown>;
  requireInteraction?: boolean;
}

interface SupabaseLike {
  from: (t: string) => any;
  rpc?: (n: string, p?: any) => any;
}

/**
 * Send a push notification to all active subscriptions of the given users,
 * respecting their `push_enabled` and the granular preference key.
 * Fire-and-forget safe: errors are swallowed and logged.
 */
export async function sendPushToUsers(
  supabase: SupabaseLike,
  userIds: string[],
  payload: PushPayload,
  preferenceKey: PushPreferenceKey,
): Promise<{ sent: number; failed: number; skipped: number }> {
  const result = { sent: 0, failed: 0, skipped: 0 };
  if (!ensureVapid()) return result;
  const uniqueIds = [...new Set(userIds.filter(Boolean))];
  if (uniqueIds.length === 0) return result;

  try {
    // 1. Filter users by preference (push_enabled + specific key)
    const { data: prefs } = await supabase
      .from("user_notification_settings")
      .select(`user_id, push_enabled, ${preferenceKey}`)
      .in("user_id", uniqueIds);

    const allowedUsers = new Set<string>(uniqueIds);
    if (prefs && Array.isArray(prefs)) {
      for (const p of prefs) {
        if (p.push_enabled === false || p[preferenceKey] === false) {
          allowedUsers.delete(p.user_id);
        }
      }
    }
    if (allowedUsers.size === 0) {
      result.skipped = uniqueIds.length;
      return result;
    }

    // 2. Fetch active subscriptions
    const { data: subs } = await supabase
      .from("push_subscriptions")
      .select("id, endpoint, p256dh, auth, user_id")
      .in("user_id", [...allowedUsers])
      .is("revoked_at", null);

    if (!subs || subs.length === 0) return result;

    const body = JSON.stringify(payload);

    const tasks = subs.map(async (s: any) => {
      try {
        await webpush.sendNotification(
          {
            endpoint: s.endpoint,
            keys: { p256dh: s.p256dh, auth: s.auth },
          },
          body,
          { TTL: 60 * 60 * 24 },
        );
        result.sent++;
        // best-effort touch last_seen_at
        supabase
          .from("push_subscriptions")
          .update({ last_seen_at: new Date().toISOString() })
          .eq("id", s.id)
          .then?.(() => {});
      } catch (err: any) {
        result.failed++;
        const status = err?.statusCode || err?.status || 0;
        if (status === 404 || status === 410) {
          // Endpoint dead — revoke
          await supabase
            .from("push_subscriptions")
            .update({ revoked_at: new Date().toISOString() })
            .eq("id", s.id);
        } else {
          console.warn(`[push] send failed status=${status} user=${s.user_id}`, err?.message || err);
        }
      }
    });

    await Promise.allSettled(tasks);
    return result;
  } catch (err) {
    console.error("[push] sendPushToUsers exception:", err);
    return result;
  }
}
