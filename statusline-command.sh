#!/bin/bash
# Claude Code status line: colorful emoji-rich status, three rows.
#   row 1 — session:   model, effort, thinking, session name, output style, vim, agent
#   row 2 — workspace: branch, repo, PR, worktree
#   row 3 — meters:    context bar, 5h/7d rate limits, session cost
# Each printed line produces one row in the status area.

input=$(cat)

model=$(echo "$input" | jq -r '.model.display_name // "Claude"')
cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // empty')
session_name=$(echo "$input" | jq -r '.session_name // empty')
effort=$(echo "$input" | jq -r '.effort.level // empty')
thinking=$(echo "$input" | jq -r '.thinking.enabled // empty')
output_style=$(echo "$input" | jq -r '.output_style.name // empty')
vim_mode=$(echo "$input" | jq -r '.vim.mode // empty')
agent_name=$(echo "$input" | jq -r '.agent.name // empty')
worktree_name=$(echo "$input" | jq -r '.worktree.name // empty')

used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
five_hour=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
five_hour_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
weekly=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
weekly_reset=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')

cost=$(echo "$input" | jq -r '.cost.total_cost_usd // empty')

repo_owner=$(echo "$input" | jq -r '.workspace.repo.owner // empty')
repo_name=$(echo "$input" | jq -r '.workspace.repo.name // empty')
pr_number=$(echo "$input" | jq -r '.pr.number // empty')
pr_state=$(echo "$input" | jq -r '.pr.review_state // empty')

# Colors
RESET='\033[0m'
CYAN='\033[36m'
MAGENTA='\033[35m'
BLUE='\033[34m'
GRAY='\033[90m'
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'

color_for_pct() {
  local pct="$1"
  if [ "$pct" -ge 80 ]; then echo "$RED"
  elif [ "$pct" -ge 50 ]; then echo "$YELLOW"
  else echo "$GREEN"
  fi
}

fmt_time() {
  # $1 = unix epoch seconds -> local HH:MM (macOS/BSD date)
  local epoch="$1"
  [ -z "$epoch" ] && return
  date -r "$epoch" "+%H:%M" 2>/dev/null
}

clamp_pct() {
  # $1 = float percentage -> integer 0..100
  local n
  n=$(printf '%.0f' "$1")
  [ "$n" -lt 0 ] && n=0
  [ "$n" -gt 100 ] && n=100
  echo "$n"
}

bar_width=10
build_bar() {
  local pct="$1"
  local filled empty bar i
  filled=$(( pct * bar_width / 100 ))
  empty=$(( bar_width - filled ))
  bar=""
  i=0
  while [ "$i" -lt "$filled" ]; do bar="${bar}█"; i=$((i + 1)); done
  i=0
  while [ "$i" -lt "$empty" ]; do bar="${bar}░"; i=$((i + 1)); done
  echo "$bar"
}

sep=$(printf ' %b|%b ' "$GRAY" "$RESET")
join_parts() {
  # joins its arguments with the gray pipe separator
  local out="" first=true p
  for p in "$@"; do
    if $first; then out="$p"; first=false; else out="${out}${sep}${p}"; fi
  done
  printf '%s' "$out"
}

# ---------- Row 1: session ----------
row1=()

row1+=("$(printf '%b🤖 %s%b' "$CYAN" "$model" "$RESET")")

# Reasoning effort (absent on models without the effort parameter)
if [ -n "$effort" ]; then
  case "$effort" in
    max|xhigh) effort_color="$RED" ;;
    high)      effort_color="$YELLOW" ;;
    *)         effort_color="$GREEN" ;;
  esac
  row1+=("$(printf '%b🧠 %s%b' "$effort_color" "$effort" "$RESET")")
fi

# Extended thinking, only when on
[ "$thinking" = "true" ] && row1+=("$(printf '%b💭 think%b' "$MAGENTA" "$RESET")")

# Session name (custom via --name / rename, or AI-generated title)
[ -n "$session_name" ] && row1+=("$(printf '%b🏷️ %s%b' "$BLUE" "$session_name" "$RESET")")

