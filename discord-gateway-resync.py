#!/usr/bin/env python3
"""Force Discord's gateway cache to resync a session channel whose name is stale.

Dean, 2026-08-17, three times: "london and new york are live", "its still the
same and its not fixed", "i forceclosed and reopened your wrong again". He was
right every time, and every check I ran was blind to it, because every check I
ran used REST.

THE DEFECT. Discord serves a channel's name from two places that can disagree:

  * REST (`GET /channels/{id}`, `GET /guilds/{id}/channels`) reads the
    authoritative store. This is what the session reconciler writes, what it
    verifies, and what every receipt and census entry has ever recorded.
  * The gateway's `GUILD_CREATE` payload reads a cache. This is what a Discord
    *client* renders. Nothing a user can do — reload, force-quit, reinstall,
    switch device — reads anything else.

On 2026-08-17 those two disagreed for eight hours:

    audit log   london live -> base        12:00:01.782Z
    gateway     london object `version`    12:00:01.875Z   (93 ms later)
    gateway     london object `name`       '🇬🇧・london-session・🔴live'
    REST        london name                '🇬🇧・london-session'

The cache repopulated 93 ms *after* the rename committed and still took the
pre-rename name — a read-your-writes miss on Discord's side. Nothing wrote to
london again (the next scheduled write was 07:00 the following day), so the
cache had no reason to refresh and kept serving the stale name to every client.
The handoff itself was clean: two writes, correctly ordered, 426 ms apart. This
is not the interleave that `single_run()` fixes. It is a rename that succeeded
everywhere the reconciler can see and never reached the surface users read.

THE REPAIR. A cache that will not refresh on its own refreshes when something
writes to the channel. Two strategies, cheapest first:

  1. SLOWMODE — set `rate_limit_per_user` to 1 and straight back to 0. Any
     channel mutation emits `CHANNEL_UPDATE` carrying the full channel object,
     which is enough to repopulate the cache. The desks deny SEND_MESSAGES to
     @everyone, so a one-second slowmode on a locked channel changes nothing a
     user can perceive, and `rate_limit_per_user` is not in the name/topic rate
     limit bucket (2 per 10 minutes), so it costs nothing we need later.

  2. NAME_TOGGLE — only if the gateway is still stale after (1). Rename the
     channel to the name the gateway already believes, then back to the name
     REST holds. Both writes are real changes to the authoritative store, so
     both are guaranteed to emit, and the second carries the correct name by
     construction. The cost is real: for the few hundred milliseconds between
     them the authoritative store genuinely does show two live desks. That is
     survivable here precisely because clients are *already* showing two, so no
     user observes a new wrong state — but it is the reason this is second and
     not first, and it consumes both of the channel's name edits for ten
     minutes.

Verification is by gateway, never by REST. Checking this repair with a REST read
would reproduce the exact blind spot that let me tell Dean twice the server was
clean.

BOUNDARY. `production_session_order.ExactProductionApi` refuses everything
outside the three managed session channels. That guard is correct and is not
weakened or bypassed here — this tool never imports it and carries its own,
narrower one instead:

  * only a channel in `CHANNEL_IDS` may be touched;
  * it must actually be diverged — gateway name != REST name — or it is skipped;
  * both the stale and the true name must be in `APPROVED_NAMES_BY_ID`, so a
    channel someone renamed by hand is refused rather than "repaired" into a
    name this repo invented;
  * the final name written is always the one REST already holds, so this tool
    can only ever converge the cache onto the reconciler's decision. It has no
    opinion about which desk should be live and cannot express one;
  * it takes the reconciler's own `single_run()` lock, so it can never interleave
    with a handoff.

Dry-run by default. Pass --apply to write to Discord.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

ADMIN = Path("/home/dean/btg/wt-production-session-order-v1/apps/discord-admin")
sys.path.insert(0, str(ADMIN))

import production_session_order as order  # noqa: E402
from discord_interface_visual_pass import DiscordApi, VisualPassError, load_env  # noqa: E402

ENV_FILE = Path("/home/dean/btg/ops/discord-bot.env")
RECEIPT_ROOT = Path("/home/dean/btg/ops/gateway-resync")
GUILD_ID = int(order.PRODUCTION_GUILD_ID)


def gateway_names(token: str) -> dict[str, dict]:
    """Read the session channels as a Discord *client* receives them.

    One connect, one GUILD_CREATE, immediate disconnect. The raw payload is
    captured rather than discord.py's model objects so the cache's `version`
    stamp survives — it is the only field that dates the staleness.
    """
    import discord

    captured: dict[str, dict] = {}
    intents = discord.Intents.default()
    intents.guilds = True
    client = discord.Client(intents=intents, enable_debug_events=True)

    @client.event
    async def on_socket_raw_receive(message):  # type: ignore[no-untyped-def]
        if isinstance(message, bytes):
            return
        try:
            frame = json.loads(message)
        except (ValueError, TypeError):
            return
        if frame.get("t") != "GUILD_CREATE":
            return
        if str(frame["d"].get("id")) != order.PRODUCTION_GUILD_ID:
            return
        for row in frame["d"].get("channels", []):
            if str(row.get("id")) in order.CHANNEL_IDS:
                captured[str(row["id"])] = row

    @client.event
    async def on_ready():  # type: ignore[no-untyped-def]
        await asyncio.sleep(2)
        await client.close()

    asyncio.run(client.start(token))
    if not captured:
        raise VisualPassError("gateway delivered no GUILD_CREATE for the production guild")
    return captured


def divergences(rest: dict[str, str], gw: dict[str, dict]) -> list[dict]:
    """Session channels whose cached name differs from the authoritative one."""
    found = []
    for channel_id in sorted(order.CHANNEL_IDS):
        true_name = rest.get(channel_id)
        cached = gw.get(channel_id, {})
        stale_name = cached.get("name")
        if true_name is None or stale_name is None or stale_name == true_name:
            continue
        approved = order.APPROVED_NAMES_BY_ID[channel_id]
        if true_name not in approved or stale_name not in approved:
            raise VisualPassError(
                f"{channel_id}: refusing to repair an unrecognised name "
                f"(rest={true_name!r} gateway={stale_name!r})"
            )
        version = cached.get("version")
        found.append({
            "id": channel_id,
            "trueName": true_name,
            "staleName": stale_name,
            "staleSince": (
                datetime.fromtimestamp(version / 1000, timezone.utc).isoformat()
                if isinstance(version, int)
                else None
            ),
        })
    return found


def touch(api: DiscordApi, channel_id: str, payload: dict) -> None:
    """One PATCH, re-checking the boundary at the point of the write."""
    if channel_id not in order.CHANNEL_IDS:
        raise VisualPassError("gateway resync escaped its boundary")
    if "name" in payload and payload["name"] not in order.APPROVED_NAMES_BY_ID[channel_id]:
        raise VisualPassError(f"gateway resync refused unapproved name {payload['name']!r}")
    api.request("PATCH", f"/channels/{channel_id}", payload)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true", help="actually write to Discord")
    parser.add_argument(
        "--allow-name-toggle",
        action="store_true",
        help="permit strategy 2, which briefly makes the authoritative store show two live desks",
    )
    args = parser.parse_args()

    values = load_env(ENV_FILE)
    if values.get("DISCORD_GUILD_ID") != order.PRODUCTION_GUILD_ID:
        raise VisualPassError("env does not point at the production guild")
    token = values["DISCORD_BOT_TOKEN"]
    api = DiscordApi(token)

    def read_rest() -> dict[str, str]:
        rows = api.get(f"/guilds/{order.PRODUCTION_GUILD_ID}/channels")
        return {
            str(r["id"]): str(r["name"])
            for r in rows
            if str(r.get("id")) in order.CHANNEL_IDS
        }

    rest_before = read_rest()
    gw_before = gateway_names(token)
    diverged = divergences(rest_before, gw_before)

    print("session channels, authoritative (REST) vs rendered (gateway):")
    for channel_id in sorted(order.CHANNEL_IDS):
        rest_name = rest_before.get(channel_id, "?")
        gw_name = gw_before.get(channel_id, {}).get("name", "?")
        flag = "  " if rest_name == gw_name else "<-- DIVERGED"
        print(f"  {channel_id}  rest={rest_name!r:38} gateway={gw_name!r:38} {flag}")

    live_rest = sum(1 for n in rest_before.values() if n.endswith(order.LIVE_MARKER))
    live_gw = sum(
        1 for c in gw_before.values() if str(c.get("name", "")).endswith(order.LIVE_MARKER)
    )
    print(f"\nlive desks: REST says {live_rest}, a client sees {live_gw}")

    if not diverged:
        print("\nnothing to repair — the cache already matches the authoritative store.")
        return 0

    for row in diverged:
        print(
            f"\nstale: {row['id']}\n"
            f"  authoritative {row['trueName']!r}\n"
            f"  clients see   {row['staleName']!r}\n"
            f"  cached since  {row['staleSince']}"
        )

    if not args.apply:
        print("\nDRY RUN — nothing written. Pass --apply to force the resync.")
        return 0

    attempts: list[dict] = []
    with order.single_run() as acquired:
        if not acquired:
            print("\nreconciler is mid-handoff; not writing. Re-run in a minute.")
            return 0

        for row in diverged:
            touch(api, row["id"], {"rate_limit_per_user": 1})
            touch(api, row["id"], {"rate_limit_per_user": 0})
            attempts.append({"id": row["id"], "strategy": "SLOWMODE"})

        gw_after = gateway_names(token)
        still = divergences(read_rest(), gw_after)

        if still and args.allow_name_toggle:
            for row in still:
                # Deliberate: the first write makes the authoritative store agree
                # with what clients are already showing, the second corrects both.
                touch(api, row["id"], {"name": row["staleName"]})
                touch(api, row["id"], {"name": row["trueName"]})
                attempts.append({"id": row["id"], "strategy": "NAME_TOGGLE"})
            gw_after = gateway_names(token)
            still = divergences(read_rest(), gw_after)

    rest_after = read_rest()
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    directory = RECEIPT_ROOT / stamp
    directory.mkdir(parents=True, exist_ok=True)
    receipt = {
        "schemaVersion": "btg.discord.gateway-resync.v1",
        "capturedAt": datetime.now(timezone.utc).isoformat(),
        "guildId": order.PRODUCTION_GUILD_ID,
        "operation": "RESYNCED" if not still else "STILL_DIVERGED",
        "divergedBefore": diverged,
        "divergedAfter": still,
        "attempts": attempts,
        "restBefore": rest_before,
        "restAfter": rest_after,
        "gatewayBefore": {k: v.get("name") for k, v in gw_before.items()},
        "gatewayAfter": {k: v.get("name") for k, v in gw_after.items()},
        "liveDesksRestAfter": sum(
            1 for n in rest_after.values() if n.endswith(order.LIVE_MARKER)
        ),
        "liveDesksGatewayAfter": sum(
            1 for c in gw_after.values() if str(c.get("name", "")).endswith(order.LIVE_MARKER)
        ),
    }
    (directory / "receipt.json").write_text(
        json.dumps(receipt, indent=2, ensure_ascii=False)
    )

    print(f"\nreceipt        {directory}")
    print(f"gateway now    {receipt['gatewayAfter']}")
    print(
        f"live desks     REST {receipt['liveDesksRestAfter']}, "
        f"client {receipt['liveDesksGatewayAfter']}"
    )
    if still:
        print("\nSTILL DIVERGED. Re-run with --allow-name-toggle.")
        return 1
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except VisualPassError as error:
        print(f"REFUSED: {error}", file=sys.stderr)
        raise SystemExit(2)
