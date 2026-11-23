// Supabase-native Edge Function entry point for private Breezze audio.
// The portable handler is shared with the Cloudflare fallback so HMAC,
// territory-gated playback, Range and no-store behavior stay identical.
import mediaWorker from "../../../infra/cloudflare/media-worker/src/index.ts";

const keysRaw = Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}";
let supabaseSecretKey = "";
try {
  const keys = JSON.parse(keysRaw) as Record<string, unknown>;
  if (typeof keys.default === "string") {
    supabaseSecretKey = keys.default;
  }
} catch {
  // No credentials means the media endpoint fails closed with HTTP 503.
}

const env = {
  SUPABASE_URL: Deno.env.get("SUPABASE_URL") ?? "",
  SUPABASE_SECRET_KEY: supabaseSecretKey,
  SUPABASE_MEDIA_BUCKET: "breezze-media",
  MEDIA_SIGNING_KEY: Deno.env.get("MEDIA_SIGNING_KEY") ?? "",
};

Deno.serve((request: Request) => {
  const url = new URL(request.url);
  const basePath = "/functions/v1/media";
  if (!url.pathname.startsWith(basePath + "/audio/")) {
    return new Response("NOT_FOUND", { status: 404 });
  }
  url.pathname = url.pathname.slice(basePath.length);
  return mediaWorker.fetch(new Request(url.toString(), request), env);
});
