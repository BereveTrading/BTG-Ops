# BTG level-up loop

Built DISABLED. Turning it on is ZEN's decision, because each run spends tokens.

## What it does
One run (`run.sh`) does these steps:
1. **7 read-only reviewers** run one after the other: technical, visual, competitive, engine, zed-render, systems and data. Each one writes `evidence/<lens>.md` in `~/btg/reviews/level-up-<date>/`.
2. **1 merge reviewer** checks every P0/P1 firsthand and dedupes the findings. It compares them with the previous run's REVIEW.md (NEW / STILL OPEN / FIXED / REGRESSED). Then it writes `REVIEW.md` (defects sheet, ranked upgrade sheet, rulings owed), `BUILDER.md` (lanes), `checks.md`, `progress.md` and `delta.json`.
3. **Builders run only with `--build`.** A builder takes a lane only when the lane is `Ruling needed: no`, `Size: S` and `Class: bug`. The cap is `--max-builders` (default 2). Each builder works in its own new worktree from origin/main and opens **one draft PR**. The merge reviewer writes the lanes. A builder never reviews its own lane.
4. **`--notify` sends one notice.** It sends ZEN a short Telegram notice (3–6 lines, plain English) through `~/btg/ops/tg-text.sh`, a single sendMessage. The loop never reads Telegram.

The timer file runs steps 1, 2 and 4 weekly, on Monday at 03:30 UTC. It does not run builders.

## Cost
- Estimate: **about 425k–520k subagent tokens per run**. The basis is 76k–101k tokens per reviewer in the 2026-11-09 manual review, plus the merge step. There is no measured $ figure yet. After the first run, `run/costs.tsv` shows each agent's real cost and tokens as the CLI reports them. On a subscription login, `total_cost_usd` is the CLI's estimate, not a bill.
- Caps in `level-up.conf` (caps, not estimates):
  - $15 per reviewer and $15 for the merge step (`--max-budget-usd` on each call).
  - $20 per builder.
  - **$120 per run.** run.sh adds up the reported cost and starts no new agent at the cap. It also cuts each agent's cap to what is left. An agent killed by its timeout is charged its full cap.
- Model: `opus` by default, with a `sonnet` fallback. run.sh **refuses** any model name that contains "fable" and any model that is not opus/sonnet/haiku.

## Enable (3 commands)
```
cp ~/btg/ops/level-up/systemd/btg-level-up.{service,timer} ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now btg-level-up.timer
```

## Stop
- Stop the schedule: `systemctl --user disable --now btg-level-up.timer`
- Stop a run that is in progress: `systemctl --user stop btg-level-up.service`. This stops that unit only. Run it again later and it resumes: finished evidence files are not redone.

## Try it without spending
- `~/btg/ops/level-up/run.sh --dry-run [--build] [--notify] [--show-prompt]` prints the plan, the argv and the notice. It writes nothing and starts no agent.
- `bash ~/btg/ops/level-up/tests/test_run.sh` runs 78 checks. The tests use a fake CLI and a fake notifier.
- To run by hand: `run.sh --lens data` (one reviewer, no merge), `run.sh` (review + merge), `run.sh --build --max-builders 1`.

## Safety limits
- **Never** merges, deploys, restarts a unit or container, writes to the DB or changes prod. Builders open **draft** PRs only (no `gh pr merge`, no `gh pr ready`).
- Reviewers are read-only. A reviewer never builds, and a builder never reviews its own lane.
- No pkill or killall. Never kills a PPID. A timeout signals only that agent's own process.
- No Discord API. Telegram is send-only, through run.sh, and agents are denied the send scripts.
- One run at a time: `flock` on `~/.local/state/btg-level-up/run.lock`. A second run exits 0.
- `nice -n 19` + `ionice -c 3` for everything. The unit has MemoryMax=12G and TimeoutStartSec=12h.
- Load gate: a run waits while load1 > 24, checking every 5 min for up to 120 min. Then it stops; a later run resumes it.
- Hard timeouts per agent: reviewer 75 min, merge 60 min, builder 120 min.
- Scratch and TMPDIR are in the run folder on disk, never /tmp.
- Agents run headless in `--permission-mode auto`. The safety classifier and each brief's safety block are the main guard. A `--disallowed-tools` deny list (kill, systemctl start/stop, docker run/stop, gh pr merge, getUpdates, Telegram/Discord API, refresh_continuous_aggregate, deploy scripts, …) is a **backstop only**: prefix rules can miss a command that is wrapped in another one.
- The owner is "ZEN" in every brief and notice. run.sh refuses to send a notice that contains his real name.

## Files
`run.sh` · `level-up.conf` (every value can be overridden by a `LEVELUP_*` env var) · `briefs/` (`_common.md` + 7 lenses + `merge.md` + `builder.md`) · `systemd/` · `tests/`
