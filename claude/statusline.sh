#!/usr/bin/env bash
#
# statusline.sh — Claude Code statusline: Caveman badge + usage/rate limits.
#
# Renders (left to right):
#   1. the Caveman plugin badge (if the plugin is installed + active), then
#   2. the active model name and the current usage / rate limits:
#        Kontext <u>k/<max> · <n>%  -> context-window fill (context_window.*)
#        Sitzung <n>%        -> rolling 5-hour window   (rate_limits.five_hour)
#        Woche   <n>%        -> weekly / 7-day window    (rate_limits.seven_day)
#
# The rate_limits.* fields are only present for Claude.ai Pro/Max subscribers
# and only AFTER the first API response of a session — until then this just
# shows the badge + model, which is expected.
#
# Install: copy this file to ~/.claude/statusline.sh, `chmod +x` it, and point
# statusLine.command in ~/.claude/settings.json at it (see the README section
# "Claude Code usage statusline").
#
# ~/.claude is bind-mounted into every DevContainer by spawn-workspace.sh (host
# ~/.claude -> /home/vscode/.claude), so the same statusline is active on the
# host and inside every story container. The one runtime dependency is `jq`;
# the DevContainer image installs it. Without jq the script still renders the
# badge + model and degrades gracefully (no rate limits).

CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

# Read the statusline JSON payload from stdin exactly once.
input="$(cat)"

# Opt-in diagnostics: with STATUSLINE_DEBUG=1 the latest raw payload is written
# to ~/.claude/.statusline-input.json so the exact schema can be inspected.
# Off by default — the payload includes session cost/transcript paths and there
# is no need to write it on every render.
if [ "${STATUSLINE_DEBUG:-0}" = "1" ]; then
  printf '%s' "$input" > "$CONFIG_DIR/.statusline-input.json" 2>/dev/null || true
fi

out=""

# --- 1. Caveman badge -------------------------------------------------------
# Discover the plugin's statusline script by glob (newest match) instead of a
# hard-coded cache hash, so it survives plugin updates. The script reads its
# own flag files, not stdin, so it needs no input piped in.
cave="$(ls -t "$CONFIG_DIR"/plugins/cache/caveman/caveman/*/hooks/caveman-statusline.sh 2>/dev/null | head -1)"
if [ -n "$cave" ] && [ -f "$cave" ]; then
  badge="$(bash "$cave" 2>/dev/null)"
  [ -n "$badge" ] && out="$badge"
fi

# --- 2. Model + rate limits (needs jq) --------------------------------------
if command -v jq >/dev/null 2>&1; then
  model="$(printf '%s' "$input" | jq -r '.model.display_name // empty' 2>/dev/null)"
  # Round to a whole percent inside jq — bash 3.2's printf %f is locale-fragile.
  five="$(printf '%s' "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty | numbers | round' 2>/dev/null)"
  week="$(printf '%s' "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty | numbers | round' 2>/dev/null)"

  # Context-window fill: tokens currently in context vs. the model's limit,
  # e.g. "Kontext 250k/1M · 25%". context_window.* is sent from Claude Code 2.x;
  # the token counts are null/absent before the first API response and right
  # after /compact, so fall back to 0. The limit renders as "1M" for the
  # extended-context models and "<n>k" otherwise. If context_window is missing
  # entirely (older CC), ctx_size is empty and the segment is simply omitted.
  ctx_used="$(printf '%s' "$input" | jq -r '((.context_window.total_input_tokens // 0) + (.context_window.total_output_tokens // 0)) | floor' 2>/dev/null)"
  ctx_size="$(printf '%s' "$input" | jq -r '.context_window.context_window_size // empty' 2>/dev/null)"
  ctx=""
  if [ -n "$ctx_size" ] && [ "$ctx_size" -gt 0 ] 2>/dev/null; then
    if [ "$ctx_size" -ge 1000000 ]; then ctx_total="$((ctx_size / 1000000))M"; else ctx_total="$((ctx_size / 1000))k"; fi
    ctx_used="${ctx_used:-0}"
    # Percent from the SAME token total shown as k/k, so "250k/1M" and "25%" agree
    # (Claude Code's own context_window.used_percentage is input-only and would
    # not quite match). Integer math is enough for a status line.
    ctx_pct=$(( ctx_used * 100 / ctx_size ))
    ctx="Kontext $(( ctx_used / 1000 ))k/${ctx_total} · ${ctx_pct}%"
  fi

  seg=""
  [ -n "$model" ] && seg="$model"
  [ -n "$ctx" ] && seg="${seg:+$seg | }$ctx"
  [ -n "$five" ] && seg="${seg:+$seg | }Sitzung ${five}%"
  [ -n "$week" ] && seg="${seg:+$seg | }Woche ${week}%"

  if [ -n "$seg" ]; then
    # Dim grey so the badge stays the visual anchor.
    seg="$(printf '\033[38;5;245m%s\033[0m' "$seg")"
    out="${out:+$out  }$seg"
  fi
fi

printf '%s' "$out"
