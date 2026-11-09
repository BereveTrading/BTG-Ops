#!/usr/bin/env bash
# BTG level-up loop — one run.
#   7 read-only reviewer agents (serial) -> 1 merge agent -> (only with --build) up to
#   --max-builders builder agents that each open ONE draft PR.
# The loop never merges, deploys, restarts a unit/container, writes to the DB or changes prod.
# See README.md. Settings: level-up.conf.
set -Eeuo pipefail
umask 027

# ---------- lowest CPU + IO priority for the whole run (and every agent it starts) ----------
if [[ -z "${LEVELUP_NICED:-}" ]]; then
  export LEVELUP_NICED=1
  if command -v ionice >/dev/null 2>&1; then
    exec nice -n 19 ionice -c 3 "$0" "$@"
  fi
  exec nice -n 19 "$0" "$@"
fi

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CONF="${LEVELUP_CONF:-$HERE/level-up.conf}"
MARKER='<!-- level-up: complete -->'

usage() {
  cat <<'EOF'
Usage: run.sh [options]
  --dry-run            Print what would run. Starts no agent, writes nothing, spends nothing.
  --lens NAME          Run one reviewer only (technical visual competitive engine zed-render systems data). No merge.
  --build              After the merge, run builders for lanes marked Size S + Class bug + Ruling needed: no.
  --max-builders N     Cap builders per run (default from level-up.conf, 2).
  --notify             Send ZEN a short Telegram notice (send-only script) when the run ends.
  --date YYYY-MM-DD    Run folder date (default: today UTC). Same date = resume that run.
  --run-dir PATH       Use this run folder instead of <reviews>/level-up-<date> (tests).
  --show-prompt        With --dry-run: print the rendered prompts too.
  --smoke              One trivial headless call ("reply OK") with the real argv; prints the JSON.
  -h, --help
Exit: 0 done or nothing to do / another run active, 2 refused (bad option or config), 3 stopped early (load, budget, too few lenses), 1 error.
EOF
}

die()  { echo "level-up: $*" >&2; exit 2; }

DRY=0 BUILD=0 NOTIFY=0 SMOKE=0 SHOW_PROMPT=0
ONLY_LENS="" MAXB_ARG="" RUN_DIR_ARG="" DATE_ARG=""
while (($#)); do
  case "$1" in
    --dry-run) DRY=1 ;;
    --build) BUILD=1 ;;
    --notify) NOTIFY=1 ;;
    --smoke) SMOKE=1 ;;
    --show-prompt) SHOW_PROMPT=1 ;;
    --lens) ONLY_LENS="${2:?--lens needs a name}"; shift ;;
    --max-builders) MAXB_ARG="${2:?--max-builders needs a number}"; shift ;;
    --run-dir) RUN_DIR_ARG="${2:?--run-dir needs a path}"; shift ;;
    --date) DATE_ARG="${2:?--date needs YYYY-MM-DD}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
  shift
done

[[ -r "$CONF" ]] || die "config not readable: $CONF"
# shellcheck source=level-up.conf
source "$CONF"
[[ -n "$MAXB_ARG" ]] && MAX_BUILDERS="$MAXB_ARG"

# ---------- config guards ----------
is_num()  { [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]; }
is_int()  { [[ "$1" =~ ^[0-9]+$ ]]; }
model_ok() {
  local m="${1,,}"
  [[ "$m" == *fable* ]] && return 1
  [[ "$m" =~ ^(opus|sonnet|haiku|claude-(opus|sonnet|haiku)-[a-z0-9.-]+)$ ]]
}
model_ok "$MODEL" || die "refused model '$MODEL': must be opus-class or cheaper, never fable (ZEN 11-02)"
[[ -z "$FALLBACK_MODEL" ]] || model_ok "$FALLBACK_MODEL" || die "refused fallback model '$FALLBACK_MODEL'"
[[ "${FALLBACK_MODEL,,}" != "${MODEL,,}" ]] || FALLBACK_MODEL=""
case "$PERMISSION_MODE" in auto|dontAsk|acceptEdits|plan) ;; *) die "refused permission mode '$PERMISSION_MODE' (allowed: auto dontAsk acceptEdits plan)";; esac
for v in REVIEWER_BUDGET_USD MERGE_BUDGET_USD BUILDER_BUDGET_USD RUN_BUDGET_USD MAX_LOAD1; do
  is_num "${!v}" || die "$v must be a number, got '${!v}'"
