#!/usr/bin/env bash
# Claude Code Terminal Title Patch
#
# Bug: Auto-generated terminal titles never fire because the gate condition
# checks `messages.length <= 1`, but built-in attachment messages (skill
# listings, deferred tools, MCP instructions) inflate the count to >= 2
# before the first user query even hits the model.
#
# The title generation code (onBeforeQuery handler):
#
#   if (!disableTitle && !customTitle && !agentName && messages.length <= 1 &&
#       lastMsg?.type === "user" && typeof lastMsg.message.content === "string")
#     generateTitle(lastMsg.message.content).then(t => { if (t) setTitle(t) });
#
# Fix: Change `<=1` to `>=0` (same byte count). Since length is never
# negative, `>=0` is always true — effectively removing the gate. The
# generator itself checks if the message "indicates a new conversation
# topic" so repeated calls are harmless.
#
# The patch is overwritten on each Claude Code auto-update. Re-run after.
#
# Usage:
#   ./patch.sh                # patches whichever binary is on PATH
#   ./patch.sh /path/to/bin   # patches a specific binary

set -eo pipefail

if [[ $# -ge 1 ]]; then
  BINARY="$1"
else
  # Resolve the actual binary on PATH (follows symlinks)
  BINARY=$(command -v claude 2>/dev/null) || true
  if [[ -z "$BINARY" ]]; then
    echo "error: 'claude' not found on PATH" >&2
    exit 1
  fi
  # Resolve symlinks to the real file
  BINARY=$(readlink -f "$BINARY" 2>/dev/null || realpath "$BINARY" 2>/dev/null || echo "$BINARY")
fi

if [[ ! -f "$BINARY" ]]; then
  echo "error: binary not found: $BINARY" >&2
  exit 1
fi

echo "Binary: $BINARY"

# --- Find the pattern ---
# The minified variable names change between versions, so we search for the
# stable structural pattern: a `.length<=1` immediately followed by `&&`
# within the title generation gate. The unique surrounding context is that
# the same code block contains a `.then(` call to the title generator.
#
# Strategy:
#   1. Find all `.length<=1&&` byte offsets in the binary
#   2. For each, read ~200 bytes after it and check for `.then(` (the title
#      generator promise chain) — this distinguishes the title gate from the
#      30+ other `length<=1` occurrences

# Note: null bytes in Bun binaries break grep across long patterns, so we
# search for shorter anchors and validate context with dd + strings.

# --- Check if already patched ---
PATCHED_OFFSETS=()
while IFS=: read -r offset _; do
  PATCHED_OFFSETS+=("$offset")
done < <(grep -b -o -a 'length>=0' "$BINARY" 2>/dev/null || true)

PATCHED_TITLE=()
for offset in "${PATCHED_OFFSETS[@]}"; do
  context=$(dd if="$BINARY" bs=1 skip="$offset" count=200 2>/dev/null | strings -n 3)
  if echo "$context" | grep -q '\.then('; then
    PATCHED_TITLE+=("$offset")
  fi
done

if [[ ${#PATCHED_TITLE[@]} -gt 0 ]]; then
  echo "Already patched (${#PATCHED_TITLE[@]} occurrence(s)) — nothing to do"
  exit 0
fi

# --- Find unpatched pattern ---
OFFSETS=()
while IFS=: read -r offset _; do
  OFFSETS+=("$offset")
done < <(grep -b -o -a 'length<=1' "$BINARY" 2>/dev/null || true)

echo "Found ${#OFFSETS[@]} occurrences of length<=1"

if [[ ${#OFFSETS[@]} -eq 0 ]]; then
  echo "error: pattern not found — the code structure may have changed" >&2
  echo "Try: strings \"$BINARY\" | grep 'isNewTopic'" >&2
  echo "If that returns results, the title feature exists but the gate pattern changed." >&2
  exit 1
fi

# Filter to only the title-gate occurrences by checking for .then( nearby
TITLE_OFFSETS=()
for offset in "${OFFSETS[@]}"; do
  context=$(dd if="$BINARY" bs=1 skip="$offset" count=200 2>/dev/null | strings -n 3)
  if echo "$context" | grep -q '\.then('; then
    TITLE_OFFSETS+=("$offset")
  fi
done

echo "Filtered to ${#TITLE_OFFSETS[@]} title-gate occurrence(s)"

if [[ ${#TITLE_OFFSETS[@]} -eq 0 ]]; then
  echo "error: could not identify title-gate instances" >&2
  echo "Manual inspection needed. Run:" >&2
  echo "  strings \"$BINARY\" | grep 'length<=1'" >&2
  exit 1
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
for offset in "${TITLE_OFFSETS[@]}"; do
  patch_offset=$((offset + 6))  # skip "length" (6 bytes) to reach "<=1"

  # Verify we're patching the right bytes
  current_hex=$(dd if="$BINARY" bs=1 skip="$patch_offset" count=3 2>/dev/null | xxd -p)
  if [[ "$current_hex" != "3c3d31" ]]; then
    echo "warning: unexpected bytes at offset $patch_offset: $current_hex (expected 3c3d31), skipping" >&2
    continue
  fi

  printf '\x3e\x3d\x30' | dd of="$BINARY" bs=1 seek="$patch_offset" conv=notrunc 2>/dev/null
  echo "Patched offset $patch_offset: <=1 -> >=0"
done

# --- Re-sign (required on macOS arm64) ---
if [[ "$(uname -s)" == "Darwin" ]]; then
  codesign --sign - --force "$BINARY" 2>/dev/null
  echo "Re-signed binary"
fi

echo "Done. Restart Claude Code for the patch to take effect."
