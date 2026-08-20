#!/usr/bin/env python3
"""Regression tests for the gateway-divergence watcher.

The failure mode worth guarding is not a crash. It is a watcher that runs
happily every ten minutes and never says anything — which is indistinguishable
from a healthy surface right up until Dean reports two live desks for the fifth
time. So the tests below drive the DIVERGED path hardest: that a real stale
cache alerts, that a mid-handoff blip does not, that a persisting fault does not
alert 57 times, and that finding a fault never exits non-zero (which would fire
the W4 OnFailure alert and conflate "production is wrong" with "the detector
broke").
"""

from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
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

_wspec = importlib.util.spec_from_file_location(
    "discord_gateway_divergence_watch", HERE / "discord-gateway-divergence-watch.py"
)
watch = importlib.util.module_from_spec(_wspec)
_wspec.loader.exec_module(watch)

ASIA, LONDON, NEW_YORK = sorted(order.CHANNEL_IDS)
VERSION = 1786968001875


def base(channel_id: str) -> str:
    return order.BASE_NAME_BY_ID[channel_id]


def live(channel_id: str) -> str:
    return order.LIVE_NAME_BY_ID[channel_id]


IN_SYNC = {ASIA: base(ASIA), LONDON: base(LONDON), NEW_YORK: live(NEW_YORK)}
# What production actually looked like for 9.5 hours on 2026-08-17.
STALE_LONDON = dict(IN_SYNC, **{LONDON: live(LONDON)})


class FakeApi:
    def __init__(self, rest_states: list[dict[str, str]]) -> None:
        self.rest_states = rest_states
        self.calls = 0

    def get(self, path: str):
        names = self.rest_states[min(self.calls, len(self.rest_states) - 1)]
        self.calls += 1
        return [{"id": cid, "name": n} for cid, n in names.items()]


class FakeResync:
    """Stands in for the resync module, reusing its real `divergences`."""

    ENV_FILE = Path("/nonexistent")
    VisualPassError = VisualPassError
    order = order
    divergences = staticmethod(resync.divergences)

    def __init__(self, rest_states, gateway_states, guild=None) -> None:
        self._rest_states = rest_states
        self._gateway_states = gateway_states
        self._gateway_calls = 0
        self._guild = guild or order.PRODUCTION_GUILD_ID
        self.api = FakeApi(rest_states)

    def load_env(self, _path):
        return {"DISCORD_GUILD_ID": self._guild, "DISCORD_BOT_TOKEN": "token"}

    def DiscordApi(self, _token):  # noqa: N802 - mirrors the real constructor
        return self.api

    def gateway_names(self, _token):
        names = self._gateway_states[
            min(self._gateway_calls, len(self._gateway_states) - 1)
        ]
        self._gateway_calls += 1
        return {cid: {"id": cid, "name": n, "version": VERSION} for cid, n in names.items()}


class WatcherCase(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        root = Path(self._tmp.name)
        self._orig = (watch.STATE_DIR, watch.STATE_FILE, watch.LOG_FILE, watch.alert)
        watch.STATE_DIR = root
        watch.STATE_FILE = root / "state.json"
        watch.LOG_FILE = root / "watch.jsonl"
        self.alerts: list[str] = []
        watch.alert = self.alerts.append
        self.root = root
        # The confirm delay is real time; nothing here needs to actually wait.
        self._sleep = watch.time.sleep
        watch.time.sleep = lambda _s: None
        self.addCleanup(self._restore)

    def _restore(self) -> None:
        watch.STATE_DIR, watch.STATE_FILE, watch.LOG_FILE, watch.alert = self._orig
        watch.time.sleep = self._sleep
        self._tmp.cleanup()

    def run_watch(self, rest_states, gateway_states, argv=None, guild=None) -> int:
        fake = FakeResync(rest_states, gateway_states, guild=guild)
        orig_load, orig_argv = watch.load_resync, sys.argv
        watch.load_resync = lambda: fake
        sys.argv = ["watch", "--quiet"] + (argv or [])
        try:
            return watch.main()
        finally:
            watch.load_resync, sys.argv = orig_load, orig_argv

    def state(self) -> dict:
        return watch.read_state()

    def receipts(self) -> list[Path]:
        return [p for p in self.root.iterdir() if p.is_dir()]

    def log_rows(self) -> list[dict]:
        if not watch.LOG_FILE.exists():
            return []
        return [json.loads(l) for l in watch.LOG_FILE.read_text().splitlines() if l]


class CleanRuns(WatcherCase):
    def test_in_sync_says_nothing_and_leaves_no_receipt(self) -> None:
        rc = self.run_watch([IN_SYNC], [IN_SYNC])
        self.assertEqual(rc, 0)
        self.assertEqual(self.alerts, [])
        self.assertEqual(self.receipts(), [])
        self.assertEqual(self.state(), {})

    def test_a_clean_run_still_appends_one_log_line(self) -> None:
        """Cheap enough at 144/day, and it is the only evidence the watcher ran."""
        self.run_watch([IN_SYNC], [IN_SYNC])
        rows = self.log_rows()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["divergedIds"], [])
        self.assertEqual(rows[0]["liveRest"], 1)
        self.assertEqual(rows[0]["liveGateway"], 1)

    def test_clean_runs_never_create_directories(self) -> None:
        """144 runs/day leaving a dir each rebuilds the 9,016-dir problem."""
        for _ in range(20):
            self.run_watch([IN_SYNC], [IN_SYNC])
        self.assertEqual(self.receipts(), [])


