# Web Search for Chat Apps on OpenAI-Compatible LLM Servers

A self-contained spec of the "let the model search the live web" feature, extracted from this
app so it can be reimplemented in any future chat app that talks to a local/localhost
OpenAI-compatible server (Ollama, llama-server, Unsloth Studio, vLLM, …). Read this top to
bottom; every section ends with the rule you must keep.

## The one-paragraph model

The app never fetches web pages itself. Some OpenAI-compatible servers run **server-side tools**
(the server scrapes the web and injects the results into the model's context). The app only puts
the right fields on the upstream `POST /v1/chat/completions` request, prepends a system note
telling the model the tools exist, streams the response through its own proxy, and detects —
after the fact — whether a search actually ran, because these servers give the answer no
flag of their own.

## Architecture (three layers, always in this order)

1. **Client** (browser UI): a user-facing toggle (here: a globe button) holding a global
   boolean `webSearch`, plus an optional per-request `forceSearch` flag. Sends the boolean to…
2. **Server proxy route** (`/api/chat` here): must be server-side (avoids CORS, parses the
   upstream SSE). Adds search fields to the upstream request, retries with fewer fields when the
   server 400s, and re-encodes the reply into a plain text stream with marker bytes.
3. **Client stream reader**: strips marker bytes, stamps the assistant message, shows a chip.

The browser never sees the upstream SSE; the proxy converts it to a plain-text delta stream.
That shared stream is the channel between proxy and client, and control-character bytes in it
are the protocol for out-of-band signals.

## Layer 1 — the toggle

- Default **OFF**. Searching fetches the live web per message; it is an opt-in, not something
  every turn pays.
- Persist it across launches (here: `localStorage`, stored as `"1"`/`"0"`, absent key = default).
- Keep it **global** (all composers/windows in the app share one value).
- Send it upstream as `webSearch: boolean` in the client→proxy JSON. Only `true` means
  anything; `false`/absent keep the request shape plain. (Different convention than the
  thinking knob, where explicit `false` matters — don't confuse them.)
- **`forceSearch`** is the second entry point: some requests must search for exactly one turn
  without touching the global toggle (here: the right-click "Check the web for current info"
  dive and a pending "compare" dive). The proxy receives `webSearch: forceSearch || webSearch`.
  The global state and the user's next turn stay as they were.

Rule: global persisted boolean + per-request override flag. Nothing else.

## Layer 2 — the upstream request

When the effective value is true (and this `(baseUrl, model)` pair has not been seen to reject
search — see below), the proxy changes exactly two things in the upstream call:

### A. Extra body fields

```jsonc
// alongside the usual { model, messages, stream: true }
"enable_tools": true,
"enabled_tools": ["web_search"],
"permission_mode": "off",              // REQUIRED — see pitfall 1
"stream_options": { "include_usage": true }  // REQUIRED — see pitfall 2 / evidence B
```

- This is the wire shape proven to actually run a search on llama-server-family hosts
  (Unsloth Studio), the same switch Studio's own Chat tab enables.
- Do **not** use the older spelling `tools: [{type: "web_search"}]` — Studio silently ignores
  it (HTTP 200, no search; the answer misleadingly comes from model memory).

### B. A prepended system note (only on searched requests)

Without it, models keep insisting they cannot browse the live internet even when the tools are
offered. This is required, not decorative:

```
LIVE WEB SEARCH IS ENABLED for this conversation. Real search tools run on the server;
when you call one, you get fresh web results in your next turn. Rules:
- Never say you cannot search or browse - you can, via these tools. Today is <YYYY-MM-DD>;
  anything at or before that date is NOT the future, so "latest"/"as of"/recent months need
  a search, never a refusal.
- For recent/current things (events, prices, dates, rankings, "latest", "as of", "still true"),
  call the search tool and answer from its results, naming the source and its date.
- For timeless background, answer from your own knowledge without searching.
```

The date matters: "latest news" otherwise reads to a dated-cutoff model as future data. The
note rides only on requests that actually carry the search fields.

Rule: four extra fields + one dated system note. Nothing else on the wire.

## Layer 3 — graceful degradation

Strict OpenAI-compatible servers 400-reject any field they don't know. So:

- A memo `searchRejected: Set<string>` keyed `` `${baseUrl} ${model ?? ""}` `
  (keyed per model too: a server may refuse the knobs for one model but not another).
- Effective ask = `webSearch === true && !searchRejected.has(key)`.
- If the upstream call is not ok, **replay the identical request dropping one knob-kind at a
  time**, in order: (1) without the search fields + note, (2) without thinking knobs, (3) plain.
  The **first replay that succeeds** names what this pair cannot be given:
  if it succeeded without search → `searchRejected.add(key)`. Later messages pay one POST.
  A pair that fails everything is memoized as rejecting both kinds at once.
- Only an all-knobs-dropped bounce is a real error, and the **first** rejection's body text is
  what you show the user (it usually names the offending parameter; replayed failures only
  repeat that the model itself is unhappy).
- Track which combination actually reached the server (`attemptedSearch`), because the
  evidence detector below must know whether the **winning** request carried the search fields.

Rule: never assume a server supports search. Feature-detect via the replay cascade and
memoize per (baseUrl, model).

## Evidence: did the search actually run?

These servers' tool loops are **invisible**: they emit no visible marker on the stream, yet
the tool result is injected into context (scraped pages become prompt material), and the usage
chunk `stream_options.include_usage` unlocks reports it. So detect hard evidence, never trust
the flag:

1. SSE line that is not `data:` but starts with `event:` and matches `/tool/i`
   (Unsloth streams custom `event: tool_result` lines).
2. A usage chunk whose `usage.prompt_tokens` jumps far above what you sent:

```
promptTokens > expectedTokens * 1.35 + 400
expectedTokens = (searchNote.length + sentTextChars) / 3.5   // chars ≈ 3.5 tokens
```

- `expectedTokens` counts the sent message characters **plus the system note** (it only counted
  the note when the fields rode — a plain turn must never be mistaken for a searched one).
- Gate both detectors on `expectedTokens > 0`, i.e. only when this turn's winning request
  actually carried the search fields.
- Observed on a real server: ~180-token prompt → 5,776 prompt tokens when the search ran.
- 1.35× + 400 threshold mirrors the reference implementation; keep it.

Rule: search ran iff a `…tool…` event line appeared, or prompt_tokens ≫ what we sent.
A searched-but-no-evidence turn gets no credit — better a missed chip than a fake one.

## The marker protocol (proxy → client, one shared text stream)

The proxy yields into its text stream exactly one control-character byte, at most once per
reply, when the first piece of evidence arrives:

- `\u0001` = searchMarker: "a web search verifiably ran this turn".
- (`\u0000` = thinkingMarker, same protocol, reasoning deltas; include it if your app has
  thinking too, and note that searchMarker must be a byte model text can never contain.)

Client side of the protocol:

- Accumulate the buffer; `buffer.includes(searchMarker)` → stamp the in-flight assistant
  message `searched: true`; render `buffer` with both marker bytes removed
  (`replaceAll(thinkingMarker, "").replaceAll(searchMarker, "")`).
- Give the message type an **optional** `searched?: boolean` field, persisted with the chat.
  Optional keeps old chats loadable untouched, and the chip only rides turns the proxy proved
  searched. Render a small "🌐 Searched the web" chip on `searched === true`.

Rule: out-of-band signals ride the same stream as NUL-class bytes; client strips them and turns
them into per-message metadata. Never let them reach the UI as text.

## Portability checklist for a new app

1. Add a global persisted `webSearch` boolean (default **false**) to your settings, with a UI
   toggle; plus a per-request force flag if you have any one-shot "search this" flow.
2. Send it in the client→proxy body; on the proxy, add the four search fields and the dated
   system note only when effectively on.
3. Put the LLM call behind a server-side proxy that parses the upstream SSE and streams plain
   text deltas to the client (no CORS, clean parsing). Disable buffering/caching on the
   response (`Cache-Control: no-cache, no-transform`, `X-Accel-Buffering: no`, and your
   framework's "don't cache this route" equivalent).
4. Implement the 400-replay cascade + `(baseUrl, model)` rejection memo, and remember which
   combination actually succeeded.
5. Implement both evidence detectors (tool-event line + prompt-token jump) gated on
   "this turn carried the search fields", with `stream_options.include_usage` on.
6. Emit one `\u0001` byte on evidence; client strips it, stamps `searched: true` on the
   assistant message, persists it, shows a chip.

## Pitfalls (all proven against these servers)

- `permission_mode: "off"` is required: Studio defaults to tool **confirmation**, which 400s a
  streaming tool call and leaves the model *writing* tool markup as answer text instead of one
  running.
- The old `tools: [{type:"web_search"}]` spelling is silently ignored → 200 with no search.
  You get a confident memory-only answer with no error — a leading source of "why didn't it
  search?" bugs.
- No system note → the model refuses to browse even with tools offered.
- Forgetting `stream_options.include_usage` makes a ran-or-not search literally invisible on
  llama-server hosts (they give no other evidence).
- Trusting the toggle instead of evidence → chip lies on servers that ignore the fields.
- `expectedTokens` must include the note's characters, and only for turns where the note rode.
- Rejections are per (baseUrl, model): memoize both.

## Reference implementation in this app

- `app/api/chat/route.ts` — the whole proxy layer: `searchRejected` memo, `askUpstream` body
  with the four fields + note, the replay cascade, `streamContent()` SSE parser with both
  evidence detectors and the `searchMarker` yield.
- `lib/llm.ts` — `WEB_SEARCH_DEFAULT = false`, `loadWebSearch`/`saveWebSearch`
  (localStorage `"1"`/`"0"`), `Message.searched?: boolean`.
- `components/Chat.tsx` — globe toggle state, `runStream(…, forceSearch)`, marker stripping
  (`searchMarker = "\u0001"`), stamping `{ searched: true }` on the streamed bubble.
- `components/Message.tsx` — the "🌐 Searched the web" chip from `message.searched`.
- `docs/implementation-notes.md` ("Wire details") — the cascade ordering, memo key, and the
  5,776-vs-~180 token probe that justified the heuristic.