done
for v in MAX_BUILDERS MIN_LENSES LOAD_WAIT_MIN; do
  is_int "${!v}" || die "$v must be a whole number, got '${!v}'"
done
[[ -x "$CLAUDE_BIN" ]] || die "claude CLI not executable: $CLAUDE_BIN"
read -r -a LENS_LIST <<<"$LENSES"
for l in "${LENS_LIST[@]}"; do [[ -r "$HERE/briefs/$l.md" ]] || die "missing brief: briefs/$l.md"; done
for f in _common merge builder; do [[ -r "$HERE/briefs/$f.md" ]] || die "missing brief: briefs/$f.md"; done
if [[ -n "$ONLY_LENS" ]]; then
  printf '%s\n' "${LENS_LIST[@]}" | grep -qxF -- "$ONLY_LENS" || die "unknown lens '$ONLY_LENS' (known: ${LENS_LIST[*]})"
  LENS_LIST=("$ONLY_LENS")
fi

DATE="${DATE_ARG:-$(date -u +%F)}"
[[ "$DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "bad --date '$DATE'"
RUN_DIR="${RUN_DIR_ARG:-$REVIEWS_ROOT/level-up-$DATE}"
RUN_LOG_DIR="$RUN_DIR/run"

# ---------- hard backstop deny lists (the auto-mode classifier + the brief are the first line) ----------
# Prefix rules only match the start of a command; they are a backstop, not a sandbox.
COMMON_DENY=(
  "Agent" "Task"
  "Bash(pkill:*)" "Bash(killall:*)" "Bash(kill:*)" "Bash(sudo:*)"
  "Bash(systemctl --user start:*)" "Bash(systemctl --user stop:*)" "Bash(systemctl --user restart:*)"
  "Bash(systemctl --user reload:*)" "Bash(systemctl --user enable:*)" "Bash(systemctl --user disable:*)"
  "Bash(systemctl --user daemon-reload:*)" "Bash(systemctl --user kill:*)" "Bash(systemctl --user mask:*)"
  "Bash(systemctl start:*)" "Bash(systemctl stop:*)" "Bash(systemctl restart:*)"
  "Bash(docker start:*)" "Bash(docker stop:*)" "Bash(docker restart:*)" "Bash(docker kill:*)"
  "Bash(docker rm:*)" "Bash(docker rmi:*)" "Bash(docker run:*)" "Bash(docker exec:*)" "Bash(docker build:*)"
  "Bash(docker pull:*)" "Bash(docker compose:*)" "Bash(docker-compose:*)" "Bash(docker system prune:*)"
  "Bash(docker image prune:*)" "Bash(docker volume rm:*)" "Bash(docker update:*)"
  "Bash(gh pr merge:*)" "Bash(gh pr ready:*)" "Bash(gh api:*)" "Bash(gh release:*)"
  "Bash(git push --force:*)" "Bash(git push -f:*)" "Bash(git push origin main:*)" "Bash(git push origin HEAD:main:*)"
  "Bash(*getUpdates*)" "Bash(*api.telegram.org*)" "Bash(*discord.com/api*)" "Bash(*discordapp.com/api*)"
  "Bash(*tg-text.sh*)" "Bash(*tg-send.sh*)"
  "Bash(*refresh_continuous_aggregate*)" "Bash(*run_job*)" "Bash(*vision-prod-deploy*)"
  "WebFetch(domain:api.telegram.org)" "WebFetch(domain:discord.com)" "WebFetch(domain:discordapp.com)"
  "Edit(//home/dean/.config/systemd/**)" "Edit(//home/dean/.claude/**)" "Edit(//home/dean/btg/state/**)"
)
REVIEWER_DENY=(
  "${COMMON_DENY[@]}"
  "Bash(git push:*)" "Bash(git commit:*)" "Bash(git checkout:*)" "Bash(git switch:*)" "Bash(git reset:*)"
  "Bash(git stash:*)" "Bash(git rebase:*)" "Bash(git merge:*)" "Bash(git worktree add:*)" "Bash(git worktree remove:*)"
  "Bash(gh pr create:*)" "Bash(npm install:*)" "Bash(npm ci:*)" "Bash(pnpm install:*)" "Bash(yarn install:*)"
  "Edit(//home/dean/btg/BTG-*/**)" "Edit(//home/dean/btg/wt/**)"
)
BUILDER_DENY=( "${COMMON_DENY[@]}" "Bash(git checkout main:*)" "Bash(git switch main:*)" "Bash(git rebase:*)" )

# ---------- helpers ----------
log() {
  local line; line="$(date -u +%FT%TZ) $*"
  echo "$line"
  if ((DRY == 0)) && [[ -d "$RUN_LOG_DIR" ]]; then echo "$line" >>"$RUN_LOG_DIR/run.log"; fi
}
load1() { cut -d' ' -f1 /proc/loadavg; }
load_ok() { awk -v l="$(load1)" -v m="$MAX_LOAD1" 'BEGIN{exit !(l <= m)}'; }
wait_for_load() {   # returns 0 when load is fine, 1 when we gave up
  local waited=0
  while ! load_ok; do
    if ((DRY)); then log "load1 $(load1) > $MAX_LOAD1: a real run would wait up to ${LOAD_WAIT_MIN} min, then stop"; return 0; fi
    if ((waited >= LOAD_WAIT_MIN)); then log "load1 $(load1) > $MAX_LOAD1 after ${waited} min: stopping (resumable)"; return 1; fi
    log "load1 $(load1) > $MAX_LOAD1: waiting 5 min (${waited}/${LOAD_WAIT_MIN})"
    sleep 300; waited=$((waited + 5))
  done
  return 0
}
is_complete() { [[ -s "$1" ]] && tail -n 5 "$1" | grep -qxF -- "$MARKER"; }
fadd() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.4f", a + b}'; }
fmin() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.2f", (a < b ? a : b)}'; }
fgt()  { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a > b)}'; }

SPENT=0
STOP_REASON=""
read_spent() {   # resume: costs already charged to this run folder
  if [[ -s "$RUN_LOG_DIR/costs.tsv" ]]; then
    SPENT="$(awk -F'\t' 'NR>1 && $6 != "" {s += $6} END{printf "%.4f", s + 0}' "$RUN_LOG_DIR/costs.tsv")"
  fi
}

prod_sha() {
  local s
  s="$(curl -s --max-time 5 "$READY_URL" 2>/dev/null | jq -r '.buildSha // empty' 2>/dev/null || true)"
  [[ "$s" =~ ^[0-9a-f]{7,40}$ ]] && echo "${s:0:9}" || echo "unknown (ready probe failed)"
}
main_wt() {
  local w
  w="$(git -C /home/dean/btg/BTG-Rebuild worktree list 2>/dev/null | awk '/\[main\]$/{print $1 " at " $2; exit}')"
  echo "${w:-unknown}"
}
prev_review() {
  local d best=""
  for d in "$REVIEWS_ROOT"/level-up-*/; do
    [[ -d "$d" ]] || continue
    d="${d%/}"
    [[ "$d" == "${RUN_DIR%/}" ]] && continue
    [[ "$(basename "$d")" < "level-up-$DATE" ]] || continue
    is_complete "$d/REVIEW.md" && best="$d/REVIEW.md"
  done
  if [[ -n "$best" ]]; then echo "$best"
  elif [[ -s "$PREV_REVIEW_SEED" ]]; then echo "$PREV_REVIEW_SEED"
  else echo "none"; fi
}

# render <template> [KEY=VALUE ...] -> stdout. Fails if a {PLACEHOLDER} is left.
render() {
  local tpl="$1"; shift
  local text kv k v
  text="$(cat "$HERE/briefs/_common.md" "$HERE/briefs/$tpl.md")"
  for kv in "LANE_DIR=$RUN_DIR" "DATE=$DATE" "PROD_SHA=$PROD_SHA" "MAIN_WT=$MAIN_WT" "PREV_REVIEW=$PREV_REVIEW" "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    text="${text//"{$k}"/"$v"}"
  done
  if grep -qE '\{[A-Z][A-Z_]+\}' <<<"$text"; then
    echo "level-up: unresolved placeholder in $tpl: $(grep -oE '\{[A-Z][A-Z_]+\}' <<<"$text" | sort -u | tr '\n' ' ')" >&2
    return 1
  fi
  printf '%s\n' "$text"
}

# run_agent NAME KIND(reviewer|merge|builder) CWD BUDGET TIMEOUT PROMPT_FILE [extra claude args...]
# Returns 0 if the agent ran (whatever its result), 1 if the run must stop (budget/load).
run_agent() {
  local name="$1" kind="$2" cwd="$3" budget="$4" tmo="$5" prompt="$6"; shift 6
  local -a deny argv
  case "$kind" in builder) deny=("${BUILDER_DENY[@]}") ;; *) deny=("${REVIEWER_DENY[@]}") ;; esac
  local left cap
  left="$(awk -v r="$RUN_BUDGET_USD" -v s="$SPENT" 'BEGIN{printf "%.2f", r - s}')"
  if ! fgt "$left" 0.5; then STOP_REASON="run budget reached (spent \$$SPENT of \$$RUN_BUDGET_USD)"; log "STOP: $STOP_REASON"; return 1; fi
  cap="$(fmin "$budget" "$left")"
  wait_for_load || { STOP_REASON="load above $MAX_LOAD1"; return 1; }
  argv=("$CLAUDE_BIN" -p --model "$MODEL" --output-format json --no-session-persistence
        --permission-mode "$PERMISSION_MODE" --max-budget-usd "$cap")
  [[ -n "$FALLBACK_MODEL" ]] && argv+=(--fallback-model "$FALLBACK_MODEL")
  argv+=("$@")
  if ((DRY)); then
    log "WOULD RUN $name ($kind) cwd=$cwd cap=\$$cap timeout=$tmo"
    printf '   '; printf ' %q' timeout --kill-after=60s "$tmo" "${argv[@]}"; echo " --disallowed-tools <${#deny[@]} rules> < prompt"
    return 0
  fi
  argv+=(--disallowed-tools "${deny[@]}")
  local out="$RUN_LOG_DIR/$name.json" err="$RUN_LOG_DIR/$name.stderr.log" rc=0 t0 t1
  log "START $name ($kind) cap=\$$cap timeout=$tmo"
  t0=$(date +%s)
  ( cd "$cwd" && exec timeout --kill-after=60s "$tmo" "${argv[@]}" ) <"$prompt" >"$out" 2>"$err" || rc=$?
  t1=$(date +%s)
  local cost subtype in_t out_t cr_t cc_t
  if jq -e . "$out" >/dev/null 2>&1; then
    cost="$(jq -r '.total_cost_usd // 0' "$out")"
    subtype="$(jq -r '.subtype // "?"' "$out")"
    in_t="$(jq -r '.usage.input_tokens // 0' "$out")"; out_t="$(jq -r '.usage.output_tokens // 0' "$out")"
    cr_t="$(jq -r '.usage.cache_read_input_tokens // 0' "$out")"; cc_t="$(jq -r '.usage.cache_creation_input_tokens // 0' "$out")"
  else
    # No result JSON (timeout kill or crash): charge the full cap so the run budget stays honest.
    cost="$cap"; subtype="no-result"; in_t=0; out_t=0; cr_t=0; cc_t=0
  fi
  [[ -s "$RUN_LOG_DIR/costs.tsv" ]] || printf 'utc\tagent\tkind\trc\tsubtype\tcost_usd\tcap_usd\tseconds\tinput_tok\toutput_tok\tcache_read_tok\tcache_create_tok\n' >"$RUN_LOG_DIR/costs.tsv"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$name" "$kind" "$rc" "$subtype" "$cost" "$cap" \
    "$((t1 - t0))" "$in_t" "$out_t" "$cr_t" "$cc_t" >>"$RUN_LOG_DIR/costs.tsv"
  SPENT="$(fadd "$SPENT" "$cost")"
  log "END $name rc=$rc subtype=$subtype cost=\$$cost spent=\$$SPENT secs=$((t1 - t0))"
  return 0
}

