#!/usr/bin/env bash
# Tests for run.sh. Spend nothing: every agent is tests/fake-claude.sh and every notice
# is tests/fake-notify.sh. Scratch lives on disk in ~/.cache/btg-level-up-test (never /tmp).
# Usage: bash tests/test_run.sh
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(dirname "$HERE")"
RUN="$ROOT/run.sh"
T="$HOME/.cache/btg-level-up-test"
DATE=2026-11-09
PASS=0 FAIL=0

case "$T" in "$HOME"/.cache/btg-level-up-test) ;; *) echo "bad test dir $T"; exit 1 ;; esac
rm -rf -- "$T"; mkdir -p "$T"

ok()   { PASS=$((PASS + 1)); echo "PASS  $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "FAIL  $1"; [[ -n "${2:-}" ]] && sed 's/^/      /' <<<"$2" | tail -n 25; }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name" "${OUT:-}"; fi; }
has()  { grep -qF -- "$1" <<<"$OUT"; }
hasnt() { ! grep -qF -- "$1" <<<"$OUT"; }

reset_env() {
  rm -rf -- "$T/s"; mkdir -p "$T/s"
  export LEVELUP_STATE_DIR="$T/s/state" LEVELUP_REVIEWS_ROOT="$T/s/reviews" LEVELUP_PREV_REVIEW_SEED="$T/s/no-seed.md"
  export LEVELUP_CLAUDE_BIN="$HERE/fake-claude.sh" LEVELUP_NOTIFY_BIN="$HERE/fake-notify.sh"
  export LEVELUP_MAX_LOAD1=100000 LEVELUP_LOAD_WAIT_MIN=0 LEVELUP_READY_URL="http://127.0.0.1:9/none"
  export LEVELUP_BUILD_REPOS="$T/s/repo" LEVELUP_WORKTREE_ROOT="$T/s/wt"
  export FAKE_LOG="$T/s/fake.log" FAKE_NOTIFY_OUT="$T/s/notify.out" FAKE_DELTA="$HERE/fixtures/delta.json"
  export FAKE_BUILDER_SRC="$T/s/BUILDER.md" FAKE_COST=1.25
  unset FAKE_MODE LEVELUP_MODEL LEVELUP_FALLBACK_MODEL LEVELUP_RUN_BUDGET_USD LEVELUP_REVIEWER_TIMEOUT LEVELUP_MIN_LENSES
  sed "s#@REPO@#$T/s/repo#g" "$HERE/fixtures/BUILDER.md" >"$FAKE_BUILDER_SRC"
  RD="$LEVELUP_REVIEWS_ROOT/level-up-$DATE"
}
make_repo() {   # a local repo with a local bare "origin" (no network)
  git init -q --bare "$T/s/origin.git"
  git init -q -b main "$T/s/repo"
  git -C "$T/s/repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  git -C "$T/s/repo" remote add origin "$T/s/origin.git"
  git -C "$T/s/repo" push -q origin main
}
run() { OUT="$("$RUN" --date "$DATE" "$@" 2>&1)"; RC=$?; }

# ---- static ----
reset_env
check "bash -n run.sh" bash -n "$RUN"
check "bash -n fakes" bash -c "bash -n '$HERE/fake-claude.sh' && bash -n '$HERE/fake-notify.sh'"

# ---- refusals ----
for m in fable Fable claude-fable-1 gpt-5 "opus;rm"; do
  LEVELUP_MODEL="$m" run --dry-run
  check "model '$m' refused (rc 2)" test "$RC" = 2
done
LEVELUP_FALLBACK_MODEL=fable run --dry-run;   check "fallback fable refused" test "$RC" = 2
LEVELUP_MODEL=sonnet run --dry-run;           check "model sonnet accepted" test "$RC" = 0
run --dry-run --lens nope;                    check "unknown lens refused" test "$RC" = 2
run --bogus;                                  check "unknown option refused" test "$RC" = 2
LEVELUP_RUN_BUDGET_USD=abc run --dry-run;     check "non-numeric budget refused" test "$RC" = 2

# ---- dry-run spends and writes nothing ----
reset_env
run --dry-run --build --notify --show-prompt
check "dry-run rc 0" test "$RC" = 0
check "dry-run created no run dir" test ! -e "$RD"
check "dry-run created no state dir" test ! -e "$LEVELUP_STATE_DIR"
check "dry-run started no agent" test ! -e "$FAKE_LOG"
check "dry-run sent nothing" test ! -e "$FAKE_NOTIFY_OUT"
check "dry-run lists 7 reviewers + merge" test "$(grep -c 'WOULD RUN' <<<"$OUT")" = 8
check "dry-run prompts fully rendered" bash -c '! grep -qE "\{[A-Z][A-Z_]+\}" <<<"$1"' _ "$OUT"
check "dry-run prompt has run folder" has "- Run folder: $RD"
check "dry-run argv shows model + budget" has "--model opus --output-format json --no-session-persistence --permission-mode auto --max-budget-usd 15.00"