class TransientHandoff(WatcherCase):
    def test_a_mid_handoff_blip_is_not_reported(self) -> None:
        """REST writes, the cache follows a beat later. That is not a fault.

        Without the confirm read this alerts at every single handoff — three
        false alarms a day, which is how a real alert gets ignored.
        """
        rc = self.run_watch(
            [IN_SYNC, IN_SYNC],
            [STALE_LONDON, IN_SYNC],  # stale on first read, caught up on second
        )
        self.assertEqual(rc, 0)
        self.assertEqual(self.alerts, [])
        self.assertEqual(self.receipts(), [])
        self.assertEqual(self.state(), {})

    def test_the_transient_is_still_recorded(self) -> None:
        self.run_watch([IN_SYNC, IN_SYNC], [STALE_LONDON, IN_SYNC])
        rows = self.log_rows()
        self.assertEqual(rows[0]["divergedIds"], [])
        self.assertEqual(rows[0]["transientIds"], [LONDON])


class RealDivergence(WatcherCase):
    def test_a_surviving_divergence_alerts_and_leaves_a_receipt(self) -> None:
        rc = self.run_watch(
            [IN_SYNC, IN_SYNC], [STALE_LONDON, STALE_LONDON]
        )
        self.assertEqual(rc, 0, "a finding is not a malfunction — must not exit non-zero")
        self.assertEqual(len(self.alerts), 1)
        self.assertIn("clients see 2 live desk", self.alerts[0])
        self.assertIn("the authoritative store has 1", self.alerts[0])
        self.assertIn(live(LONDON), self.alerts[0])
        self.assertIn("discord-gateway-resync.py --apply", self.alerts[0])
        self.assertEqual(len(self.receipts()), 1)

    def test_the_alert_says_it_will_not_self_heal(self) -> None:
        """The 08-17 fault outlived two handoffs. Anyone paged must know that."""
        self.run_watch([IN_SYNC, IN_SYNC], [STALE_LONDON, STALE_LONDON])
        self.assertIn("will not clear at the next handoff", self.alerts[0])

    def test_the_receipt_records_both_surfaces(self) -> None:
        self.run_watch([IN_SYNC, IN_SYNC], [STALE_LONDON, STALE_LONDON])
        payload = json.loads((self.receipts()[0] / "receipt.json").read_text())
        self.assertEqual(payload["rest"][LONDON], base(LONDON))
        self.assertEqual(payload["gateway"][LONDON], live(LONDON))
        self.assertEqual(payload["liveRest"], 1)
        self.assertEqual(payload["liveGateway"], 2)
        self.assertEqual(payload["diverged"][0]["id"], LONDON)

    def test_no_marker_anywhere_on_the_client_is_caught(self) -> None:
        """REST grants the marker, the cache never shows it: nobody sees a live desk."""
        rest = IN_SYNC
        cached = dict(IN_SYNC, **{NEW_YORK: base(NEW_YORK)})
        self.run_watch([rest, rest], [cached, cached])
        self.assertEqual(len(self.alerts), 1)
        self.assertIn("clients see 0 live desk", self.alerts[0])
        self.assertIn("the authoritative store has 1", self.alerts[0])

    def test_a_swapped_divergence_is_caught_despite_matching_counts(self) -> None:
        """The nastiest shape: one marker on BOTH surfaces, on DIFFERENT desks.

        London has handed over to New York in the authoritative store, but the
        cache still shows London live and New York not. Every marker COUNT reads
        healthy — `live_marker_census()` would pass this — while every client is
        looking at the wrong desk.
        """
        rest = IN_SYNC
        cached = dict(IN_SYNC, **{LONDON: live(LONDON), NEW_YORK: base(NEW_YORK)})
        self.run_watch([rest, rest], [cached, cached])
        self.assertEqual(len(self.alerts), 1)
        self.assertIn("showing the wrong desk live", self.alerts[0])
        self.assertIn(live(LONDON), self.alerts[0])
        payload = json.loads((self.receipts()[0] / "receipt.json").read_text())
        self.assertEqual(payload["liveRest"], payload["liveGateway"])
        self.assertEqual(
            sorted(r["id"] for r in payload["diverged"]), sorted([LONDON, NEW_YORK])
        )


