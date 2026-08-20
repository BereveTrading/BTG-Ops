#!/usr/bin/env python3
"""Propose-only idea digest for the BTG-Rebuild vault.

Read-only: pulls Jarvis's own `awareness` snapshot (spec queue state,
flagged memory claims, recent git activity) — zero mutation, zero agent
spawn, per docs/decisions/PLAN_jarvis_awareness.md — asks Claude to turn
that grounded snapshot into a short list of concrete next moves, and sends
the result to Telegram. Writes NOTHING: no spec files, no git changes, no
enqueue. Per GOVERNANCE.md's ruling ("No file is ever written without my
ack in that session"), anything from this digest that Zen wants to pursue
still goes through a live session and the normal Jarvis draft->review flow.

  source ~/btg/state/discord-bot.env ~/btg/state/telegram-bot.env
  python3 idea-digest.py
"""
import json
import os
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

REPO = "/home/dean/btg/BTG-Rebuild"
MODEL = "claude-sonnet-5"

PROMPT = """You are looking at a read-only snapshot of the BTG-Rebuild trading \
platform's spec-driven vault (specs/*.md queue state, flagged memory \
claims, recent git activity). Propose at most 5 concrete next moves.

Rules:
- Every proposal must cite a SPECIFIC item from the snapshot below (a named \
Approved-but-undispatched spec, a named flagged memory claim, a specific \
recent commit/branch) — no generic advice, nothing ungrounded.
- Prefer surfacing existing undone work (e.g. an Approved spec nobody has \
built) over inventing new scope.
- Each proposal: one line, <220 chars, plain text, no markdown formatting.
- If nothing concrete stands out, say so plainly instead of padding the list.

Snapshot:
"""


def get_snapshot() -> str:
    out = subprocess.run(
        [sys.executable, "-m", "awareness", "--json"],
        cwd=REPO, capture_output=True, text=True, timeout=30, check=True,
    )
    return out.stdout.strip()


def ask_claude(snapshot_json: str) -> str:
    api_key = os.environ["ANTHROPIC_API_KEY"]
    body = json.dumps({
        "model": MODEL,
        "max_tokens": 1024,
        "messages": [{"role": "user", "content": PROMPT + snapshot_json}],
    }).encode()
    req = urllib.request.Request(
        "https://api.anthropic.com/v1/messages",
        data=body,
        method="POST",
        headers={
            "x-api-key": api_key,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
        },
    )
    # Read the API's own error body. Without this the job failed silently for
    # 9 consecutive runs (Jul 23 - Aug 20 2026): the journal showed only
    # "HTTP Error 400: Bad Request", never the reason, which is the one thing
    # needed to fix it.
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            d = json.load(r)
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace").strip()[:800]
        raise RuntimeError(
            f"Anthropic API refused the request: HTTP {e.code} {e.reason} - {detail}"
        ) from None
    return "".join(b["text"] for b in d["content"] if b["type"] == "text").strip()


def send_telegram(text: str) -> None:
    tok = os.environ["TELEGRAM_BOT_TOKEN"].strip()
    cid = open(os.path.expanduser("~/btg/state/.telegram-chatid")).read().strip()
    body = urllib.parse.urlencode({
        "chat_id": cid,
        "text": f"\U0001F4A1 Vault idea digest (propose-only, nothing written):\n\n{text}",
    }).encode()
    req = urllib.request.Request(
        f"https://api.telegram.org/bot{tok}/sendMessage", data=body, method="POST",
    )
    with urllib.request.urlopen(req, timeout=15) as r:
        d = json.load(r)
    print("sent ok" if d.get("ok") else f"telegram FAIL: {d}")


def main() -> int:
    snapshot = get_snapshot()
    digest = ask_claude(snapshot)
    send_telegram(digest)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
