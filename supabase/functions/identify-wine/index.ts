// identify-wine: label photo + OCR text -> structured label extraction,
// catalog candidates and clearly-labelled AI tasting suggestions.
//
// Secrets (supabase secrets set ...): OPENAI_API_KEY, optional OPENAI_MODEL.
// The provider key never leaves this function.
import { createClient } from "jsr:@supabase/supabase-js@2";
import { corsHeaders, json } from "../_shared/http.ts";

const MODEL = Deno.env.get("OPENAI_MODEL") ?? "gpt-4.1-mini";
const MAX_SCANS_PER_HOUR = 60;
const WINE_TYPES = ["red", "white", "rose", "sparkling", "dessert", "fortified", "orange"];

const nullable = (type: string) => ({ type: [type, "null"] });
const unit = { type: ["number", "null"], minimum: 0, maximum: 1 };

// Strict JSON schema: the model must return exactly this shape.
const responseSchema = {
  type: "object",
  additionalProperties: false,
  required: ["label", "identity_confidence", "suggestion"],
  properties: {
    label: {
      type: "object",
      additionalProperties: false,
      required: ["producer", "wine_name", "vintage", "type", "grapes", "country", "region", "appellation", "abv", "volume_ml"],
      properties: {
        producer: nullable("string"),
        wine_name: nullable("string"),
        vintage: nullable("integer"),
        type: { type: ["string", "null"], enum: [...WINE_TYPES, null] },
        grapes: { type: "array", items: { type: "string" } },
        country: nullable("string"),
        region: nullable("string"),
        appellation: nullable("string"),
        abv: nullable("number"),
        volume_ml: nullable("integer"),
      },
    },
    identity_confidence: { type: "number", minimum: 0, maximum: 1 },
    suggestion: {
      type: "object",
      additionalProperties: false,
      required: ["characteristics", "pairings", "summary"],
      properties: {
        characteristics: {
          type: "object",
          additionalProperties: false,
          required: ["sweetness", "acidity", "body", "tannin", "fruitiness", "flavors", "serve_min_c", "serve_max_c", "decant_minutes", "aging_years"],
          properties: {
            sweetness: unit, acidity: unit, body: unit, tannin: unit, fruitiness: unit,
            flavors: { type: "array", items: { type: "string" } },
            serve_min_c: nullable("integer"),
            serve_max_c: nullable("integer"),
            decant_minutes: nullable("integer"),
            aging_years: nullable("integer"),
          },
        },
        pairings: { type: "array", items: { type: "string" } },
        summary: nullable("string"),
      },
    },
  },
};

const systemPrompt = `You read wine bottle labels.
Rules:
- In "label", report ONLY information visibly printed on the label or present in the OCR text. If a field is not legible or not present, use null. Never guess the vintage, ABV or volume.
- "type" may be inferred only when the label or a named grape makes it unambiguous; otherwise null.
- "identity_confidence" (0-1) is how sure you are that producer and wine name are read correctly.
- "suggestion" holds typical-style tasting guidance for this kind of wine. It will be shown to users as an AI suggestion, not a fact. Use null for any value you are unsure about. Keep flavors and pairings to at most 5 short items each, and summary to one sentence.`;

async function sha256(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function readLabel(imageBase64: string, ocrLines: string[]) {
  const apiKey = Deno.env.get("OPENAI_API_KEY");
  if (!apiKey) throw new Error("OPENAI_API_KEY is not configured");

  const res = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: { "Authorization": `Bearer ${apiKey}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      model: MODEL,
      temperature: 0,
      response_format: { type: "json_schema", json_schema: { name: "wine_label", strict: true, schema: responseSchema } },
      messages: [
        { role: "system", content: systemPrompt },
        {
          role: "user",
          content: [
            { type: "text", text: `On-device OCR text (may contain errors):\n${ocrLines.join("\n").slice(0, 2000)}` },
            { type: "image_url", image_url: { url: `data:image/jpeg;base64,${imageBase64}`, detail: "high" } },
          ],
        },
      ],
    }),
  });
  if (!res.ok) throw new Error(`Vision provider error ${res.status}: ${(await res.text()).slice(0, 300)}`);
  const body = await res.json();
  return JSON.parse(body.choices[0].message.content);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  const authHeader = req.headers.get("Authorization") ?? "";
  const url = Deno.env.get("SUPABASE_URL")!;
  const userClient = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: authHeader } },
  });
  const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  const { data: { user } } = await userClient.auth.getUser();
  if (!user) return json({ error: "unauthorized" }, 401);

  let payload: { image_base64?: string; ocr_text?: string[]; text_key?: string };
  try {
    payload = await req.json();
  } catch {
    return json({ error: "invalid JSON" }, 400);
  }
  const ocr = (payload.ocr_text ?? []).filter((l) => typeof l === "string").slice(0, 80);
  const textKey = (payload.text_key ?? ocr.join(" ")).toLowerCase().trim();
  if (!payload.image_base64 && ocr.length === 0) return json({ error: "image or text required" }, 400);
  if ((payload.image_base64?.length ?? 0) > 4_000_000) return json({ error: "image too large" }, 413);

  // Basic abuse guard: cap AI-backed scans per user per hour.
  const since = new Date(Date.now() - 3600_000).toISOString();
  const { count } = await admin.from("scan_history").select("id", { count: "exact", head: true })
    .eq("user_id", user.id).gte("created_at", since);
  if ((count ?? 0) >= MAX_SCANS_PER_HOUR) return json({ error: "scan limit reached, try again later" }, 429);

  const textHash = await sha256(textKey || payload.image_base64!.slice(0, 10_000));
  let cached = textKey
    ? (await admin.from("label_cache").select("*").eq("text_hash", textHash).maybeSingle()).data
    : null;

  if (!cached) {
    try {
      const result = await readLabel(payload.image_base64 ?? "", ocr);
      cached = {
        text_hash: textHash,
        extraction: result.label,
        suggestion: result.suggestion,
        identity_confidence: result.identity_confidence,
        model: MODEL,
      };
      await admin.from("label_cache").upsert(cached);
    } catch (error) {
      console.error(error);
      return json({ error: "label reading unavailable" }, 502);
    }
  }

  const label = cached.extraction;
  const { data: matches, error: matchError } = await userClient.rpc("match_wines", {
    producer: label.producer,
    wine_name: label.wine_name ?? label.producer,
    vintage: label.vintage,
    lim: 5,
  });
  if (matchError) console.error(matchError);

  return json({
    text_hash: textHash,
    extraction: label,
    identity_confidence: cached.identity_confidence,
    suggestion: cached.suggestion,
    candidates: (matches ?? []).map((m: { vintage_id: string; score: number }) => ({
      vintage_id: m.vintage_id,
      // Discount catalog similarity by how well the label itself was read.
      score: Math.min(1, m.score * (0.6 + 0.4 * cached.identity_confidence)),
    })),
  });
});