run --dry-run --lens technical
check "--lens runs one reviewer, no merge" bash -c '[[ $(grep -c "WOULD RUN" <<<"$1") == 1 ]] && grep -q "WOULD RUN technical" <<<"$1" && grep -q "no merge" <<<"$1"' _ "$OUT"

# ---- dry-run resume: a finished evidence file is not redone ----
mkdir -p "$RD/evidence"
cp "$HERE/fixtures/evidence-complete.md" "$RD/evidence/technical.md"
cp "$HERE/fixtures/evidence-incomplete.md" "$RD/evidence/visual.md"
run --dry-run
check "complete evidence skipped" has "SKIP technical: evidence complete"
check "unfinished evidence re-run" has "WOULD RUN visual"

# ---- dry-run build plan ----
make_repo
cp "$FAKE_BUILDER_SRC" "$RD/BUILDER.md"; cp "$FAKE_DELTA" "$RD/delta.json"
printf '# R\n<!-- level-up: complete -->\n' >"$RD/REVIEW.md"
run --dry-run --build
check "build: merge skipped when complete" has "SKIP merge"
check "build: L1 planned" has "build PLAN L1"
check "build: L6 planned" has "build PLAN L6"
check "build: L2 skipped (upgrade)" has "build SKIP L2 (New header readout): class upgrade"
check "build: L3 skipped (ruling)" has "build SKIP L3 (Pricing copy): ruling needed: yes"
check "build: L4 skipped (size M)" has "build SKIP L4 (Big refactor): size m"
check "build: L5 skipped (repo)" has "build SKIP L5 (Repo outside the allow list): repo not in BUILD_REPOS"
check "build: L7 skipped (cap 2)" has "build SKIP L7 (Third eligible bug (over the cap)): max-builders 2 reached"
check "build: dry-run made no worktree" test ! -e "$LEVELUP_WORKTREE_ROOT"
run --dry-run --build --max-builders 1
check "--max-builders 1 caps at one" bash -c '[[ $(grep -c "build PLAN" <<<"$1") == 1 ]]' _ "$OUT"

# ---- dry-run notify text ----
run --dry-run --notify
MSG="$(sed -n 's/^    | //p' <<<"$OUT")"
check "notify: message shown" has "WOULD NOTIFY"
check "notify: starts with ZEN" bash -c '[[ "$(head -n1 <<<"$1")" == "ZEN, the level-up review for 2026-11-09 is done." ]]' _ "$MSG"
check "notify: 3-6 lines" bash -c 'n=$(wc -l <<<"$1"); (( n >= 3 && n <= 6 ))' _ "$MSG"
check "notify: counts from delta.json" bash -c 'grep -q "^New: 3. Still open: 4. Fixed: 2. Regressed: 0.$" <<<"$1" && grep -q "^P0: 1. P1: 3. Rulings owed: 2.$" <<<"$1"' _ "$MSG"
check "notify: no table chars" bash -c '! grep -q "|" <<<"$1"' _ "$MSG"
jq '.headline = "Dean should look at the P0."' "$FAKE_DELTA" >"$RD/delta.json"
run --dry-run --notify
MSG="$(sed -n 's/^    | //p' <<<"$OUT")"
check "notify: headline with real name dropped" bash -c '! grep -qi "dean" <<<"$1" && [[ -n "$1" ]]' _ "$MSG"

# ---- lock ----
reset_env
mkdir -p "$LEVELUP_STATE_DIR"
OUT="$( ( flock -n 8 || exit 9; "$RUN" --date "$DATE" --dry-run 2>&1 ) 8>"$LEVELUP_STATE_DIR/run.lock" )"
check "lock held: dry-run reports it" has "lock: HELD"
OUT="$( ( flock -n 8 || exit 9; "$RUN" --date "$DATE" 2>&1; echo "rc=$?" ) 8>"$LEVELUP_STATE_DIR/run.lock" )"
check "lock held: real run exits 0 at once" bash -c 'grep -q "another run holds" <<<"$1" && grep -q "^rc=0$" <<<"$1"' _ "$OUT"
check "lock held: no agent started" test ! -e "$FAKE_LOG"

# ---- full run with fakes (review + merge + notify) ----
reset_env
run --notify
check "full run rc 0" test "$RC" = 0
n=0; for l in technical visual competitive engine zed-render systems data; do
  tail -n1 "$RD/evidence/$l.md" 2>/dev/null | grep -qxF '<!-- level-up: complete -->' && n=$((n + 1)); done
