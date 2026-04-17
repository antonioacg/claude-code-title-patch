# Claude Code Terminal Title Patch

Patches the Claude Code binary so the terminal title **updates on every user message** and **persists across session resume**.

Without this patch, Claude Code generates a title from the first user message and never updates it again. If the conversation shifts topic, the title stays stale for the rest of the session. Resumed sessions show "Claude Code" until the first user message, and auto-generated titles are never written to disk so they can't be recovered on the next resume.

## How it works

### Patch site 1: onBeforeQuery — one-shot guard

The `onBeforeQuery` handler generates terminal titles. A `useRef` guard fires once and blocks forever (v2.1.87, minified names vary by version):

```javascript
// d5 is a useRef — one-shot guard, starts as false
// m3 is the title setter — m3(title) updates the terminal title
// i9H is the title generator — calls the model to produce a short title

if (!yA && !G5 && !Ez && !d5.current) {
  let bz = x_.find((yO) => yO.type === "user" && !yO.isMeta);
  let Iz = bz?.type === "user" ? AF(bz.message.content) : null;
  if (Iz && !Iz.startsWith(...))
    d5.current = !0,  // <-- one-shot: never fires again
    i9H(Iz, new AbortController().signal).then((yO) => {
      if (yO) m3(yO); else d5.current = false
    }, () => { d5.current = false })
}
```

Anchor: `.current=!0,` near `AbortController` (~120 bytes).

### Patch site 2: session resume — guard blocks restored sessions

When a session is resumed, the guard is set to `true` and the title is cleared. This prevents title generation for restored sessions entirely:

```javascript
d5.current = !0, m3(void 0)  // guard ON, title cleared
// ... later ...
Q("tengu_session_resumed", { entrypoint: ..., success: true })
```

Anchor: `.current=!0,` near `tengu_session_resumed` (~300 bytes).

### Patch site 3: guard initialization — ref starts true on resume

The guard ref is initialized with the current message count. On resume, messages already exist, so it starts as `true` — blocking title generation before the resume handler even runs:

```javascript
d5 = useRef(($?.length ?? 0) > 0)  // true when resuming (messages exist)
```

Pattern: `.length??0)>0)` near `"Claude Code"` (~80 bytes). The `useRef` call and variable name are minified differently per platform (e.g. `A6.useRef(($?...` on macOS, `w6.useRef((O?...` on Linux), so the grep pattern starts at `.length`.

### Patch site 4: persist generated title — write to disk on every generation

The `onBeforeQuery` success callback stores the generated title in React state only. `MH6(sessionId, title)` already exists and writes `{"type":"ai-title","aiTitle":...}` to the session jsonl (used by the SDK path at `@84409463`), but the interactive path never calls it:

```javascript
// unpatched (v2.1.112)
pe(QT, new AbortController().signal).then((yL) => {
  if (yL) LL(yL);              // set React state only — not persisted
  else lW.current = !1         // redundant after site 1 patch
}, () => { lW.current = !1 })
```

The fix rewrites the 39-byte success-callback arrow body in place (same length, no byte-budget required):

```javascript
// patched
(yL)=>{if(yL)MH6(b_(),yL),Gw8(yL);;;;;}
//           ^^^^^^^^^^^^^ ^^^^^^^^
//           persist        update currentSessionTitle + emit
//                                  ^^^^^ padding to keep 39 bytes
```

Pattern: `(yL)=>{if(yL)LL(yL);else lW.current=!1}` near `toolPermissionContext` (~120 bytes).

Why `MH6` (ai-title) and not `Vv` (custom-title): `customTitle` is reserved for user `/rename`. If auto-generation wrote `custom-title`, the user's rename would be clobbered *on disk* on every message. `ai-title` keeps the two sources distinguishable in the file so site 5 can prefer `/rename` on resume.

