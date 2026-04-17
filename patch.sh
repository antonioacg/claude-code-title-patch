#!/usr/bin/env bash
# Claude Code Terminal Title Patch
#
# Problem: Claude Code generates a terminal title from the first user message
# but never updates it again, even when the conversation changes topic. It also
# skips title generation entirely on resumed sessions.
#
# Three patch sites (v2.1.87 minified names shown):
#
# 1. onBeforeQuery handler — one-shot guard prevents re-generation:
#
#      d5.current = !0,  // <-- fires once, then blocks forever
#      i9H(Iz, new AbortController().signal).then(...)
#
#    Anchor: `.current=!0,` near `AbortController` (~120 bytes)
#    Fix: `!0` -> `!1` (0x30 -> 0x31)
#
# 2. Session resume handler — guard blocks title gen for restored sessions:
#
#      d5.current = !0, m3(void 0)  // <-- blocks + clears title
#      ... Q("tengu_session_resumed", ...)
#
#    Anchor: `.current=!0,` near `tengu_session_resumed` (~300 bytes)
#    Fix: `!0` -> `!1` (0x30 -> 0x31)
#
# 3. Guard initialization — ref starts true when messages exist (resume):
#
#      d5 = useRef(($?.length ?? 0) > 0)  // <-- true on resume
#
#    Pattern: `.length??0)>0)` near `"Claude Code"` (~80 bytes)
#    Note: The useRef call and variable name vary across platforms
#    (e.g. `A6.useRef(($?.length??0)>0)` on macOS, `w6.useRef((O?.length??0)>0)` on Linux)
#    Fix: `>0)` -> `<0)` (0x3e -> 0x3c) — length is never negative, so always false
#
# The title generator uses model inference to decide if the message warrants
# a new title, so repeated calls are harmless.
#
# The patch is overwritten on each Claude Code auto-update. Re-run after.
#
# Usage:
#   ./patch.sh                # patches whichever binary is on PATH
#   ./patch.sh /path/to/bin   # patches a specific binary
#   ./patch.sh --check        # check patch status without modifying
#   ./patch.sh --restore      # restore from backup

set -eo pipefail

# --- Parse arguments ---
CHECK_ONLY=false
RESTORE=false
BINARY=""

for arg in "$@"; do
  case "$arg" in
    --check)  CHECK_ONLY=true ;;
    --restore) RESTORE=true ;;
    -*) echo "error: unknown option: $arg" >&2; exit 1 ;;
    *)  BINARY="$arg" ;;
  esac
done

# --- Resolve binary ---
if [[ -z "$BINARY" ]]; then
  # 1. mise installs directory (avoids shim → mise symlink problem)
  mise_dir="$HOME/.local/share/mise/installs/claude"
  if [[ -d "$mise_dir" ]]; then
    latest=$(ls -1 "$mise_dir" | sort -V | tail -1)
    if [[ -n "$latest" && -f "$mise_dir/$latest/claude" ]]; then
      BINARY="$mise_dir/$latest/claude"
    fi
  fi
  # 2. which + realpath
  if [[ -z "$BINARY" ]]; then
    BINARY=$(command -v claude 2>/dev/null) || true
    if [[ -z "$BINARY" ]]; then
      echo "error: 'claude' not found on PATH" >&2
      exit 1
    fi
    BINARY=$(readlink -f "$BINARY" 2>/dev/null || realpath "$BINARY" 2>/dev/null || echo "$BINARY")
  fi
fi

if [[ ! -f "$BINARY" ]]; then
  echo "error: binary not found: $BINARY" >&2
  exit 1
fi

echo "Binary: $BINARY"

# --- Restore mode ---
if [[ "$RESTORE" == true ]]; then
  BACKUP="$BINARY.bak"
  if [[ ! -f "$BACKUP" ]]; then
    echo "error: no backup found at $BACKUP" >&2
    exit 1
  fi
  cp "$BACKUP" "$BINARY"
  if [[ "$(uname -s)" == "Darwin" ]]; then
    codesign --sign - --force "$BINARY" 2>/dev/null
  fi
  echo "Restored from backup"
  exit 0
fi

# --- Find patterns ---
# Each patch site has a mode (byte or replace), a grep pattern (unpatched/patched),
# an anchor string that must appear within a scan range forward of the pattern,
# and mode-specific fields for the edit.

# Searches for a literal pattern and filters by a nearby anchor string.
# Args: $1=pattern, $2=anchor, $3=scan range
find_offsets() {
  local pattern="$1" anchor="$2" range="${3:-120}"
  local offsets=()
  while IFS=: read -r offset _; do
    offsets+=("$offset")
  done < <(grep -b -o -a -F "$pattern" "$BINARY" 2>/dev/null || true)

  local matches=()
  for offset in "${offsets[@]}"; do
    # grep -a treats binary input as text; avoids `strings` which truncates
    # long printable runs (~1024 chars on macOS) and would miss anchors for
    # long patterns.
    if dd if="$BINARY" bs=1 skip="$offset" count="$range" 2>/dev/null | grep -qF -a "$anchor"; then
      matches+=("$offset")
    fi
  done
  echo "${matches[@]}"
}

