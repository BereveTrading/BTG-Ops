#!/usr/bin/env python3
"""Regression tests for the gateway-vs-REST divergence detector.

The bug these guard against is not a crash — it is the detector quietly
agreeing with REST, which is precisely what let three separate investigations
tell Dean the server was clean while his client rendered two live desks.
"""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, "/home/dean/btg/wt-production-session-order-v1/apps/discord-admin")

import production_session_order as order  # noqa: E402
from discord_interface_visual_pass import VisualPassError  # noqa: E402

_spec = importlib.util.spec_from_file_location(
    "discord_gateway_resync", HERE / "discord-gateway-resync.py"
)
resync = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(resync)

ASIA, LONDON, NEW_YORK = sorted(order.CHANNEL_IDS)


def base(channel_id: str) -> str:
    return order.BASE_NAME_BY_ID[channel_id]


def live(channel_id: str) -> str:
    return order.LIVE_NAME_BY_ID[channel_id]


def gw(names: dict[str, str], version: int = 1786968001875) -> dict[str, dict]:
    return {cid: {"id": cid, "name": n, "version": version} for cid, n in names.items()}


class DivergenceDetection(unittest.TestCase):
    def test_agreement_is_not_a_divergence(self) -> None:
        names = {ASIA: base(ASIA), LONDON: base(LONDON), NEW_YORK: live(NEW_YORK)}
        self.assertEqual(resync.divergences(names, gw(names)), [])

    def test_the_2026_08_17_production_state(self) -> None:
        """REST says one desk is live; a client renders two. The real reading."""
        rest = {ASIA: base(ASIA), LONDON: base(LONDON), NEW_YORK: live(NEW_YORK)}
        cached = dict(rest, **{LONDON: live(LONDON)})
        found = resync.divergences(rest, gw(cached))
        self.assertEqual(len(found), 1)
        self.assertEqual(found[0]["id"], LONDON)
        self.assertEqual(found[0]["trueName"], base(LONDON))
        self.assertEqual(found[0]["staleName"], live(LONDON))
        self.assertEqual(found[0]["staleSince"], "2026-08-17T12:00:01.875000+00:00")

    def test_a_stale_cache_can_hide_a_live_desk_too(self) -> None:
        """The inverse: REST grants the marker, the cache never shows it.

        Symptom is 'no session is live' rather than two, so it would never be
        reported as this bug — but it is the same defect and must be detected.
        """
        rest = {ASIA: base(ASIA), LONDON: live(LONDON), NEW_YORK: base(NEW_YORK)}
        cached = dict(rest, **{LONDON: base(LONDON)})
        found = resync.divergences(rest, gw(cached))
        self.assertEqual([r["id"] for r in found], [LONDON])

    def test_every_channel_can_be_diverged_at_once(self) -> None:
        rest = {ASIA: live(ASIA), LONDON: base(LONDON), NEW_YORK: base(NEW_YORK)}
        cached = {ASIA: base(ASIA), LONDON: live(LONDON), NEW_YORK: live(NEW_YORK)}
        self.assertEqual(
            [r["id"] for r in resync.divergences(rest, gw(cached))],
            sorted(order.CHANNEL_IDS),
        )

    def test_a_hand_renamed_channel_is_refused_not_repaired(self) -> None:
        """Converging a name this repo never approved would be a silent rewrite."""
        rest = {ASIA: base(ASIA), LONDON: "🇬🇧・london-session-OLD", NEW_YORK: live(NEW_YORK)}
        with self.assertRaises(VisualPassError):
            resync.divergences(rest, gw(dict(rest, **{LONDON: base(LONDON)})))

    def test_an_unapproved_cached_name_is_also_refused(self) -> None:
        rest = {ASIA: base(ASIA), LONDON: base(LONDON), NEW_YORK: live(NEW_YORK)}
        with self.assertRaises(VisualPassError):
            resync.divergences(rest, gw(dict(rest, **{LONDON: "🇬🇧・london-session・LIVE"})))

    def test_a_channel_missing_from_either_read_is_skipped_quietly(self) -> None:
        """A partial read must not be reported as a divergence to repair."""
        rest = {ASIA: base(ASIA), LONDON: base(LONDON), NEW_YORK: live(NEW_YORK)}
        self.assertEqual(resync.divergences(rest, gw({ASIA: base(ASIA)})), [])
        self.assertEqual(resync.divergences({ASIA: base(ASIA)}, gw(rest)), [])


class WriteBoundary(unittest.TestCase):
    class Recorder:
        def __init__(self) -> None:
            self.calls: list[tuple[str, str, dict]] = []

        def request(self, method: str, path: str, payload: dict) -> dict:
            self.calls.append((method, path, payload))
            return {}

    def test_an_unmanaged_channel_is_refused(self) -> None:
        api = self.Recorder()
        with self.assertRaises(VisualPassError):
            resync.touch(api, "1433907808700727451", {"rate_limit_per_user": 1})
        self.assertEqual(api.calls, [])

    def test_an_unapproved_name_is_refused_at_the_write(self) -> None:
        api = self.Recorder()
        with self.assertRaises(VisualPassError):
            resync.touch(api, LONDON, {"name": "🇬🇧・london-session・🔴LIVE"})
        self.assertEqual(api.calls, [])

    def test_slowmode_never_sends_a_name(self) -> None:
        api = self.Recorder()
        resync.touch(api, LONDON, {"rate_limit_per_user": 1})
        resync.touch(api, LONDON, {"rate_limit_per_user": 0})
        self.assertEqual(
            api.calls,
            [
                ("PATCH", f"/channels/{LONDON}", {"rate_limit_per_user": 1}),
                ("PATCH", f"/channels/{LONDON}", {"rate_limit_per_user": 0}),
            ],
        )

    def test_both_approved_names_are_writable(self) -> None:
        api = self.Recorder()
        resync.touch(api, LONDON, {"name": live(LONDON)})
        resync.touch(api, LONDON, {"name": base(LONDON)})
        self.assertEqual([c[2]["name"] for c in api.calls], [live(LONDON), base(LONDON)])


if __name__ == "__main__":
    unittest.main()