class AlertBudget(WatcherCase):
    def test_a_persisting_fault_does_not_alert_every_run(self) -> None:
        """9.5 hours at one run per 10 minutes would have been ~57 messages."""
        for _ in range(6):
            self.run_watch([IN_SYNC, IN_SYNC], [STALE_LONDON, STALE_LONDON])
        self.assertEqual(len(self.alerts), 1)

    def test_it_re_alerts_once_the_window_passes(self) -> None:
        self.run_watch([IN_SYNC, IN_SYNC], [STALE_LONDON, STALE_LONDON])
        stale_state = self.state()
        stale_state["lastAlerted"] = (
            datetime.now(timezone.utc) - watch.REALERT_AFTER - timedelta(minutes=1)
        ).isoformat()
        watch.write_state(stale_state)
        self.run_watch([IN_SYNC, IN_SYNC], [STALE_LONDON, STALE_LONDON])
        self.assertEqual(len(self.alerts), 2)

    def test_first_seen_survives_re_alerting(self) -> None:
        self.run_watch([IN_SYNC, IN_SYNC], [STALE_LONDON, STALE_LONDON])
        first = self.state()["firstSeen"]
        for _ in range(3):
            self.run_watch([IN_SYNC, IN_SYNC], [STALE_LONDON, STALE_LONDON])
        self.assertEqual(self.state()["firstSeen"], first)

    def test_a_second_channel_diverging_is_a_new_fault(self) -> None:
        self.run_watch([IN_SYNC, IN_SYNC], [STALE_LONDON, STALE_LONDON])
        both = dict(STALE_LONDON, **{ASIA: live(ASIA)})
        self.run_watch([IN_SYNC, IN_SYNC], [both, both])
        self.assertEqual(len(self.alerts), 2)
        self.assertEqual(self.state()["divergedIds"], sorted([ASIA, LONDON]))


class Recovery(WatcherCase):
    def test_clearing_alerts_once_and_resets(self) -> None:
        self.run_watch([IN_SYNC, IN_SYNC], [STALE_LONDON, STALE_LONDON])
        self.alerts.clear()
        rc = self.run_watch([IN_SYNC], [IN_SYNC])
        self.assertEqual(rc, 0)
        self.assertEqual(len(self.alerts), 1)
        self.assertIn("back in sync", self.alerts[0])
        self.assertEqual(self.state(), {})

    def test_it_does_not_announce_recovery_it_never_saw_break(self) -> None:
        self.run_watch([IN_SYNC], [IN_SYNC])
        self.assertEqual(self.alerts, [])


class Boundary(WatcherCase):
    def test_it_refuses_a_non_production_guild(self) -> None:
        """The same guard the resync carries: never point this at DEV by accident."""
        with self.assertRaises(VisualPassError):
            self.run_watch([IN_SYNC], [IN_SYNC], guild="1531755272987607201")

    def test_it_never_writes_to_discord_without_repair(self) -> None:
        """Detection is read-only. The repair stays a deliberate, separate act."""
        fake = FakeResync([IN_SYNC, IN_SYNC], [STALE_LONDON, STALE_LONDON])
        orig_load, orig_argv = watch.load_resync, sys.argv
        watch.load_resync = lambda: fake
        sys.argv = ["watch", "--quiet"]
        try:
            watch.main()
        finally:
            watch.load_resync, sys.argv = orig_load, orig_argv
        # FakeApi only implements get(); any write would have raised AttributeError.
        self.assertFalse(hasattr(fake.api, "patch"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
