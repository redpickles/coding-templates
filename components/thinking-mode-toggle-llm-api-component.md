# Thinking-Mode Toggle — Reusable LLM-API Component Spec

A portable spec for a "thinking mode" toggle in any app that talks to an
OpenAI-compatible LLM server (local or remote). Implements the feature in
five independent pieces. Copy the ideas; adapt the syntax to your stack.

## What the feature is

One button (icon: lightbulb) next to every send control. Clicking it flips an
app-wide, remembered-across-launches boolean. That boolean rides on every chat
request to the server, which turns it into "reasoning knobs" in the upstream
request; reasoning that the server streams back shows up as a "Thinking..."
indicator in the UI until real answer text arrives.

```
UI button ──click──> app state (thinkMode) ──saved──> localStorage
                          │
                          ▼ on every send
              request body { thinking: boolean }
                          │
                          ▼ proxy/server
              upstream knobs (3 spellings) + rejection cascade
                          │
                          ▼ SSE stream back
              reasoning deltas ──> marker byte ──> "Thinking..." bubble
```

## The five pieces

### 1. Config: default + persistence (one module)

- One constant `THINKING_DEFAULT = true`. **Default ON**: asking a reasoning
  model to think is what makes it think, and a server that cannot be told to
  just ignores or bounces the knob (the cascade in piece 4 absorbs the bounce).
  Reasoning is the expensive, surprising behavior — turning it on is what the
  user opted into by shipping this feature.
- Persist under a namespaced storage key (`"appname.thinking"`), alongside all
  other user config in the same place.
- Booleans are stored as the **strings `"1"`/`"0"`**. Load rule: an *absent* key
  means the default; anything but `"0"` counts as on.

```ts
const THINKING_DEFAULT = true;
loadThinking()  // absent key -> THINKING_DEFAULT; otherwise raw !== "0"
saveThinking(b) // setItem(key, b ? "1" : "0")
```

### 2. App state: one global boolean, not per-chat

- Hold `thinkMode` in the top-level component state, seeded from
  `loadThinking()` on mount; persist with a change-watcher
  (`useEffect` keyed on it calling `saveThinking`). Same pattern as every
  other setting.
- **App-wide, not per-conversation**: every composer's bulb reads/writes the
  same state, so one click flips the whole app and all bulbs always agree.
- Render the *current* value into each request at send time — a mid-stream
  click does not change a reply already in flight.
- Never disable the button, even mid-stream.

### 3. UI button: one static icon, two states in pure CSS

- `<button>` just before each send button. One shared icon markup (a lightbulb
  on a 24×24 viewBox: round globe + base lines + rays). Click
  `thinkMode = !thinkMode` at the app level, not per button.
- State classes: `think-btn` (off) and `think-btn on` (on). All visual
  difference is CSS: off = muted outline bulb, rays hidden; on = accent ink,
  rays drawn. Keep the rays in the DOM always and hide them with
  `display: none` on the SVG child, so a click never re-renders the icon.