Why `Gw8` (store write + emit) and not `LL` (React state only): once site 5 loads the last `ai-title` into `currentSessionTitle` on resume, `$j` is populated and wins the priority chain. Subsequent auto-gen calls need to update `currentSessionTitle` too, otherwise `$j` remains stale and the display doesn't refresh mid-session. `Gw8` does exactly that (`F5().currentSessionTitle = H, Ww8.emit()`), triggering the `useSyncExternalStore` subscription.

Site 4 on its own is necessary but **not sufficient** — see sites 5 and 6.

### Patch site 5: make full-load resume read ai-title

Claude Code has two session-reading paths that behave differently:

- **Picker/lite path (`ZV5` at `@82570953`)** — string-scans the head and tail of the jsonl, uses `customTitle ?? aiTitle`. This is why `ai-title` shows up in the `/resume` list picker.
- **Full-load path (`Vt` at `@82558475`)** — parses every jsonl line as an event, routes by `type` into per-type Maps. It handles `custom-title`, `tag`, `agent-name`, `agent-color`, `agent-setting`, `mode`, `permission-mode`, `worktree-state`, `pr-link`, `file-history-snapshot`, `attribution-snapshot`, `content-replacement`, `marble-origami-commit`, `marble-origami-snapshot` — **but not `ai-title`**.

`--continue` and `--resume` both go through the full-load path. `Vt` ignores `ai-title` events, so `Q_.customTitle` arrives at `En(Q_)` as undefined, and the priority chain falls through to `"Claude Code"`.

The fix rewrites the entire 1167-byte else-if chain (from `custom-title` through `marble-origami-snapshot`) in place. The compression comes from aliasing `V.type` → `t` and `V.sessionId` → `i` throughout, saving ~200 bytes that pay for the new `ai-title` handler and padding.

```javascript
// unpatched — 13 branches, no ai-title
else if(V.type==="custom-title"&&V.sessionId)O.set(V.sessionId,V.customTitle);
else if(V.type==="tag"&&V.sessionId)T.set(V.sessionId,V.tag);
// ... 11 more branches ...
else if(V.type==="marble-origami-snapshot")G=V

// patched — wraps the chain in `else{let t,i; ...}` and adds ai-title handler
else{
  let t=V.type, i=V.sessionId;
  if(t==="custom-title"&&i) O.set(i,V.customTitle), O.set("c"+i,1);   // sentinel marker
  else if(t==="ai-title"&&i&&!O.has("c"+i)) O.set(i,V.aiTitle);       // skips if rename exists
  else if(t==="tag"&&i) T.set(i,V.tag);
  // ... all other branches, using t and i ...
  else if(t==="marble-origami-snapshot") G=V
  ;;;;;;...   // empty statements padding to 1167 bytes
}
```

**Priority logic via sentinel key.** The goal: `/rename` should always win, AND the latest auto-generated topic should win when no `/rename` exists. A single map can't express that without distinguishing which entry was written by `custom-title` vs `ai-title`.

The trick: when processing `custom-title`, write the title at key `sessionId` **and** a marker at key `"c"+sessionId` (just `1`). When processing `ai-title`, guard with `!O.has("c"+sessionId)` — skip if a rename has ever been seen for this session. Since session IDs are UUIDs (36 chars, all hex+hyphen), they never collide with the 37-char `"c"+UUID` sentinel keys. `O.get(sessionId)` always returns the intended value; sentinel entries are invisible to downstream `.get()` consumers.

Scenarios (verified in test harness):

| Event order | Result |
|---|---|
| `ai, ai, ai` (no rename) | Latest `ai-title` wins ✓ |
| `ai, rename, ai` | `rename` wins ✓ |
| `rename, ai, ai` | `rename` wins ✓ |
| `rename, ai, rename2` | `rename2` wins ✓ (last rename) |

Pattern: full 1167-byte unpatched chain, near `marble-origami-snapshot` (range 1200).

### Patch site 6: remove the `!$j` check from the onBeforeQuery gate

