#!/usr/bin/env bash
# Claude Code status line:
#   repo/path, branch + worktree marker, PR │ model + effort │ context (+ cold cache)
#   │ plan limits │ cost │ session name
# The trailing segments drop off, least important first, when the terminal is narrow.
#
# Install: symlink to ~/.claude/statusline.sh, and in ~/.claude/settings.json set
#   "statusLine": { "type": "command", "command": "~/.claude/statusline.sh",
#                   "padding": 0, "refreshInterval": 10 }
input=$(cat)

# One jq pass. @sh quotes every value, so the eval is safe.
cwd='' model='' model_id='' effort='' fast='' size='' used='' pct='' cost='' name=''
pr_num='' pr_url='' pr_state='' h5_pct='' h5_reset='' d7_pct='' d7_reset='' cold='' recache=''
eval "$(jq -r '
  def i: if type == "number" then floor else "" end;
  @sh "cwd=\(.workspace.current_dir // .cwd // "")
model=\(.model.display_name // "")
model_id=\(.model.id // "")
effort=\(.effort.level // "")
fast=\(if .fast_mode == true then 1 else "" end)
size=\(.context_window.context_window_size | i)
used=\(.context_window.current_usage
       | if . == null then "" else
         (.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0) end)
pct=\(.context_window.used_percentage | i)
cost=\(.cost.total_cost_usd // "")
name=\(.session_name // "")
pr_num=\(.pr.number // "")
pr_url=\(.pr.url // "")
pr_state=\(.pr.review_state // "")
h5_pct=\(.rate_limits.five_hour.used_percentage | i)
h5_reset=\(.rate_limits.five_hour.resets_at | i)
d7_pct=\(.rate_limits.seven_day.used_percentage | i)
d7_reset=\(.rate_limits.seven_day.resets_at | i)
cold=\(.prompt_cache
       | if . == null or .caching_observed != true then ""
         elif .warm == false or ((.expires_at | type) == "number" and .expires_at <= now) then 1
         else "" end)
recache=\(.prompt_cache.recache_tokens_if_cold | i)"
' <<<"$input" 2>/dev/null)"
[ -z "$cwd" ] && cwd=$PWD

RESET=$'\e[0m'; DIM=$'\e[2m'; BOLD=$'\e[1m'
GREEN=$'\e[32m'; YELLOW=$'\e[33m'; RED=$'\e[31m'; CYAN=$'\e[36m'; MAGENTA=$'\e[35m'; BLUE=$'\e[94m'
SEP=" ${DIM}│${RESET} "

# Checkouts that must stay on main with nothing uncommitted (every session runs code from
# them). Colon-separated; off main or dirty there is shown in red.
GUARD_MAIN=${STATUSLINE_GUARD_MAIN:-$HOME/repos/workflow}

# --- location: repo name + path inside it, branch, worktree, dirty, PR ---
loc=""
if top=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null); then
  git_dir=$(git -C "$cwd" rev-parse --absolute-git-dir 2>/dev/null)
  common_dir=$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  main_root=$(dirname "$common_dir")
  repo=$(basename "$main_root")

  rel=${cwd#"$top"}; rel=${rel#/}
  branch=$(git -C "$cwd" symbolic-ref --short -q HEAD 2>/dev/null \
           || git -C "$cwd" rev-parse --short HEAD 2>/dev/null)
  dirty=$(git -C "$cwd" status --porcelain --untracked-files=no 2>/dev/null | head -n1)

  guarded=""
  if [ "$git_dir" = "$common_dir" ]; then
    case ":$GUARD_MAIN:" in *":$main_root:"*) guarded=1 ;; esac
  fi

  loc="${BOLD}${repo}${RESET}"
  if [ "$git_dir" != "$common_dir" ]; then
    # Linked worktree: show its folder name so parallel sessions are distinguishable.
    loc+=" ${MAGENTA}[wt:$(basename "$top")]${RESET}"
  fi
  [ -n "$rel" ] && loc+="${DIM}/${rel}${RESET}"
  if [ -n "$guarded" ] && [ "$branch" != main ]; then
    loc+=" "$'\e[41;97;1m'" ⎇ ${branch} ≠ main "${RESET}
  else
    loc+=" ${CYAN}⎇ ${branch}${RESET}"
  fi
  if [ -n "$dirty" ]; then
    if [ -n "$guarded" ]; then loc+=" ${RED}${BOLD}● dirty${RESET}"; else loc+=" ${YELLOW}●${RESET}"; fi
  fi

  if [ -n "$pr_num" ]; then
    pr="#${pr_num}"
    pr_url=${pr_url//[$'\e\a']/}
    # OSC 8 hyperlink: ctrl+click opens the PR.
    [ -n "$pr_url" ] && pr=$'\e]8;;'"${pr_url}"$'\e\\'"${pr}"$'\e]8;;\e\\'
    case $pr_state in
      approved)          pr="${GREEN}${pr} ✓${RESET}" ;;
      changes_requested) pr="${RED}${pr} ✗${RESET}" ;;
      pending)           pr="${YELLOW}${pr} ○${RESET}" ;;
      draft)             pr="${DIM}${pr} draft${RESET}" ;;
      *)                 pr="${CYAN}${pr}${RESET}" ;;
    esac
    loc+=" ${pr}"
  fi
else
  loc="${BOLD}${cwd/#$HOME/\~}${RESET}"
fi

# --- context usage ---
if [ -z "$pct" ] && [ -n "$used" ] && [ "${size:-0}" -gt 0 ]; then
  pct=$(( used * 100 / size ))
fi
if [ -z "$used" ] && [ -n "$pct" ] && [ "${size:-0}" -gt 0 ]; then
  used=$(( pct * size / 100 ))
fi

# 126400 -> 126k, 1000000 -> 1M
human() {
  local n=$1
  if   [ "$n" -ge 1000000 ]; then
    if [ $(( n % 1000000 )) -eq 0 ]; then echo "$(( n / 1000000 ))M"
    else printf '%d.%dM' $(( n / 1000000 )) $(( n % 1000000 / 100000 )); fi
  elif [ "$n" -ge 1000 ]; then echo "$(( n / 1000 ))k"
  else echo "$n"; fi
}

ctx=""
if [ -n "$pct" ]; then
  # Colour by absolute tokens, not percentage: quality degrades with raw context
  # length, so 200k is "red" on a 1M window too. Percentage only as a fallback.
  WARN_TOKENS=100000; DANGER_TOKENS=160000
  if [ -n "$used" ]; then
    level=0
    [ "$used" -ge "$WARN_TOKENS" ] && level=1
    [ "$used" -ge "$DANGER_TOKENS" ] && level=2
  else
    level=0
    [ "$pct" -ge 50 ] && level=1
    [ "$pct" -ge 80 ] && level=2
  fi
  case $level in
    2) fill=$'\e[41;97m'; c=$RED ;;
    1) fill=$'\e[43;30m'; c=$YELLOW ;;
    *) fill=$'\e[42;30m'; c=$GREEN ;;
  esac
  empty=$'\e[100;97m'

  # Token count rendered inside the bar; the filled part takes the colour.
  label="${pct}%"
  [ -n "$used" ] && label="$(human "$used")"
  [ -n "$used" ] && [ "${size:-0}" -gt 0 ] && label+="/$(human "$size")"
  width=16
  [ ${#label} -gt $(( width - 2 )) ] && width=$(( ${#label} + 2 ))
  lpad=$(( (width - ${#label}) / 2 ))
  text=$(printf '%*s%s%*s' "$lpad" '' "$label" $(( width - lpad - ${#label} )) '')
  # The bar fills toward DANGER_TOKENS, not the window: a full bar means "compact now",
  # whatever the window size. The window percentage follows it.
  if [ -n "$used" ]; then filled=$(( used * width / DANGER_TOKENS ))
  else filled=$(( pct * width / 100 )); fi
  [ "$filled" -gt "$width" ] && filled=$width

  bar="${fill}${text:0:filled}${empty}${text:filled}${RESET}"
  ctx="${c}ctx${RESET} ${bar}"
  [ -n "$used" ] && ctx+=" ${c}${pct}%${RESET}"
fi

# --- prompt cache: once it expires, the next turn re-writes the whole context ---
cache=""
if [ -n "$cold" ]; then
  cache="${BLUE}❄ cold"
  [ "${recache:-0}" -gt 0 ] && cache+=" $(human "$recache")"
  cache+="${RESET}"
fi

# --- plan limits: 5-hour and weekly usage, reset time once it matters ---
now=$(printf '%(%s)T' -1)
until_reset() {
  local s=$(( $1 - now ))
  [ "$s" -le 0 ] && return
  if   [ "$s" -ge 86400 ]; then printf '%dd%dh' $(( s / 86400 )) $(( s % 86400 / 3600 ))
  elif [ "$s" -ge 3600 ];  then printf '%dh%02dm' $(( s / 3600 )) $(( s % 3600 / 60 ))
  else printf '%dm' $(( s / 60 )); fi
}
limit() {  # label pct resets_at
  [ -z "$2" ] && return
  local c=$DIM t="$1 $2%"
  [ "$2" -ge 70 ] && c=$YELLOW
  [ "$2" -ge 90 ] && c=$RED
  if [ "$2" -ge 70 ] && [ -n "$3" ]; then
    local r; r=$(until_reset "$3"); [ -n "$r" ] && t+=" ↻${r}"
  fi
  printf '%s' "${c}${t}${RESET}"
}
h5=$(limit 5h "$h5_pct" "$h5_reset")
d7=$(limit 7d "$d7_pct" "$d7_reset")

# --- session cost (list-price estimate; notional on a subscription) ---
[ -n "$cost" ] && cost=$(printf '$%.2f' "$cost")

# --- model: Fable (orange) and Sonnet (magenta) are highlighted blocks; Opus is the plain default ---
[ -n "$model" ] && [ -n "$effort" ] && model+=" · ${effort}"
case "${model_id,,} ${model,,}" in
  " ")     ;;
  *fable*) model=$'\e[48;5;208;30;1m'" ◆ ${model} "${RESET} ;;  # orange block
  *sonnet*) model=$'\e[45;97;1m'" ▲ ${model} "${RESET} ;;  # magenta block: not the intended model
  *opus*)  model="${GREEN}${model}${RESET}" ;;
  *)       model="${DIM}${model}${RESET}" ;;
esac
[ -n "$fast" ] && model+=" ${YELLOW}${BOLD}↯ fast${RESET}"

# --- session name ---
if [ -n "$name" ]; then
  [ ${#name} -gt 28 ] && name="${name:0:27}…"
  name="${DIM}${name}${RESET}"
fi

# --- assemble, dropping the least important segments until it fits ---
visible_len() {
  local s
  s=$(sed -E $'s/\e\\]8;;[^\e]*\e\\\\//g; s/\e\\[[0-9;]*m//g' <<<"$1")
  echo ${#s}
}
render() {
  local out="$loc" lim=""
  [ -n "$model" ] && out+="${SEP}${model}"
  [ -n "$ctx" ] && out+="${SEP}${ctx}"
  [ -n "$cache" ] && out+=" ${cache}"
  [ -n "$h5" ] && lim="$h5"
  [ -n "$d7" ] && lim+="${lim:+ }$d7"
  [ -n "$lim" ] && out+="${SEP}${lim}"
  [ -n "$cost" ] && out+="${SEP}${cost}"
  [ -n "$name" ] && out+="${SEP}${name}"
  printf '%s' "$out"
}
out=$(render)
if [ "${COLUMNS:-0}" -gt 0 ]; then
  for drop in name cost d7 h5 cache; do
    [ "$(visible_len "$out")" -le $(( COLUMNS - 4 )) ] && break
    printf -v "$drop" '%s' ''
    out=$(render)
  done
fi
printf '%s' "$out"