check "full run: 7 evidence files complete" test "$n" = 7
check "full run: REVIEW.md + BUILDER.md + delta.json" bash -c 'tail -n1 "$1/REVIEW.md" | grep -q "level-up: complete" && test -s "$1/BUILDER.md" && jq -e . "$1/delta.json" >/dev/null' _ "$RD"
check "full run: ledger has 8 agent rows" test "$(($(wc -l <"$RD/run/costs.tsv") - 1))" = 8
check "full run: spent = 8 x 1.25" bash -c 'grep -q "done. spent=\$10.0000" <<<"$1"' _ "$OUT"
check "full run: 8 prompts saved" test "$(find "$RD/run/prompts" -name '*.md' | wc -l)" = 8
check "full run: notify sent once" test "$(grep -c '^===$' "$FAKE_NOTIFY_OUT")" = 1
check "full run: argv has model opus" grep -qx 'ARG=opus' "$FAKE_LOG"
check "full run: argv has budget cap" grep -qx 'ARG=--max-budget-usd' "$FAKE_LOG"
check "full run: deny list passed" bash -c 'grep -qx "ARG=--disallowed-tools" "$1" && grep -qxF "ARG=Bash(pkill:*)" "$1" && grep -qxF "ARG=Bash(gh pr merge:*)" "$1" && grep -qxF "ARG=Bash(*getUpdates*)" "$1"' _ "$FAKE_LOG"
check "full run: no fable anywhere in argv" bash -c '! grep -qi "fable" "$1"' _ "$FAKE_LOG"
check "full run: agent cwd is run folder" grep -qx "CWD=$RD" "$FAKE_LOG"
check "full run: TMPDIR on disk in run folder" grep -qx "TMPDIR=$RD/.tmp" "$FAKE_LOG"
calls=$(grep -c '^---$' "$FAKE_LOG")
run --notify
check "rerun: nothing redone" bash -c '[[ $(grep -c "^---$" "$1") == '"$calls"' ]]' _ "$FAKE_LOG"
check "rerun: notify not repeated" test "$(grep -c '^===$' "$FAKE_NOTIFY_OUT")" = 1
check "rerun: rc 0" test "$RC" = 0

# ---- builders (real git worktrees on a local test repo; no network) ----
make_repo
run --build
check "build run rc 0" test "$RC" = 0
check "build: 2 builders ran (cap)" test "$(grep -c '^builder-' <(cut -f2 "$RD/run/costs.tsv"))" = 2
check "build: L1 worktree on its own branch" bash -c '[[ $(git -C "$1" rev-parse --abbrev-ref HEAD) == lane/claude/level-up-2026-11-09-l1 ]]' _ "$LEVELUP_WORKTREE_ROOT/level-up-$DATE-l1"
check "build: L1 handback written" bash -c 'head -n1 "$1" | grep -q "^READY fake L1"' _ "$RD/build/L1/HANDBACK.md"
check "build: builder cwd is its worktree" grep -qx "CWD=$LEVELUP_WORKTREE_ROOT/level-up-$DATE-l1" "$FAKE_LOG"
check "build: builder gets --add-dir run folder" bash -c 'grep -A1 -x "ARG=--add-dir" "$1" | grep -qx "ARG=$2"' _ "$FAKE_LOG" "$RD"
check "build: no L3/L4/L5 worktree" bash -c '! ls "$1" | grep -qE "l3|l4|l5"' _ "$LEVELUP_WORKTREE_ROOT"
check "build: [main] of test repo untouched" bash -c '[[ $(git -C "$1" rev-parse --abbrev-ref HEAD) == main ]]' _ "$T/s/repo"
run --build
check "build rerun: L1 already handed back" has "build SKIP L1 (Live bar drops on reconnect): already handed back"
check "build rerun: L7 now runs (cap per run)" has "build L7: READY fake L7"

# ---- run budget stops new agents ----
reset_env
FAKE_COST=1.5 LEVELUP_RUN_BUDGET_USD=2 run --notify
check "budget: rc 3" test "$RC" = 3
check "budget: one agent then stop" test "$(grep -c '^---$' "$FAKE_LOG")" = 1
check "budget: stop reason logged" has "STOP: run budget reached"
check "budget: stop notice sent" grep -q "stopped early" "$FAKE_NOTIFY_OUT"

# ---- per-agent timeout ----
reset_env
FAKE_MODE=hang LEVELUP_REVIEWER_TIMEOUT=2s run --lens technical
check "timeout: agent killed (rc 124 in ledger)" bash -c 'awk -F"\t" "NR==2{exit !(\$4==124 && \$5==\"no-result\" && \$6==\$7)}" "$1"' _ "$RD/run/costs.tsv"
check "timeout: evidence not marked complete" test ! -s "$RD/evidence/technical.md"

# ---- too few lenses: no merge ----
reset_env
FAKE_MODE=incomplete run --notify
check "few lenses: rc 3" test "$RC" = 3
check "few lenses: merge not run" bash -c '! test -e "$1/REVIEW.md"' _ "$RD"
check "few lenses: reason logged" has "only 0 of 7 reviewers finished"

rm -rf -- "$T"
echo "----"
echo "passed $PASS, failed $FAIL"
((FAIL == 0))