Sites 1–5 alone have a subtle bug: once site 5 populates `currentSessionTitle` from the resumed `ai-title`, `$j` is truthy, and the gate `if(!V && !$j && !X3 && !lW.current)` fails. The title generator stops firing on subsequent user messages. New `ai-title` events never get written, and resume cycles get stuck on the pre-resume title.

The gate's `!$j` clause was upstream's way of saying "don't auto-generate when a user has set a rename." But with our flow, resume *always* populates `$j` (from either `/rename` or `ai-title`), so the check over-matches.

The fix is a byte-equal swap of the 3-char `!$j` expression with `!!1` (always `true`), effectively dropping the check:

```javascript
// unpatched
if(!V&&!$j&&!X3&&!lW.current){ ... pe(QT, ...).then(...) }

// patched
if(!V&&!!1&&!X3&&!lW.current){ ... pe(QT, ...).then(...) }
//      ^^^ always true
```

Pattern: `!V&&!$j&&!X3&&!lW.current` (25 bytes) near `AbortController` (~170 bytes forward).

### The fix

| Site | Mode | What it does | Size |
|---|---|---|---|
| onBeforeQuery | byte | Disable one-shot guard on the query path | 1 byte (`0x30` → `0x31`) |
| sessionResume | byte | Don't re-arm the guard on resume | 1 byte (`0x30` → `0x31`) |
| guardInit | byte | `useRef` starts `false` even when messages exist | 1 byte (`0x3e` → `0x3c`) |
| persistTitle | replace | Write every auto-gen title as `ai-title`; refresh `currentSessionTitle` in-session | 39-byte in-place swap |
| titlePriority | replace | Make full-load reader consume `ai-title` with proper priority | 1167-byte compressed rewrite |
| titleGate | replace | Drop `!$j` from the gate so auto-gen fires even when `$j` is loaded from resume | 25-byte in-place swap |

Sites 1–3 make the title generator eligible to fire on every `onBeforeQuery`. Site 6 unblocks it when resume has populated `$j`. Site 4 persists the result to jsonl and updates the in-session store. Site 5 makes the jsonl-persisted title flow back through `--continue` / `--resume` without clobbering `/rename` on disk.

The title priority chain at render time: `renameTitle ?? agentType ?? generatedTitle ?? "Claude Code"` — rename title > agent type > generated title > fallback. (Minified names vary per platform, e.g. `G5 ?? Ez ?? F4` on 2.1.87 macOS, `$j ?? X3 ?? mP` on 2.1.112 macOS.)

After patching, the binary is ad-hoc re-signed with `codesign -s -` on macOS.

### Title persistence architecture (2.1.112)

What's actually on disk and how it flows back in on resume:

- **Writers**:
  - `Vv(sessionId, title)` — writes `{"type":"custom-title","customTitle":…}`, updates the runtime store, fires `tengu_session_renamed`. Called by `/rename`.
  - `MH6(sessionId, title)` — writes `{"type":"ai-title","aiTitle":…}`, persist-only. Called by the SDK path originally; after site 4, also by interactive `onBeforeQuery`.
- **Readers**:
  - `ZV5` (lite/picker): `customTitle ?? aiTitle` via head/tail string scan. Always worked for both types.
  - `Vt` (full-load): event-by-event type routing. Handles `custom-title` → `O` map; **after site 5**, also handles `ai-title` → same `O` map with priority logic.
- **Resume flow**: `Vt` → `$H6/q9_/TV5` → `Q_.customTitle` → `En(Q_)` → `currentSessionTitle` → `$j` → rendered title.

Priority is preserved by the sentinel-key trick in site 5: `O.get(sessionId)` returns `/rename` if any was set (even mid-session), otherwise the latest auto-gen topic.

## Requirements

- Bash
- Claude Code installed as a compiled binary (mise, standalone download)
- `grep`, `dd`, `xxd` (standard on macOS and Linux)