# BUILDER.md -> TSV: id size class ruling repo title
parse_lanes() {
  awk '
    function val(s) { sub(/^-[ \t]*[A-Za-z ]+:[ \t]*/, "", s); gsub(/[ \t\r]+$/, "", s); return s }
    function flush() { if (id != "") printf "%s\t%s\t%s\t%s\t%s\t%s\n", id, tolower(size), tolower(cls), tolower(rul), repo, title; id = "" }
    /^## Lane L[0-9]+/ { flush(); match($0, /L[0-9]+/); id = substr($0, RSTART, RLENGTH)
                         title = $0; sub(/^## Lane L[0-9]+/, "", title); sub(/^[^A-Za-z0-9]+/, "", title)
                         size = cls = rul = repo = ""; next }
    /^## / { flush(); next }
    id != "" && /^- Size:/          { size = val($0) }
    id != "" && /^- Class:/         { cls = val($0) }
    id != "" && /^- Ruling needed:/ { rul = val($0) }
    id != "" && /^- Repo:/          { repo = val($0) }
    END { flush() }
  ' "$1"
}
lane_text() {  # lane_text FILE ID -> the lane block
  awk -v id="$2" '
    /^## / { inl = ($0 ~ ("^## Lane " id "([^0-9]|$)")) }
    inl { print }
  ' "$1"
}

