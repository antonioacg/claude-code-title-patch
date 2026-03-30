# Claude Code Terminal Title Patch

Patches the Claude Code binary so the terminal title **updates on every user message**, not just the first one.

Without this patch, Claude Code generates a title from the first user message and never updates it again. If the conversation shifts topic, the title stays stale for the rest of the session. Resumed sessions don't get a title at all.

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

Anchor: `useRef(($?.length??0)>0)` near `"Claude Code"` (~80 bytes).

### The fix

| Site | Original | Patched | Byte change |
|---|---|---|---|
| onBeforeQuery | `!0` (true) | `!1` (false) | `0x30` -> `0x31` |
| sessionResume | `!0` (true) | `!1` (false) | `0x30` -> `0x31` |
| guardInit | `>0)` (true on resume) | `<0)` (always false) | `0x3e` -> `0x3c` |

Single byte change per site. Since the guard stays `false`, the title generator fires on every `onBeforeQuery` — including after session resume. The generator uses model inference to decide if the message warrants a new title, so repeated calls are harmless.

The title priority chain: `G5 ?? Ez ?? F4 ?? "Claude Code"` — rename title > agent type > generated title > fallback.

After patching, the binary is ad-hoc re-signed with `codesign -s -` on macOS.

## Requirements

- Bash
- Claude Code installed as a compiled binary (mise, standalone download)
- `grep`, `dd`, `xxd`, `strings` (standard on macOS and Linux)

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
1. Locates the Claude Code binary (follows symlinks from `which claude`)
2. Finds all three patch sites by searching for unique anchor patterns near each
3. Creates a backup (`.bak` alongside the binary)
4. Applies the single-byte replacement at each site
5. Re-signs the binary (macOS only)

### After Claude Code updates

Updates replace the binary, removing the patch. Re-run `./patch.sh` after each update.

## Version history

### Gate pattern changes

| Version | Gate pattern | Anchor | Status |
|---|---|---|---|
| < 2.1.87 | `messages.length<=1` | `length<=1` near `.then(` | First-message bug: system messages inflated count, title never fired |
| 2.1.87 | `d5.current=!0` (one-shot ref) + `useRef(>0)` (init) | 3 sites: query gate, resume handler, ref init | First-message fixed upstream, but one-shot + no resume titles |

### Tested versions

| Claude Code | Platform | Status | Notes |
|---|---|---|---|
| 2.1.87 | macOS arm64 (mise) | Tested | Bun Mach-O, 6 occurrences (3 sites x 2 code/source map) |

## Restoring

```bash
# Via the patcher
./patch.sh --restore

# Or manually
cp /path/to/claude.bak /path/to/claude
codesign --sign - --force /path/to/claude  # macOS only
```

## Context

- The upstream bug where titles never fired (pre-2.1.87) was tracked but the fix only made it one-shot
- The `terminalTitleFromRename` setting controls whether `/name` overrides the generated title, but there is no setting to enable re-generation on topic changes
- The title generator uses model inference, so it naturally handles topic detection

## License

MIT