## Usage

```bash
# Apply the patch
./patch.sh

# Check current status without modifying
./patch.sh --check

# Restore original binary from backup
./patch.sh --restore

# Use a specific binary path
./patch.sh /path/to/claude
```

The patcher automatically:
1. Locates the Claude Code binary (checks mise installs directory first, falls back to `which claude`)
2. For each patch site, searches for the unpatched or patched pattern anchored by a nearby string
3. Creates a backup (`.bak` alongside the binary)
4. Applies the site-specific edit (single byte for sites 1–3; multi-byte in-place replacement for sites 4–5)
5. Re-signs the binary (macOS only)

### After Claude Code updates

Updates replace the binary, removing the patch. Re-run `./patch.sh` after each update.

## Version history

### Gate pattern changes

| Version | Gate pattern | Sites | Status |
|---|---|---|---|
| < 2.1.87 | `messages.length<=1` | `length<=1` near `.then(` | First-message bug: system messages inflated count, title never fired |
| 2.1.87 | `d5.current=!0` (one-shot ref) + `useRef(>0)` (init) | 3 sites: query gate, resume handler, ref init | First-message fixed upstream, but one-shot + no resume titles |
| 2.1.112 | Same structure, new minified names (`lW` guard, `LL`/`Gw8` setters, `pe` generator, `MH6` persist, `ix` content extractor, `$j` rename-title subscription). `tengu_session_resumed` anchor distance grew from ~170B to ~400B → sessionResume scan range bumped to 500. Added site 4 (persistTitle), site 5 (titlePriority — 1167-byte `Vt` rewrite with sentinel-key trick), site 6 (titleGate — drops `!$j` check so auto-gen fires after resume). | 6 sites |

### Tested versions

| Claude Code | Platform | Status | Notes |
|---|---|---|---|
| 2.1.87 | macOS arm64 (mise) | Tested | Bun Mach-O, 6 occurrences (3 sites x 2 code/source map) |
| 2.1.87-linux | Linux x86_64 (mise) | Tested | Bun ELF, 6 occurrences (3 sites x 2 code/source map) |
| 2.1.112 | macOS arm64 (mise) | Tested | Bun Mach-O, 12 occurrences (6 sites x 2 code/source map) |

## Restoring

```bash
# Via the patcher
./patch.sh --restore

# Or manually
cp /path/to/claude.bak /path/to/claude
codesign --sign - --force /path/to/claude  # macOS only
```

## Alternatives considered

Earlier versions of this README speculated about how to get titles to appear on resume. The actual picture ended up being a two-reader problem, not a single-reader problem. Sites 4 + 5 together cover it. Documented here for completeness:

**A. Byte-budget compression + inject title generation in the resume handler.** Would call `pe(ix(fq.findLast(m=>m.type==="user"&&!m.isMeta)?.message?.content), new AbortController().signal).then(LL)` from the resume handler directly. ~105 bytes, requires finding that much slack in surrounding code. Costs a model call on every resume even when the previous title is already fine. Sites 4 + 5 avoid both problems: auto-gen writes the title at generation time, and resume just reads the stored title with zero model calls.

**B. Hijack a no-op `useEffect`.** The component has empty effects like `useEffect(()=>{},[OM,bL,tP])`. Replacing the body with a title-gen call would fire when messages load, but the effect watches unrelated deps (e.g. scroll state) and would re-fire too often. Same model-call-on-every-resume cost.

**C. Use session metadata on disk (initial partial implementation — "site 4 alone").** Earlier iterations claimed this was sufficient because the picker reader (`ZV5`) supports `customTitle ?? aiTitle`. That's true for the picker list, but `--continue` and `--resume` use the full-load reader `Vt`, which has no `ai-title` handler. Site 4 alone persists the title correctly but the read never happens — the title still shows as "Claude Code" after resume. **Site 5 completes this approach** by teaching `Vt` to handle `ai-title` with `/rename`-preserving priority.