show_path() { local p="$1"; [[ "$p" == "$HOME"/* ]] && p="~/${p#"$HOME"/}"; echo "$p"; }   # ~ form: short on a phone, no user name
notify() {   # notify "message"
  local msg="$1"
  if grep -qiw 'dean' <<<"$msg"; then log "notify REFUSED: message contains the owner's real name"; return 0; fi
  if ((DRY)); then log "WOULD NOTIFY via $NOTIFY_BIN:"; sed 's/^/    | /' <<<"$msg"; return 0; fi
  [[ -x "$NOTIFY_BIN" ]] || { log "notify skipped: $NOTIFY_BIN not executable"; return 0; }
  if "$NOTIFY_BIN" "$msg"; then log "notify sent"; : >"$RUN_LOG_DIR/notified"; else log "notify FAILED (one attempt, no retry)"; fi
}
notify_stop() {
  ((NOTIFY)) || return 0
  [[ -e "$RUN_LOG_DIR/notified" ]] && return 0
  notify "ZEN, the level-up run for $DATE stopped early.
Reason: $1.
It will resume from where it stopped on the next run.
Folder: $(show_path "$RUN_DIR")"
}

# ---------- smoke ----------
if ((SMOKE)); then
  mkdir -p "$STATE_DIR"
  sm_out="$STATE_DIR/smoke-$(date -u +%Y%m%dT%H%M%SZ).json"
  sm_argv=("$CLAUDE_BIN" -p --model "$MODEL" --output-format json --no-session-persistence
           --permission-mode "$PERMISSION_MODE" --max-budget-usd 0.50)
  [[ -n "$FALLBACK_MODEL" ]] && sm_argv+=(--fallback-model "$FALLBACK_MODEL")
  sm_argv+=(--disallowed-tools "${REVIEWER_DENY[@]}")
  rc=0
  ( cd "$STATE_DIR" && TMPDIR="$STATE_DIR" exec timeout --kill-after=10s 180s "${sm_argv[@]}" ) \
    <<<"Reply with exactly the two letters OK and nothing else. Do not use any tool." >"$sm_out" 2>"$sm_out.stderr" || rc=$?
  echo "rc=$rc  json=$sm_out"
  cat "$sm_out"; echo
  [[ -s "$sm_out.stderr" ]] && { echo "--- stderr ---"; cat "$sm_out.stderr"; }
  exit "$rc"
fi

# ---------- lock (one run at a time) ----------
if ((DRY)); then
  if [[ -e "$STATE_DIR/run.lock" ]] && ! flock -n "$STATE_DIR/run.lock" true 2>/dev/null; then
    echo "lock: HELD by another run ($STATE_DIR/run.lock) — a real run would exit 0 now"
  else
    echo "lock: free ($STATE_DIR/run.lock)"
  fi
else
  mkdir -p "$STATE_DIR"
  exec 9>"$STATE_DIR/run.lock"
  if ! flock -n 9; then echo "level-up: another run holds $STATE_DIR/run.lock; exiting" >&2; exit 0; fi
fi

# ---------- run setup ----------
PROD_SHA="$(prod_sha)"
MAIN_WT="$(main_wt)"
PREV_REVIEW="$(prev_review)"
if ((DRY == 0)); then
  mkdir -p "$RUN_DIR"/{evidence,captures,build,run/prompts,.tmp}
  export TMPDIR="$RUN_DIR/.tmp" CLAUDE_CODE_TMPDIR="$RUN_DIR/.tmp"
  read_spent
fi
log "level-up run: date=$DATE dir=$RUN_DIR model=$MODEL fallback=${FALLBACK_MODEL:-none} mode=$PERMISSION_MODE"
log "prod=$PROD_SHA main=$MAIN_WT prev=$PREV_REVIEW load1=$(load1) max_load1=$MAX_LOAD1"
log "budget: reviewer \$$REVIEWER_BUDGET_USD merge \$$MERGE_BUDGET_USD builder \$$BUILDER_BUDGET_USD run \$$RUN_BUDGET_USD (spent so far \$$SPENT)"
log "flags: dry=$DRY lens=${ONLY_LENS:-all} build=$BUILD max_builders=$MAX_BUILDERS notify=$NOTIFY"

stage_prompt() {  # stage_prompt NAME TEMPLATE [KEY=VALUE...] -> path of the prompt file (or - in dry-run)
  local name="$1" tpl="$2"; shift 2
  local text
  text="$(render "$tpl" "$@")" || exit 2
  if ((DRY)); then
    ((SHOW_PROMPT)) && { echo "----- prompt: $name -----"; printf '%s\n' "$text"; echo "----- end: $name -----"; } >&2
    echo "-"
  else
    printf '%s\n' "$text" >"$RUN_LOG_DIR/prompts/$name.md"
    echo "$RUN_LOG_DIR/prompts/$name.md"
  fi
}

if ((DRY == 0)); then
  wait_for_load || { notify_stop "the machine stayed busy (load above $MAX_LOAD1)"; exit 3; }
fi

# ---------- 1. reviewers ----------
for lens in "${LENS_LIST[@]}"; do
  ev="$RUN_DIR/evidence/$lens.md"
  if is_complete "$ev"; then log "SKIP $lens: evidence complete ($ev)"; continue; fi
  p="$(stage_prompt "$lens" "$lens")"
  run_agent "$lens" reviewer "$RUN_DIR" "$REVIEWER_BUDGET_USD" "$REVIEWER_TIMEOUT" "$p" || { notify_stop "$STOP_REASON"; exit 3; }
  if ((DRY == 0)); then
    is_complete "$ev" && log "OK $lens: evidence complete" || log "WARN $lens: evidence missing or unfinished (will retry next run)"
  fi
done

if [[ -n "$ONLY_LENS" ]]; then log "single lens run: no merge, no build"; exit 0; fi

# ---------- 2. merge ----------
ALL_LENSES=()
read -r -a ALL_LENSES <<<"$LENSES"
done_l=() miss_l=()
for lens in "${ALL_LENSES[@]}"; do
  if is_complete "$RUN_DIR/evidence/$lens.md"; then done_l+=("evidence/$lens.md"); else miss_l+=("$lens"); fi
done
log "lenses complete: ${#done_l[@]}/${#ALL_LENSES[@]} (missing: ${miss_l[*]:-none})"

merge_done() { is_complete "$RUN_DIR/REVIEW.md" && [[ -s "$RUN_DIR/BUILDER.md" ]] && jq -e 'type == "object" and has("new")' "$RUN_DIR/delta.json" >/dev/null 2>&1; }

if merge_done; then
  log "SKIP merge: REVIEW.md, BUILDER.md and delta.json complete"
elif ((${#done_l[@]} < MIN_LENSES)) && ((DRY == 0)); then
  STOP_REASON="only ${#done_l[@]} of ${#ALL_LENSES[@]} reviewers finished (need $MIN_LENSES)"
  log "STOP: $STOP_REASON"; notify_stop "$STOP_REASON"; exit 3
else
  ((${#done_l[@]} < MIN_LENSES)) && log "(dry-run) only ${#done_l[@]} lenses complete now; merge runs after the reviewers finish"
  # In a dry-run the reviewers have not run, so show the merge as it would be called after a full pass.
  if ((DRY)) && ((${#done_l[@]} == 0)); then done_txt="evidence/<each lens>.md (after the reviewers above)"; miss_txt="none"
  else done_txt="${done_l[*]:-none}"; miss_txt="${miss_l[*]:-none}"; fi
  p="$(stage_prompt merge merge "LENSES_DONE=$done_txt" "LENSES_MISSING=$miss_txt")"
  run_agent merge merge "$RUN_DIR" "$MERGE_BUDGET_USD" "$MERGE_TIMEOUT" "$p" || { notify_stop "$STOP_REASON"; exit 3; }
  if ((DRY == 0)) && ! merge_done; then
    STOP_REASON="the merge step did not finish REVIEW.md + BUILDER.md + delta.json"
    log "STOP: $STOP_REASON"; notify_stop "$STOP_REASON"; exit 3
  fi
fi

# ---------- 3. builders (only with --build) ----------
BUILT=()
if ((BUILD)); then
  if [[ ! -s "$RUN_DIR/BUILDER.md" ]]; then
    log "build: no BUILDER.md yet (a real run makes it in the merge step); nothing to plan"
  else
    launched=0
    while IFS=$'\t' read -r id size cls rul repo title; do
      [[ -n "$id" ]] || continue
      why=""
      [[ "$rul" == "no" ]] || why="ruling needed: ${rul:-?}"
      [[ -z "$why" && "$size" != "s" ]] && why="size ${size:-?} (only S)"
      [[ -z "$why" && "$cls" != "bug" ]] && why="class ${cls:-?} (only bug)"
      if [[ -z "$why" ]]; then
        printf '%s\n' $BUILD_REPOS | grep -qxF -- "$repo" || why="repo not in BUILD_REPOS: ${repo:-none}"
      fi
      [[ -z "$why" ]] && ! git -C "$repo" remote get-url origin >/dev/null 2>&1 && why="repo has no origin remote"
      bdir="$RUN_DIR/build/$id"
      [[ -z "$why" ]] && is_complete "$bdir/HANDBACK.md" && why="already handed back ($(head -n1 "$bdir/HANDBACK.md" | cut -c1-80))"
      [[ -z "$why" ]] && ((launched >= MAX_BUILDERS)) && why="max-builders $MAX_BUILDERS reached"
      if [[ -n "$why" ]]; then log "build SKIP $id ($title): $why"; continue; fi

      lid="${id,,}"
      branch="lane/claude/level-up-$DATE-$lid"
      wt="$WORKTREE_ROOT/level-up-$DATE-$lid"
      if ((DRY)); then
        log "build PLAN $id ($title): repo=$repo branch=$branch worktree=$wt"
      else
        mkdir -p "$bdir"
        if [[ -d "$wt" ]]; then
          if [[ "$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)" != "$branch" ]]; then
            log "build SKIP $id: $wt exists on another branch"; continue
          fi
          log "build RESUME $id in $wt"
        else
          git -C "$repo" fetch origin --quiet || { log "build SKIP $id: git fetch failed"; continue; }
          if git -C "$repo" show-ref --quiet "refs/heads/$branch" || git -C "$repo" show-ref --quiet "refs/remotes/origin/$branch"; then
            log "build SKIP $id: branch $branch already exists"; continue
          fi
          git -C "$repo" worktree add --quiet "$wt" -b "$branch" origin/main || { log "build SKIP $id: worktree add failed"; continue; }
        fi
      fi
      text="$(lane_text "$RUN_DIR/BUILDER.md" "$id")"
      p="$(stage_prompt "builder-$id" builder "LANE_ID=$id" "LANE_TEXT=$text" "WORKTREE=$wt" "BRANCH=$branch" "REPO=$repo" "BUILD_DIR=$bdir")"
      run_agent "builder-$id" builder "$wt" "$BUILDER_BUDGET_USD" "$BUILDER_TIMEOUT" "$p" --add-dir "$RUN_DIR" \
        || { notify_stop "$STOP_REASON"; exit 3; }
      launched=$((launched + 1))
      if ((DRY == 0)) && [[ -s "$bdir/HANDBACK.md" ]]; then
        BUILT+=("$id: $(head -n1 "$bdir/HANDBACK.md" | cut -c1-120)")
        log "build $id: $(head -n1 "$bdir/HANDBACK.md")"
      elif ((DRY == 0)); then
        BUILT+=("$id: no hand-back")
        log "build $id: no HANDBACK.md"
      fi
    done < <(parse_lanes "$RUN_DIR/BUILDER.md")
  fi
fi

# ---------- 4. notify ----------
if ((NOTIFY)); then
  if [[ -e "$RUN_LOG_DIR/notified" ]]; then
    log "notify: already sent for this run"
  elif jq -e . "$RUN_DIR/delta.json" >/dev/null 2>&1; then
    d() { jq -r --arg k "$1" '.[$k] // 0 | tostring' "$RUN_DIR/delta.json" | tr -cd '0-9'; }
    headline="$(jq -r '.headline // ""' "$RUN_DIR/delta.json" | tr '\n\t\r|' '    ' | sed 's/  */ /g; s/^ //; s/ $//' | cut -c1-140)"
    grep -qiw 'dean' <<<"$headline" && headline=""
    msg="ZEN, the level-up review for $DATE is done.
New: $(d new). Still open: $(d still_open). Fixed: $(d fixed). Regressed: $(d regressed).
P0: $(d p0). P1: $(d p1). Rulings owed: $(d rulings)."
    [[ -n "$headline" ]] && msg+=$'\n'"$headline"
    if ((BUILD)) && ((${#BUILT[@]})); then msg+=$'\n'"Builders ran: ${#BUILT[@]}. Draft PRs only, nothing merged."; fi
    msg+=$'\n'"Report: $(show_path "$RUN_DIR")/REVIEW.md"
    notify "$msg"
  else
    log "notify: no delta.json (a real run makes it in the merge step)"
  fi
fi

log "done. spent=\$$SPENT ledger=$RUN_LOG_DIR/costs.tsv"
exit 0
