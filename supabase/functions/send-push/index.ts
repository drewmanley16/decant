// send-push: delivers one notification to the recipient's iPhones via APNs.
//
// Called by the notifications_push database trigger with { id }. It claims the
// notification (pushed_at) so each one is sent at most once, and ignores
// anything more than a few minutes old, so it needs no caller authentication.
//
// Secrets: APNS_KEY_ID, APNS_PRIVATE_KEY (contents of the .p8 file),
// optional APNS_TEAM_ID (default X9H68STU8F), APNS_TOPIC (default com.drewmanley.decant).
import { createClient } from "jsr:@supabase/supabase-js@2";
import { json } from "../_shared/http.ts";

const TEAM_ID = Deno.env.get("APNS_TEAM_ID") ?? "X9H68STU8F";
const TOPIC = Deno.env.get("APNS_TOPIC") ?? "com.drewmanley.decant";
const MAX_AGE_MS = 5 * 60_000;

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

// --- APNs auth token (ES256 JWT, reused for up to 50 minutes) ---------------
let cachedJWT: { token: string; at: number } | null = null;

function base64url(bytes: Uint8Array | string): string {
  const raw = typeof bytes === "string" ? new TextEncoder().encode(bytes) : bytes;
  let s = "";
  for (const b of raw) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function apnsToken(): Promise<string> {
  if (cachedJWT && Date.now() - cachedJWT.at < 50 * 60_000) return cachedJWT.token;
  const keyId = Deno.env.get("APNS_KEY_ID");
  const pem = Deno.env.get("APNS_PRIVATE_KEY");
  if (!keyId || !pem) throw new Error("APNS_KEY_ID / APNS_PRIVATE_KEY not configured");
  const der = Uint8Array.from(
    atob(pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "")),
    (c) => c.charCodeAt(0),
  );
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const header = base64url(JSON.stringify({ alg: "ES256", kid: keyId }));
  const claims = base64url(JSON.stringify({ iss: TEAM_ID, iat: Math.floor(Date.now() / 1000) }));
  const signature = new Uint8Array(
    await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(`${header}.${claims}`)),
  );
  cachedJWT = { token: `${header}.${claims}.${base64url(signature)}`, at: Date.now() };
  return cachedJWT.token;
}

// --- Message text -----------------------------------------------------------
function message(kind: string, wine: string | null): string {
  const of = wine ? ` of ${wine}` : "";
  switch (kind) {
    case "follow": return "started following you";
    case "follow_request": return "wants to follow you";
    case "like": return `liked your tasting${of}`;
    case "comment": return `commented on your tasting${of}`;
    case "tag": return `tagged you in a tasting${of}`;
    case "invite_joined": return "joined Decant with your invite 🎉";
    case "mention": return wine ? `mentioned you in a comment on ${wine}` : "mentioned you in a comment";
    case "reply": return wine ? `replied to your comment on ${wine}` : "replied to your comment";
    case "reaction": return `reacted to your tasting${of} 🥂`;
    default: return "sent you a notification";
  }
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);
  let id: string | undefined;
  try {
    id = (await req.json()).id;
  } catch { /* fall through */ }
  if (!id || !/^[0-9a-f-]{36}$/i.test(id)) return json({ error: "id required" }, 400);

  // Claim it: only the first call for a fresh, unsent notification proceeds.
  const since = new Date(Date.now() - MAX_AGE_MS).toISOString();
  const { data: claimed } = await admin.from("notifications")
    .update({ pushed_at: new Date().toISOString() })
    .eq("id", id).is("pushed_at", null).gte("created_at", since)
    .select("id, recipient_id, actor_id, kind, entry_id")
    .maybeSingle();
  if (!claimed) return json({ skipped: true });

  const [{ data: tokens }, { data: actor }, { count: unread }] = await Promise.all([
    admin.from("device_tokens").select("token, sandbox").eq("user_id", claimed.recipient_id),
    admin.from("profiles").select("display_name, username").eq("id", claimed.actor_id).maybeSingle(),
    admin.from("notifications").select("id", { count: "exact", head: true })
      .eq("recipient_id", claimed.recipient_id).is("read_at", null),
  ]);
  if (!tokens?.length) return json({ sent: 0 });

  let wine: string | null = null;
  if (claimed.entry_id) {
    const { data: entry } = await admin.from("tasting_entries").select("vintage_id").eq("id", claimed.entry_id).maybeSingle();
    if (entry) {
      const { data: w } = await admin.from("wine_catalog").select("name").eq("id", entry.vintage_id).maybeSingle();
      wine = w?.name ?? null;
    }
  }

  const name = actor?.display_name || actor?.username || "Someone";
  const link = claimed.entry_id ? `decant://t/${claimed.entry_id}` : `decant://u/${claimed.actor_id}`;
  const payload = JSON.stringify({
    aps: {
      alert: { title: name, body: message(claimed.kind, wine) },
      sound: "default",
      badge: unread ?? 1,
      "thread-id": claimed.entry_id ?? claimed.kind,
    },
    link,
  });

  let jwt: string;
  try {
    jwt = await apnsToken();
  } catch (error) {
    console.error(error);
    return json({ error: "push not configured" }, 503);
  }

  let sent = 0;
  for (const { token, sandbox } of tokens) {
    const host = sandbox ? "https://api.sandbox.push.apple.com" : "https://api.push.apple.com";
    const res = await fetch(`${host}/3/device/${token}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${jwt}`,
        "apns-topic": TOPIC,
        "apns-push-type": "alert",
        "apns-priority": "10",
        "content-type": "application/json",
      },
      body: payload,
    });
    if (res.ok) {
      sent++;
      continue;
    }
    const reason = (await res.json().catch(() => ({}))).reason ?? res.status;
    console.error("APNs", res.status, reason);
    if (res.status === 410 || reason === "BadDeviceToken" || reason === "Unregistered") {
      await admin.from("device_tokens").delete().eq("token", token);
    }
  }
  return json({ sent });
});
