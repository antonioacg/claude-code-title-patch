#!/usr/bin/env bash
# Claude Code Terminal Title Patch
#
# Problem: Claude Code generates a terminal title from the first user message
# but never updates it again, even when the conversation changes topic.
#
# The title generation code (onBeforeQuery handler, v2.1.87 minified names):
#
#   if (!yA && !G5 && !Ez && !d5.current) {
#     let bz = x_.find((yO) => yO.type === "user" && !yO.isMeta);
#     let Iz = bz?.type === "user" ? AF(bz.message.content) : null;
#     if (Iz && !Iz.startsWith(...))
#       d5.current = !0,  // <-- one-shot guard: never fires again
#       i9H(Iz, new AbortController().signal).then((yO) => {
#         if (yO) m3(yO); else d5.current = false
#       }, () => { d5.current = false })
#   }
#
# Fix: Change `!0` (true) to `!1` (false) in the guard assignment. This is a
# single byte change (0x30 -> 0x31). The guard stays false, so the title
# generator fires on every user message. The generator uses model inference
# to decide if the message warrants a new title, so repeated calls are harmless.
#
# Anchor: `.current=!0,` followed by `AbortController` within ~100 bytes
# uniquely identifies the title-gate guard (vs hundreds of other `.current=!0`
# occurrences in React code).
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

# --- Find pattern ---
# Strategy: search for `.current=!0,` and `.current=!1,` byte offsets, then
# check if `AbortController` appears within the next ~100 bytes. This
# distinguishes the title-gate guard from hundreds of other React ref
# assignments.

find_title_offsets() {
  local pattern="$1"
  local offsets=()
  while IFS=: read -r offset _; do
    offsets+=("$offset")
  done < <(grep -b -o -a "$pattern" "$BINARY" 2>/dev/null || true)

  local matches=()
  for offset in "${offsets[@]}"; do
    local context
    context=$(dd if="$BINARY" bs=1 skip="$offset" count=120 2>/dev/null | strings -n 5)
    if echo "$context" | grep -q 'AbortController'; then
      matches+=("$offset")
    fi
  done

  echo "${matches[@]}"
}

# Check if already patched
read -ra PATCHED <<< "$(find_title_offsets '.current=!1,')"

if [[ ${#PATCHED[@]} -gt 0 ]]; then
  echo "Status: patched (${#PATCHED[@]} occurrence(s))"
  [[ "$CHECK_ONLY" == true ]] && exit 0
  echo "Already patched — nothing to do"
  exit 0
fi

# Find unpatched pattern
read -ra UNPATCHED <<< "$(find_title_offsets '.current=!0,')"

if [[ ${#UNPATCHED[@]} -eq 0 ]]; then
  echo "Status: unknown"
  echo "ERROR: Could not find the expected code pattern in this binary." >&2
  echo "This version of Claude Code may not be compatible with this patch." >&2
  echo "Run with --check for details." >&2
  exit 1
fi

echo "Status: unpatched"
echo "Found ${#UNPATCHED[@]} title-gate occurrence(s)"

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
for offset in "${UNPATCHED[@]}"; do
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