**D. External shell hook.** Read the session jsonl after `claude --resume` and set the title via escape sequences. Doesn't need binary patching but requires orchestrating outside the binary and timing the write correctly. Dismissed in favor of the in-binary fix.

**E. Write `custom-title` directly from auto-gen (rejected).** The simplest "just make it persist" move — swap site 4's `MH6` for `Vv`. Vt's `custom-title` branch is already wired. But auto-gen fires on every user message (sites 1–3), and each fire would overwrite any prior `/rename` on disk. Site 5's sentinel-key trick is what makes the two sources distinguishable in a single map without this tradeoff.

## Tradeoff: `/rename` is clobbered in-session (not on disk)

Site 4 uses `Gw8(yL)` (store write + emit) so the display refreshes on every user message. `Gw8` overwrites `currentSessionTitle` unconditionally. If the user runs `/rename` mid-session and then sends another message, auto-gen's `Gw8` overwrites the rename in the runtime store — the on-screen title flips to the new auto-gen title.

**On disk**, `/rename` still writes a `custom-title` event via `Vv`, and site 5's sentinel ensures any later `ai-title` events are skipped at read time. So `--continue` on the same session shows the rename correctly.

This is the same "in-session rename clobber" behavior as upstream bug [#47397](https://github.com/anthropics/claude-code/issues/47397). Fixing it without clobber would require either (a) a new Map in `Vt` to store `ai-title` separately from `custom-title` (bytes we don't trivially have), or (b) an invasive resume-handler patch that loads the `ai-title` into React state `mP` instead of the store, keeping `$j` exclusive to `/rename`. Considered; left out of this patch to keep the change surface smaller.

## Context

- The upstream bug where titles never fired (pre-2.1.87) was tracked but the fix only made it one-shot.
- The `terminalTitleFromRename` setting controls whether `currentSessionTitle` flows into `$j`. The patch assumes the default (`true`); with it set to `false`, `$j` stays empty and site 4's `Gw8` writes would not reach the priority chain — the title would still update via `mP` if site 4 used `LL`, but with `Gw8` it's silently dropped. Non-default users should consider site 4 non-functional.
- The title generator uses model inference, so it naturally handles topic detection.
- Site 4 drops the `else lW.current=!1` branch. That branch is redundant once site 1 has disabled the guard (the ref stays `false` throughout). If a future Claude Code version ever re-arms the guard through a path site 1 doesn't catch and `pe` resolves with an empty title, the guard would stay stuck armed for the session. The promise-reject branch still clears the guard, so real errors are unaffected.
- Site 5 populates `O` with sentinel entries (`"c"+sessionId` → `1`) on every `custom-title` event. Downstream code only calls `O.get(sessionId)` with 36-char UUID keys, so sentinel entries (37 chars, prefixed with `"c"`) are never accidentally fetched. Any future code that iterates `customTitles` directly (e.g. `.values()`, `.entries()`) would see them — verified as of 2.1.112 that no such iteration exists across all destructured usages.
- Site 5 depends on event processing being single-pass through `Vt`. If Anthropic adds retry logic or a second-pass reader, the sentinel-guard approach may need revisiting.
- Site 6 removes the `!$j` check entirely. If Anthropic ever adds other `$j`-based behaviors that *should* gate title gen (e.g. an explicit "this rename is final, stop auto-gen" signal), we'd lose that. Not observed in 2.1.112.
- **Upgrading from earlier patch versions**: sites 4 and 5 changed between iterations. If the patcher reports "not found" after a script upgrade, run `./patch.sh --restore && ./patch.sh` to get back to a clean unpatched state and apply the new sites cleanly.
- Upstream has multiple open, unfixed issues in the same neighborhood (e.g. `#47397`, `#31394`, `#32150`, `#25090`). The title subsystem appears deprioritized, so no relief expected from upstream.

## License

MIT