# Patch a single byte at a given offset.
# Args: $1=offset, $2=expected hex, $3=replacement hex
patch_byte() {
  local offset="$1" expected="$2" replacement="$3"
  local current_hex
  current_hex=$(dd if="$BINARY" bs=1 skip="$offset" count=1 2>/dev/null | xxd -p)
  if [[ "$current_hex" != "$expected" ]]; then
    echo "warning: unexpected byte at offset $offset: 0x$current_hex (expected 0x$expected), skipping" >&2
    return 1
  fi
  printf "\\x$replacement" | dd of="$BINARY" bs=1 seek="$offset" conv=notrunc 2>/dev/null
  return 0
}

# Replace a multi-byte sequence at a given offset with a same-length string.
# Args: $1=offset, $2=expected string, $3=replacement string
patch_bytes() {
  local offset="$1" expected="$2" replacement="$3"
  if [[ ${#expected} -ne ${#replacement} ]]; then
    echo "error: expected and replacement differ in length (${#expected} vs ${#replacement})" >&2
    return 1
  fi
  local current
  current=$(dd if="$BINARY" bs=1 skip="$offset" count="${#expected}" 2>/dev/null)
  if [[ "$current" != "$expected" ]]; then
    echo "warning: unexpected bytes at offset $offset, skipping" >&2
    return 1
  fi
  printf '%s' "$replacement" | dd of="$BINARY" bs=1 seek="$offset" conv=notrunc 2>/dev/null
  return 0
}

# --- Patch site definitions ---
# Two formats:
#   byte:    name|byte|unpatched|patched|anchor|range|byte_offset|from_hex|to_hex
#   replace: name|replace|unpatched|patched|anchor|range
# For `replace`, `unpatched` and `patched` must be the same length — the whole
# pattern is overwritten in place (no byte-shifting).

# Site 5 (titlePriority) is a 1167-byte compressed rewrite of the Vt else-if chain
# that adds an ai-title handler with priority logic. The sentinel-key trick
# (O.set("c"+i,1) on custom-title, !O.has("c"+i) guard on ai-title) lets the
# latest auto-gen topic win while still letting /rename override it. Patterns are
# factored out as vars because they're ~1.2 KB each. See README for full rationale.
TITLE_PRIORITY_UNPATCHED='else if(V.type==="custom-title"&&V.sessionId)O.set(V.sessionId,V.customTitle);else if(V.type==="tag"&&V.sessionId)T.set(V.sessionId,V.tag);else if(V.type==="agent-name"&&V.sessionId)$.set(V.sessionId,V.agentName);else if(V.type==="agent-color"&&V.sessionId)A.set(V.sessionId,V.agentColor);else if(V.type==="agent-setting"&&V.sessionId)z.set(V.sessionId,V.agentSetting);else if(V.type==="mode"&&V.sessionId)j.set(V.sessionId,V.mode);else if(V.type==="permission-mode"&&V.sessionId)D.set(V.sessionId,V.permissionMode);else if(V.type==="worktree-state"&&V.sessionId)M.set(V.sessionId,V.worktreeSession);else if(V.type==="pr-link"&&V.sessionId)w.set(V.sessionId,V.prNumber),Y.set(V.sessionId,V.prUrl),f.set(V.sessionId,V.prRepository);else if(V.type==="file-history-snapshot")J.set(V.messageId,V);else if(V.type==="attribution-snapshot")P.clear(),P.set(V.messageId,V);else if(V.type==="content-replacement")if(V.agentId){let C=R.get(V.agentId)??[];R.set(V.agentId,C),C.push(...V.replacements)}else{let C=X.get(V.sessionId)??[];X.set(V.sessionId,C),C.push(...V.replacements)}else if(V.type==="marble-origami-commit")W.push(V);else if(V.type==="marble-origami-snapshot")G=V'
TITLE_PRIORITY_PATCHED='else{let t=V.type,i=V.sessionId;if(t==="custom-title"&&i)O.set(i,V.customTitle),O.set("c"+i,1);else if(t==="ai-title"&&i&&!O.has("c"+i))O.set(i,V.aiTitle);else if(t==="tag"&&i)T.set(i,V.tag);else if(t==="agent-name"&&i)$.set(i,V.agentName);else if(t==="agent-color"&&i)A.set(i,V.agentColor);else if(t==="agent-setting"&&i)z.set(i,V.agentSetting);else if(t==="mode"&&i)j.set(i,V.mode);else if(t==="permission-mode"&&i)D.set(i,V.permissionMode);else if(t==="worktree-state"&&i)M.set(i,V.worktreeSession);else if(t==="pr-link"&&i)w.set(i,V.prNumber),Y.set(i,V.prUrl),f.set(i,V.prRepository);else if(t==="file-history-snapshot")J.set(V.messageId,V);else if(t==="attribution-snapshot")P.clear(),P.set(V.messageId,V);else if(t==="content-replacement")if(V.agentId){let C=R.get(V.agentId)??[];R.set(V.agentId,C),C.push(...V.replacements)}else{let C=X.get(i)??[];X.set(i,C),C.push(...V.replacements)}else if(t==="marble-origami-commit")W.push(V);else if(t==="marble-origami-snapshot")G=V;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;}'

SITES=(
  "onBeforeQuery|byte|.current=!0,|.current=!1,|AbortController|120|10|30|31"
  "sessionResume|byte|.current=!0,|.current=!1,|tengu_session_resumed|500|10|30|31"
  "guardInit|byte|.length??0)>0)|.length??0)<0)|Claude Code|80|11|3e|3c"
  "persistTitle|replace|(yL)=>{if(yL)LL(yL);else lW.current=!1}|(yL)=>{if(yL)MH6(b_(),yL),Gw8(yL);;;;;}|toolPermissionContext|120"
  "titlePriority|replace|${TITLE_PRIORITY_UNPATCHED}|${TITLE_PRIORITY_PATCHED}|marble-origami-snapshot|1200"
  "titleGate|replace|!V&&!\$j&&!X3&&!lW.current|!V&&!!1&&!X3&&!lW.current|AbortController|250"
)

ALL_PATCHED=0
ALL_UNPATCHED=0
declare -a PENDING_PATCHES  # "byte|offset|byte_off|from|to" or "replace|offset|unpatched|patched"

for site in "${SITES[@]}"; do
  IFS='|' read -r name mode unpatched patched anchor range byte_off from_hex to_hex <<< "$site"

  read -ra patched_offsets <<< "$(find_offsets "$patched" "$anchor" "$range")"
  read -ra unpatched_offsets <<< "$(find_offsets "$unpatched" "$anchor" "$range")"

  if [[ ${#patched_offsets[@]} -gt 0 && "${patched_offsets[0]}" != "" ]]; then
    echo "  $name: patched (${#patched_offsets[@]})"
    ALL_PATCHED=$((ALL_PATCHED + ${#patched_offsets[@]}))
  elif [[ ${#unpatched_offsets[@]} -gt 0 && "${unpatched_offsets[0]}" != "" ]]; then
    echo "  $name: unpatched (${#unpatched_offsets[@]})"
    ALL_UNPATCHED=$((ALL_UNPATCHED + ${#unpatched_offsets[@]}))
    for off in "${unpatched_offsets[@]}"; do
      if [[ "$mode" == "byte" ]]; then
        PENDING_PATCHES+=("byte|$off|$byte_off|$from_hex|$to_hex")
      else
        PENDING_PATCHES+=("replace|$off|$unpatched|$patched")
      fi
    done
  else
    echo "  $name: not found"
  fi
done

if [[ $ALL_UNPATCHED -eq 0 && $ALL_PATCHED -gt 0 ]]; then
  echo "Status: patched ($ALL_PATCHED occurrence(s))"
  [[ "$CHECK_ONLY" == true ]] && exit 0
  echo "Already patched — nothing to do"
  exit 0
fi

if [[ $ALL_UNPATCHED -eq 0 && $ALL_PATCHED -eq 0 ]]; then
  echo "Status: unknown"
  echo "ERROR: Could not find the expected code pattern in this binary." >&2
  echo "This version of Claude Code may not be compatible with this patch." >&2
  exit 1
fi

echo "Status: unpatched"
echo "Found ${#PENDING_PATCHES[@]} occurrence(s) to patch"

if [[ "$CHECK_ONLY" == true ]]; then
  exit 0
fi

# --- Back up ---
BACKUP="$BINARY.bak"
if [[ ! -f "$BACKUP" ]]; then
  cp "$BINARY" "$BACKUP"
  echo "Backup: $BACKUP"
else
  echo "Backup already exists: $BACKUP"
fi

# --- Patch ---
for entry in "${PENDING_PATCHES[@]}"; do
  pmode="${entry%%|*}"
  rest="${entry#*|}"
  if [[ "$pmode" == "byte" ]]; then
    IFS='|' read -r base_offset byte_off from_hex to_hex <<< "$rest"
    patch_offset=$((base_offset + byte_off))
    if patch_byte "$patch_offset" "$from_hex" "$to_hex"; then
      echo "Patched offset $patch_offset: 0x$from_hex -> 0x$to_hex"
    fi
  else
    IFS='|' read -r off expected replacement <<< "$rest"
    if patch_bytes "$off" "$expected" "$replacement"; then
      echo "Replaced at offset $off: ${#expected} bytes"
    fi
  fi
done

# --- Re-sign (required on macOS arm64) ---
if [[ "$(uname -s)" == "Darwin" ]]; then
  codesign --sign - --force "$BINARY" 2>/dev/null
  echo "Re-signed binary"
fi

echo "Done. Restart Claude Code for the patch to take effect."