# Output style, when not default
if [ -n "$output_style" ] && [ "$output_style" != "default" ]; then
  row1+=("$(printf '%b🎨 %s%b' "$GRAY" "$output_style" "$RESET")")
fi

[ -n "$vim_mode" ] && row1+=("$(printf '%b⌨️ %s%b' "$GRAY" "$vim_mode" "$RESET")")
[ -n "$agent_name" ] && row1+=("$(printf '%b🕵️ %s%b' "$BLUE" "$agent_name" "$RESET")")

# ---------- Row 2: workspace ----------
row2=()

# Git branch (skip optional locks so we never fight a concurrent git process)
if [ -n "$cwd" ] && git --no-optional-locks -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch=$(git --no-optional-locks -C "$cwd" branch --show-current 2>/dev/null)
  [ -n "$branch" ] && row2+=("$(printf '%b🌿 %s%b' "$MAGENTA" "$branch" "$RESET")")
fi

if [ -n "$repo_owner" ] && [ -n "$repo_name" ]; then
  row2+=("$(printf '%b📦 %s/%s%b' "$BLUE" "$repo_owner" "$repo_name" "$RESET")")
fi

if [ -n "$pr_number" ]; then
  case "$pr_state" in
    approved)          pr_color="$GREEN"; pr_icon="✅" ;;
    changes_requested) pr_color="$RED";   pr_icon="🚧" ;;
    draft)             pr_color="$GRAY";  pr_icon="📝" ;;
    *)                 pr_color="$YELLOW"; pr_icon="🔀" ;;
  esac
  row2+=("$(printf '%b%s PR#%s%b' "$pr_color" "$pr_icon" "$pr_number" "$RESET")")
fi

[ -n "$worktree_name" ] && row2+=("$(printf '%b🌳 %s%b' "$BLUE" "$worktree_name" "$RESET")")

# ---------- Row 3: meters ----------
row3=()

# Context window usage
if [ -n "$used" ]; then
  used_int=$(clamp_pct "$used")
  row3+=("$(printf '%b📊 [%s] %s%%%b' "$(color_for_pct "$used_int")" "$(build_bar "$used_int")" "$used_int" "$RESET")")
fi

# 5-hour rate limit (all models combined)
if [ -n "$five_hour" ]; then
  five_int=$(clamp_pct "$five_hour")
  reset_str=$(fmt_time "$five_hour_reset")
  if [ -n "$reset_str" ]; then
    row3+=("$(printf '%b⏱️ 5h %s%% (→%s)%b' "$(color_for_pct "$five_int")" "$five_int" "$reset_str" "$RESET")")
  else
    row3+=("$(printf '%b⏱️ 5h %s%%%b' "$(color_for_pct "$five_int")" "$five_int" "$RESET")")
  fi
fi

# 7-day rate limit (all models combined)
if [ -n "$weekly" ]; then
  weekly_int=$(clamp_pct "$weekly")
  reset_str=$(fmt_time "$weekly_reset")
  if [ -n "$reset_str" ]; then
    row3+=("$(printf '%b📅 7d %s%% (→%s)%b' "$(color_for_pct "$weekly_int")" "$weekly_int" "$reset_str" "$RESET")")
  else
    row3+=("$(printf '%b📅 7d %s%%%b' "$(color_for_pct "$weekly_int")" "$weekly_int" "$RESET")")
  fi
fi

# Estimated session cost (client-side estimate, resets on /clear)
if [ -n "$cost" ]; then
  row3+=("$(printf '%b💰 $%.2f%b' "$GRAY" "$cost" "$RESET")")
fi

[ ${#row1[@]} -gt 0 ] && printf '%b\n' "$(join_parts "${row1[@]}")"
[ ${#row2[@]} -gt 0 ] && printf '%b\n' "$(join_parts "${row2[@]}")"
[ ${#row3[@]} -gt 0 ] && printf '%b\n' "$(join_parts "${row3[@]}")"

exit 0
