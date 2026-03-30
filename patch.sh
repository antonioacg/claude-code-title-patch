#!/usr/bin/env bash
# Claude Code Terminal Title Patch
#
# Problem: Claude Code generates a terminal title from the first user message
# but never updates it again, even when the conversation changes topic. It also
# skips title generation entirely on resumed sessions.
#
# Two patch sites (v2.1.87 minified names shown):
#
# 1. onBeforeQuery handler — one-shot guard prevents re-generation:
#
#      d5.current = !0,  // <-- fires once, then blocks forever
#      i9H(Iz, new AbortController().signal).then(...)
#
#    Anchor: `.current=!0,` near `AbortController` (~120 bytes)
#
# 2. Session resume handler — guard blocks title gen for restored sessions:
#
#      d5.current = !0, m3(void 0)  // <-- blocks + clears title
#      ... Q("tengu_session_resumed", ...)
#
#    Anchor: `.current=!0,` near `tengu_session_resumed` (~300 bytes)
#
# Fix: Change `!0` (true) to `!1` (false) at both sites. Single byte change
# each (0x30 -> 0x31). The title generator uses model inference to decide if
# the message warrants a new title, so repeated calls are harmless.
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
  BINARY=$(command -v claude 2>/dev/null) || true
  if [[ -z "$BINARY" ]]; then
    echo "error: 'claude' not found on PATH" >&2
    exit 1
  fi
  BINARY=$(readlink -f "$BINARY" 2>/dev/null || realpath "$BINARY" 2>/dev/null || echo "$BINARY")
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
# Both patch sites share `.current=!0,` but are distinguished by what follows:
#   - onBeforeQuery:  `AbortController` within ~120 bytes
#   - session resume: `tengu_session_resumed` within ~300 bytes
# We search for `.current=!0,` (unpatched) or `.current=!1,` (patched) and
# filter by nearby anchor strings.

# Searches for `.current=!{0|1},` and filters by a nearby anchor string.
# Args: $1=pattern (.current=!0, or .current=!1,), $2=anchor, $3=scan range
find_offsets() {
  local pattern="$1" anchor="$2" range="${3:-120}"
  local offsets=()
  while IFS=: read -r offset _; do
    offsets+=("$offset")
  done < <(grep -b -o -a "$pattern" "$BINARY" 2>/dev/null || true)

  local matches=()
  for offset in "${offsets[@]}"; do
    local context
    context=$(dd if="$BINARY" bs=1 skip="$offset" count="$range" 2>/dev/null | strings -n 5)
    if echo "$context" | grep -q "$anchor"; then
      matches+=("$offset")
    fi
  done
  echo "${matches[@]}"
}

# Patch site definitions: name, anchor string, scan range
SITES=("onBeforeQuery:AbortController:120" "sessionResume:tengu_session_resumed:300")

ALL_PATCHED=0
ALL_UNPATCHED=0
PATCH_OFFSETS=()

for site in "${SITES[@]}"; do
  IFS=: read -r name anchor range <<< "$site"

  read -ra patched <<< "$(find_offsets '.current=!1,' "$anchor" "$range")"
  read -ra unpatched <<< "$(find_offsets '.current=!0,' "$anchor" "$range")"

  if [[ ${#patched[@]} -gt 0 && "${patched[0]}" != "" ]]; then
    echo "  $name: patched (${#patched[@]})"
    ALL_PATCHED=$((ALL_PATCHED + ${#patched[@]}))
  elif [[ ${#unpatched[@]} -gt 0 && "${unpatched[0]}" != "" ]]; then
    echo "  $name: unpatched (${#unpatched[@]})"
    ALL_UNPATCHED=$((ALL_UNPATCHED + ${#unpatched[@]}))
    PATCH_OFFSETS+=("${unpatched[@]}")
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
echo "Found ${#PATCH_OFFSETS[@]} occurrence(s) to patch"

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
# `.current=!0,` — the `0` is at byte 10 (0-indexed): . c u r r e n t = ! 0
#                                                      0 1 2 3 4 5 6 7 8 9 10
for offset in "${PATCH_OFFSETS[@]}"; do
  patch_offset=$((offset + 10))

  # Verify we're patching the right byte (0x30 = '0')
  current_hex=$(dd if="$BINARY" bs=1 skip="$patch_offset" count=1 2>/dev/null | xxd -p)
  if [[ "$current_hex" != "30" ]]; then
    echo "warning: unexpected byte at offset $patch_offset: 0x$current_hex (expected 0x30), skipping" >&2
    continue
  fi

  printf '\x31' | dd of="$BINARY" bs=1 seek="$patch_offset" conv=notrunc 2>/dev/null
  echo "Patched offset $patch_offset: !0 -> !1"
done

# --- Re-sign (required on macOS arm64) ---
if [[ "$(uname -s)" == "Darwin" ]]; then
  codesign --sign - --force "$BINARY" 2>/dev/null
  echo "Re-signed binary"
fi

echo "Done. Restart Claude Code for the patch to take effect."
