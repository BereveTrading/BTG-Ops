#!/usr/bin/env bash
# Test double for the claude CLI. Spends nothing. Reads the prompt on stdin, writes the
# file the prompt asks for, prints a result JSON like `claude -p --output-format json`.
# FAKE_MODE: normal (default) | hang | incomplete | crash.   FAKE_COST: reported cost.
set -euo pipefail
prompt="$(cat)"
{ printf 'CWD=%s\n' "$PWD"; printf 'TMPDIR=%s\n' "${TMPDIR:-}"; printf 'ARG=%s\n' "$@"; echo "---"; } >>"${FAKE_LOG:?}"
mode="${FAKE_MODE:-normal}"
case "$mode" in
  hang) exec sleep 30 ;;
  crash) echo "fake crash" >&2; exit 1 ;;
esac
marker='<!-- level-up: complete -->'
end() { [[ "$mode" == incomplete ]] || echo "$marker"; }
run_dir="$(sed -n 's/^- Run folder: //p' <<<"$prompt" | head -n1)"
if grep -q 'You are the MERGE REVIEWER' <<<"$prompt"; then
  { echo "# REVIEW (fake)"; end; } >"$run_dir/REVIEW.md"
  cp "${FAKE_BUILDER_SRC:?}" "$run_dir/BUILDER.md"
  echo "| fake | pass | x | - |" >"$run_dir/checks.md"
  echo "# progress (fake)" >"$run_dir/progress.md"
  [[ "$mode" == incomplete ]] || cp "${FAKE_DELTA:?}" "$run_dir/delta.json"
elif grep -q 'You are a BUILDER' <<<"$prompt"; then
  hb="$(grep -oE 'Write [^ :]+/HANDBACK\.md' <<<"$prompt" | head -n1 | cut -d' ' -f2)"
  lane="$(sed -n 's/^## Your lane: //p' <<<"$prompt" | head -n1)"
  { echo "READY fake $lane commit 0000000 PR https://example.invalid/pr/1"; end; } >"$hb"
else
  ev="$(grep -oE 'Write [^ :]+/evidence/[a-z-]+\.md' <<<"$prompt" | head -n1 | cut -d' ' -f2)"
  { echo "# evidence (fake)"; end; } >"$ev"
fi
printf '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"result":"ok","total_cost_usd":%s,"usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}\n' "${FAKE_COST:-1.25}"
