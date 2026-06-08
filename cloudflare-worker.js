// ─────────────────────────────────────────────────────────────────────────
// DOMINO speech-to-text — Cloudflare Worker (Groq Whisper proxy)
//
// Purpose: keep your Groq API key OFF the public web page. The browser records
// audio and POSTs the raw clip here; this Worker forwards it to Groq's Whisper
// model and returns { text } as JSON.
//
// One-time deploy (Cloudflare dashboard, no local tooling needed):
//   1. https://dash.cloudflare.com  →  Workers & Pages  →  Create  →  Worker
//   2. Name it e.g.  domino-stt  →  Deploy (the default hello-world).
//   3. Click "Edit code", select-all, paste THIS file, then "Deploy".
//   4. Worker → Settings → "Variables and Secrets" → Add:
//          Type = Secret,  Name = GROQ_API_KEY,  Value = <your Groq key>
//      → Deploy again.
//   5. Copy the Worker URL (looks like https://domino-stt.<you>.workers.dev)
//      and send it to me — I'll drop it into the web app and push it live.
//
// Model note: whisper-large-v3 gives the best Hebrew accuracy; the faster,
// cheaper whisper-large-v3-turbo is selected per-request via ?model=turbo
// (default, and any unknown value, is v3). See MODELS below.
// ─────────────────────────────────────────────────────────────────────────

const GROQ_URL = 'https://api.groq.com/openai/v1/audio/transcriptions';
const MODELS = {
  turbo: 'whisper-large-v3-turbo',
  v3: 'whisper-large-v3',
};
const DEFAULT_MODEL = 'v3';   // key into MODELS, not a model name
const LANGUAGE = 'he';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type',
  'Access-Control-Max-Age': '86400',
};

function json(obj, status) {
  return new Response(JSON.stringify(obj), {
    status: status || 200,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });
}

// Map a browser MIME type to a filename extension Groq can recognise.
function extFor(type) {
  if (!type) return 'webm';
  if (type.includes('webm')) return 'webm';
  if (type.includes('mp4') || type.includes('aac') || type.includes('m4a')) return 'mp4';
  if (type.includes('ogg')) return 'ogg';
  if (type.includes('wav')) return 'wav';
  if (type.includes('mpeg') || type.includes('mp3')) return 'mp3';
  return 'webm';
}

export default {
  async fetch(request, env) {
    if (request.method === 'OPTIONS') return new Response(null, { headers: CORS });
    if (request.method !== 'POST') return json({ error: 'method not allowed' }, 405);
    if (!env.GROQ_API_KEY) return json({ error: 'server missing GROQ_API_KEY' }, 500);

    const type = request.headers.get('Content-Type') || 'audio/webm';
    const buf = await request.arrayBuffer();
    if (!buf || buf.byteLength === 0) return json({ error: 'empty audio' }, 400);

    const modelKey = new URL(request.url).searchParams.get('model');
    const model = MODELS[modelKey] || MODELS[DEFAULT_MODEL];

    const form = new FormData();
    form.append('file', new Blob([buf], { type }), 'audio.' + extFor(type));
    form.append('model', model);
    form.append('language', LANGUAGE);
    form.append('response_format', 'json');
    form.append('temperature', '0');

    let r;
    try {
      r = await fetch(GROQ_URL, {
        method: 'POST',
        headers: { Authorization: 'Bearer ' + env.GROQ_API_KEY },
        body: form,
      });
    } catch (_) {
      return json({ error: 'upstream fetch failed' }, 502);
    }

    if (!r.ok) {
      const detail = await r.text();
      return json({ error: 'groq error', status: r.status, detail: detail.slice(0, 500) }, 502);
    }

    const data = await r.json();
    return json({ text: data.text || '' }, 200);
  },
};