- Accessibility: `aria-label="Toggle thinking mode"` (static) plus a dynamic
  `title` that states current state backwards ("Thinking is on — click to
  turn it off"), because the icon alone cannot tell the user which way a
  click goes.
- A `--lit`/accent token shared with other lit toggles makes them read as one
  family.

### 4. Wire protocol: send the flag, add knobs, cascade on rejection

Client sends `thinking: <boolean>` in the request body to your proxy
route — **always both directions**: `false` explicitly asks the server *not*
to think (some servers think by default; absent means "no opinion, keep the
request plain" and is what other callers send).

```json
{ "messages": [...], "model": "...", "baseUrl": "...", "thinking": true }
```

The proxy (server-side fetch to the configured base URL — server-side so
there is no browser CORS problem and SSE parses cleanly) adds **all three
knob spellings together** to the upstream chat-completions body, because
servers disagree on which they accept:

```json
{
  // ...model, messages, stream: true...
  "think": true,                                    // Ollama
  "reasoning_effort": "high",                       // llama-server/Unsloth, Ollama shim ("none" when off)
  "chat_template_kwargs": { "enable_thinking": true } // vLLM/Qwen-style
}
```

Strict servers 400-reject knobs they don't know. Handle it with a
**replay cascade**: first request carries the knobs; if it bounces, replay the
*same* request with fewer knobs — first drop the newer feature's knobs, then
the thinking knobs, then plain. Record which knob combo actually reached the
server, so you know what to feed the evidence detector below.

- Remember rejections in an in-memory `Set` keyed by `"<baseUrl> <model>"`
  (a server that refuses the knobs for one model may accept them for another).
  Next message for that pair starts at the last-known-good shape — one
  round trip per message again, no repeated bouncing.
- A 200 response that *ignored* the knobs is fine: servers that reason anyway
  stream reasoning deltas, and the indicator in piece 5 shows them. A server
  that cannot reason just answers normally. Toggling is always a no-error,
  no-404-path user action.
- Only a request with no knobs left to drop that still bounced is a real
  error; show the **first** rejection's text to the user (it usually names the
  offending parameter; a knobless replay's failure text is less useful).

### 5. Reasoning back: marker byte + waiting-bubble indicator

The proxy parses the upstream SSE stream and yields to the client, per delta:

- `delta.reasoning` (Ollama) or `delta.reasoning_content` (DeepSeek/OpenRouter)
  — reasoning text, which is **not shown to the user**. Instead of forwarding
  it, yield a single control character the model can never emit:
  `"\u0000"` (the thinking marker). Reserve a second control char (`\u0001`) if
  you add sibling side-channel signals (this app's is a web-search stamp).
- `delta.content` — normal visible text, forwarded as-is.

Client streaming loop: accumulate into one buffer; the assistant reply bubble
renders `buffer.replaceAll(marker, "")` (markers never reach content or
storage), and set `thinking = buffer still contains marker AND visible text is
still empty`. That boolean is what makes the waiting bubble show
`Thinking...`. Clear it the moment any text arrives or the stream ends.

Indicator rendering (message component):

- Only while `waiting && role === assistant && content === ""`, and only on
  the last bubble of the chat that is currently streaming.
- `waiting` (no marker seen) shows animated dots (`...`); `thinking` shows a
  muted monospace `Thinking...` span with a 1.8s ease-in-out opacity pulse
  (0.2→1→0.2). Respect `prefers-reduced-motion` (kill animation, opacity 1).

```css
.msg.assistant .bubble .thinking {
  color: var(--muted);
  font-family: ui-monospace, monospace;
  animation: thinking 1.8s ease-in-out infinite;
}
@keyframes thinking { 0%, 100% { opacity: 0.2; } 50% { opacity: 1; } }
```

## Suggested file layout

| Piece | Where it lives in this app | Generic home |
|---|---|---|
| 1 config | `lib/llm.ts` | shared settings/config module |
| 2 state | `components/Chat.tsx` | main app component |
| 3 button | `components/Chat.tsx` + `app/globals.css` | composer UI + stylesheet |
| 4 knobs/cascade | `app/api/chat/route.ts` | chat proxy route |
| 5 marker/indicator | `route.ts` + `components/Message.tsx` | proxy + message renderer |

## Non-obvious decisions (why, so you don't re-litigate)

- **Default on**, unlike opt-in expensive features (web search defaults off —
  fetching the live web is a side effect every message would pay; asking for
  reasoning is just "the model's own specialty", and the cascade makes a
  non-thinking-capable server harmless).
- **Boolean not tri-state** in UI state: an explicit off must beat a
  server's thinking-by-default, so the flag always rides the request once a
  send happens (tri-state "absent" is only used by callers that never touch
  the feature).
- **Rejection memory in RAM only** — re-probing after a restart costs one
  extra request, so persisting it would only save that at the cost of
  staleness. Keep it simple.
- **Marker bytes over stream part channels**: your proxy re-emits plain
  `text/plain`, so any control character the model cannot produce is a
  free side channel — no custom SSE format needed between proxy and client.
- **One bulb per composer, one shared state**: three separate composer
  windows (this app) still show one agreeable setting; per-window thinking
  mode confuses users.

## Checklist to implement in a new app

1. Add `THINKING_DEFAULT = true`, storage key, `load`/`save` (as "1"/"0").
2. Global `thinkMode` state, loaded on mount, saved on change.
3. Bulb button before each send button: `on`/off classes, static SVG with
   hidden rays, accent-when-on CSS, dynamic `title`, `aria-label`.
4. Put `thinking: thinkMode` in the request to your chat proxy.
5. Proxy: add the three knob spellings when `thinking !== undefined`;
   on 400, replay dropping knob kinds; remember rejections per
   (baseUrl, model); only knobless-bounce is a real error.
6. Proxy: forward reasoning deltas (`reasoning`/`reasoning_content`) as one
   `\u0000` byte; forward `content` as-is.
7. Client: strip markers from the visible buffer; while any marker is in a
   still-empty reply, show `Thinking...` in that bubble; stop the moment
   text arrives.
8. CSS: pulsing monospace indicator + reduced-motion fallback; lit bulb
   shares its accent with any other lit toggle you add later.
