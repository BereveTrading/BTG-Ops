#!/usr/bin/env python3
"""Detect a Discord gateway-cache divergence on the production session desks.

WHY THIS EXISTS. On 2026-08-17 london's channel name was stale in Discord's
gateway cache — clients rendered '🇬🇧・london-session・🔴live' for 9.5 hours while
REST, every receipt, and `live_marker_census()` all correctly said one live desk.
`ops/discord-gateway-resync.py` repairs that, and it is proven against live
production. But the repair is manual, so the only detector was Dean noticing and
reporting it a fourth time. This closes that hole.

WHAT IT DOES. Reads the authoritative store (REST) and the surface clients
actually render (the gateway's GUILD_CREATE payload), compares the two, and
alerts on Telegram when they disagree. It never writes to Discord. The repair
stays a separate, deliberate act — see AUTO-REPAIR below.

WHY NOT FOLD IT INTO THE RECONCILER. Reading the gateway needs a fresh IDENTIFY,
and Discord allows roughly 1000 of those per day. The session reconciler fires
1440 times a day, so a gateway probe cannot live there. At every 10 minutes this
is 144/day, comfortably inside the budget.

THREE THINGS THIS DELIBERATELY DOES NOT DO:

  * It does not write a receipt on a clean run. 144 runs/day each leaving a
    directory would rebuild the exact problem `prune-session-order-receipts.py`
    was just written to clean up (9,016 dirs in six days). Clean runs append one
    JSONL line; only a divergence gets a receipt directory.
  * It does not alert every run while a divergence persists. A stale cache lasts
    hours, so 10-minute alerts would mean ~57 messages for one fault. It alerts
    on the transition into divergence, again every REALERT_AFTER, and once on
    clear.
  * It does not treat the first sighting as real. A handoff writes REST and the
    cache follows a beat later, so a probe landing mid-propagation sees a
    divergence that is not a fault. Anything spotted is re-read after
    CONFIRM_DELAY and only a divergence that survives both reads is reported.

AUTO-REPAIR is wired but OFF by default (`--repair`). The repair is provably
safe — it takes the reconciler's own flock, writes only slowmode, and its
2026-08-17 receipt shows `restBefore == restAfter`, so it converges the cache
onto whatever the reconciler already decided and can never express an opinion
about which desk is live. Turning it on would make the surface self-heal within
ten minutes with no human in the loop. That is Dean's call, not this script's
default.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

OPS = Path("/home/dean/btg/ops")
RESYNC = OPS / "discord-gateway-resync.py"
STATE_DIR = OPS / "gateway-divergence-watch"
STATE_FILE = STATE_DIR / "state.json"
LOG_FILE = STATE_DIR / "watch.jsonl"
TG_TEXT = OPS / "tg-text.sh"

# A divergence spotted mid-handoff is propagation, not a fault. Wait this long
# and read the gateway again; only a divergence present in both reads is real.
CONFIRM_DELAY = timedelta(seconds=25)

# While a divergence persists, re-alert at most this often.
REALERT_AFTER = timedelta(hours=6)


def load_resync():
    """Import the resync tool as a module.

    Its filename is hyphenated, so a plain import cannot reach it. Everything
    below reuses its readers verbatim — a second implementation of "what does
    the gateway say" is exactly how the two surfaces drifted in the first place.
    """
    spec = importlib.util.spec_from_file_location("gateway_resync", RESYNC)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {RESYNC}")
    module = importlib.util.module_from_spec(spec)
    sys.modules["gateway_resync"] = module
    spec.loader.exec_module(module)
    return module


def now() -> datetime:
    return datetime.now(timezone.utc)


def read_state() -> dict:
    try:
        return json.loads(STATE_FILE.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def write_state(state: dict) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    tmp = STATE_FILE.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(state, ensure_ascii=False, indent=2))
    tmp.replace(STATE_FILE)


def append_log(row: dict) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    with LOG_FILE.open("a") as handle:
        handle.write(json.dumps(row, ensure_ascii=False) + "\n")


def alert(message: str) -> None:
    """Send to Telegram. A dead alert path must not take the watcher down."""
    try:
        subprocess.run([str(TG_TEXT), message], check=True, timeout=30)
    except (subprocess.SubprocessError, OSError) as exc:
        # Same convention as the W4 alert template: if the alert path is down,
        # leave a greppable trace rather than failing the check that found it.
        print(f"WATCHDOG-ALERT-FAILED: {exc}", file=sys.stderr)


def describe(rows: list[dict]) -> str:
    lines = []
    for row in rows:
        lines.append(
            f"  {row['trueName']}\n"
            f"  clients see: {row['staleName']}\n"
            f"  stale since: {row['staleSince']}"
        )
    return "\n".join(lines)


def write_receipt(payload: dict) -> Path:
    stamp = now().strftime("%Y%m%dT%H%M%S%fZ")
    directory = STATE_DIR / stamp
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "receipt.json").write_text(
        json.dumps(payload, ensure_ascii=False, indent=2)
    )
    return directory


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--repair",
        action="store_true",
        help="run the SLOWMODE resync when a divergence is confirmed (default: alert only)",
    )
    parser.add_argument(
        "--quiet", action="store_true", help="suppress the per-run stdout summary"
    )
    args = parser.parse_args()

    resync = load_resync()
    values = resync.load_env(resync.ENV_FILE)
    if values.get("DISCORD_GUILD_ID") != resync.order.PRODUCTION_GUILD_ID:
        raise resync.VisualPassError("env does not point at the production guild")
    token = values["DISCORD_BOT_TOKEN"]
    api = resync.DiscordApi(token)

    def read_rest() -> dict[str, str]:
        rows = api.get(f"/guilds/{resync.order.PRODUCTION_GUILD_ID}/channels")
        return {
            str(r["id"]): str(r["name"])
            for r in rows
            if str(r.get("id")) in resync.order.CHANNEL_IDS
        }

    rest = read_rest()
    gateway = resync.gateway_names(token)
    diverged = resync.divergences(rest, gateway)

    # A divergence seen once may just be the cache catching up mid-handoff.
    # Confirm it against a second, independent gateway read before believing it.
    if diverged:
        time.sleep(CONFIRM_DELAY.total_seconds())
        rest = read_rest()
        gateway = resync.gateway_names(token)
        confirmed = resync.divergences(rest, gateway)
        transient = {r["id"] for r in diverged} - {r["id"] for r in confirmed}
        diverged = confirmed
    else:
        transient = set()

    stamp = now()
    state = read_state()
    known = set(state.get("divergedIds", []))
    current = {row["id"] for row in diverged}

    live_rest = sum(
        1 for n in rest.values() if n.endswith(resync.order.LIVE_MARKER)
    )
    live_gw = sum(
        1
        for c in gateway.values()
        if str(c.get("name", "")).endswith(resync.order.LIVE_MARKER)
    )

    append_log(
        {
            "at": stamp.isoformat(),
            "divergedIds": sorted(current),
            "transientIds": sorted(transient),
            "liveRest": live_rest,
            "liveGateway": live_gw,
        }
    )

    if not args.quiet:
        for channel_id in sorted(resync.order.CHANNEL_IDS):
            rest_name = rest.get(channel_id, "?")
            gw_name = gateway.get(channel_id, {}).get("name", "?")
            flag = "  " if rest_name == gw_name else "<-- DIVERGED"
            print(f"  {channel_id}  rest={rest_name!r:38} gateway={gw_name!r:38} {flag}")
        print(f"\nlive desks: REST says {live_rest}, a client sees {live_gw}")
        if transient:
            print(f"transient (cleared on re-read): {sorted(transient)}")

    # Cleared: something we were tracking now agrees again.
    if known and not current:
        alert(
            "🟢 Discord gateway cache back in sync — "
            f"clients and the authoritative store agree again ({live_rest} live desk).\n"
            f"Was diverged since {state.get('firstSeen', 'unknown')}."
        )
        write_state({})
        if not args.quiet:
            print("\ncleared — the cache agrees with the authoritative store again.")
        return 0

    if not current:
        if not args.quiet:
            print("\nin sync.")
        return 0

    # Diverged. Decide whether this is a new fault or one we already reported.
    first_seen = state.get("firstSeen") if known == current else stamp.isoformat()
    last_alerted = state.get("lastAlerted")
    is_new = known != current
    due = False
    if last_alerted:
        try:
            due = stamp - datetime.fromisoformat(last_alerted) >= REALERT_AFTER
        except ValueError:
            due = True

    receipt = write_receipt(
        {
            "schemaVersion": "btg.discord.gateway-divergence-watch.v1",
            "capturedAt": stamp.isoformat(),
            "guildId": resync.order.PRODUCTION_GUILD_ID,
            "diverged": diverged,
            "transientIds": sorted(transient),
            "rest": rest,
            "gateway": {k: v.get("name") for k, v in gateway.items()},
            "liveRest": live_rest,
            "liveGateway": live_gw,
            "firstSeen": first_seen,
        }
    )

    if not args.quiet:
        print(f"\nDIVERGED — receipt {receipt}")
        print(describe(diverged))

    if is_new or due:
        if live_gw != live_rest:
            headline = (
                f"clients see {live_gw} live desk(s), "
                f"the authoritative store has {live_rest}"
            )
        else:
            # Equal counts, different names: clients are being shown the WRONG
            # desk as live. A census that only counts markers reads this as
            # healthy, which is exactly the blind spot worth alerting on.
            headline = (
                f"clients are showing the wrong desk live "
                f"({live_gw} marker(s) on both surfaces, on different channels)"
            )
        alert(
            f"🔴 Discord gateway cache is stale — {headline}.\n\n"
            f"{describe(diverged)}\n\n"
            "This will not clear at the next handoff; only a write to that channel "
            "refreshes it. Repair:\n"
            "! python3 /home/dean/btg/ops/discord-gateway-resync.py --apply"
        )

    write_state(
        {
            "divergedIds": sorted(current),
            "firstSeen": first_seen,
            "lastAlerted": stamp.isoformat() if (is_new or due) else last_alerted,
        }
    )

    if args.repair:
        if not args.quiet:
            print("\n--repair set: running the resync.")
        result = subprocess.run(
            [sys.executable, str(RESYNC), "--apply"],
            capture_output=True,
            text=True,
            timeout=300,
        )
        print(result.stdout)
        if result.returncode != 0:
            print(result.stderr, file=sys.stderr)
            return result.returncode
        alert("🔧 Gateway cache resync applied automatically; divergence repaired.")

    # A divergence is a finding, not a malfunction of this watcher. Exiting
    # non-zero here would fire the W4 OnFailure alert as well and conflate
    # "the surface is wrong" with "the detector broke".
    return 0


if __name__ == "__main__":
    sys.exit(main())
