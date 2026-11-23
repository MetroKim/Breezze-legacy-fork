import "jsr:@supabase/functions-js/edge-runtime.d.ts";

// Metadata-only prefetch. NEVER return a provider media URL or imply rights.
const apiOrigin = Deno.env.get("BREEZZE_API_URL")
  ?? "https://breezze-api-edge.ykw8vmq7ph.workers.dev";
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization,apikey,content-type,x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Cache-Control": "no-store",
};
function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status, headers: { ...cors, "Content-Type": "application/json" },
  });
}
const allowed = /^bz:(youtube_music|deezer|soundcloud):([A-Za-z0-9_-]{1,128})$/;

Deno.serve(async (request: Request) => {
  if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  if (request.method !== "POST") return json({ error: "METHOD_NOT_ALLOWED" }, 405);
  if (Number(request.headers.get("content-length") || "0") > 4096) {
    return json({ error: "PAYLOAD_TOO_LARGE" }, 413);
  }
  const authorization = request.headers.get("Authorization") ?? "";
  if (!authorization.startsWith("Bearer ") || authorization.length > 8192) {
    return json({ error: "UNAUTHENTICATED" }, 401);
  }
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const apiKey = Deno.env.get("SUPABASE_ANON_KEY");
  if (!supabaseUrl || !apiKey) return json({ error: "AUTH_UNAVAILABLE" }, 503);

  try {
    // Verify the user server-side even if the gateway's JWT setting changes.
    const auth = await fetch(supabaseUrl + "/auth/v1/user", {
      headers: { "Authorization": authorization, "apikey": apiKey },
      signal: AbortSignal.timeout(5000),
    });
    if (!auth.ok) return json({ error: "UNAUTHENTICATED" }, 401);
    const user = await auth.json();
    if (typeof user.id !== "string" || user.is_anonymous === true) {
      return json({ error: "UNAUTHENTICATED" }, 401);
    }
  } catch (_) {
    return json({ error: "AUTH_UNAVAILABLE" }, 503);
  }

  let body: unknown;
  try { body = await request.json(); }
  catch (_) { return json({ error: "INVALID_JSON" }, 400); }

  const payload = body as Record<string, unknown> | null;
  const ids = payload?.trackIds;
  if (!Array.isArray(ids) || ids.length < 1 || ids.length > 3
      || ids.some((id) => typeof id !== "string" || !allowed.test(id))
      || new Set(ids).size !== ids.length) {
    return json({ error: "INVALID_TRACK_IDS", maximum: 3 }, 400);
  }

  // The existing edge/cache layer owns any metadata caching. We only warm it.
  // This never calls /playback/resolve or fetches audio bytes.
  const results = await Promise.all((ids as string[]).map(async (id) => {
    const match = allowed.exec(id)!;
    const endpoint = new URL(
      "/api/v1/providers/" + encodeURIComponent(match[1])
      + "/tracks/" + encodeURIComponent(match[2]), apiOrigin,
    );
    try {
      const upstream = await fetch(endpoint, {
        headers: { "Accept": "application/json" },
        signal: AbortSignal.timeout(4500),
      });
      return { trackId: id, cached: upstream.ok };
    } catch (_) {
      return { trackId: id, cached: false };
    }
  }));
  return json({ kind: "metadata_prefetch", results });
});
