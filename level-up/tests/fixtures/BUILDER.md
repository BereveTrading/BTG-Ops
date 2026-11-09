# BUILDER lanes — fixture (repo path @REPO@ is filled in by the test)

## Lane L1 — Live bar drops on reconnect
- Key: K-app-live-bar-reconnect
- Build: keep the live bar after a socket reconnect.
- Pass: the live bar is present after reconnect in the unit test.
- Files: apps/vision/src/live.ts
- Tests: live.reconnect.test.ts first; vitest.
- Repo: @REPO@
- Size: S
- Class: bug
- Ruling needed: no

## Lane L2 — New header readout
- Key: K-visual-header-readout
- Build: add a readout.
- Pass: visible.
- Files: x
- Tests: y
- Repo: @REPO@
- Size: S
- Class: upgrade
- Ruling needed: no

## Lane L3 — Pricing copy
- Key: K-app-pricing-copy
- Build: change copy.
- Pass: copy.
- Files: x
- Tests: y
- Repo: @REPO@
- Size: S
- Class: bug
- Ruling needed: yes

## Lane L4 — Big refactor
- Key: K-engine-refactor
- Build: refactor.
- Pass: tests.
- Files: x
- Tests: y
- Repo: @REPO@
- Size: M
- Class: bug
- Ruling needed: no

## Lane L5 — Repo outside the allow list
- Key: K-zed-axis
- Build: fix axis.
- Pass: axis ok.
- Files: x
- Tests: y
- Repo: /home/dean/btg/BTG-Discord
- Size: S
- Class: bug
- Ruling needed: no

## Lane L6 — Second eligible bug
- Key: K-engine-crosshair
- Build: fix crosshair rounding.
- Pass: rounding test passes.
- Files: x
- Tests: y
- Repo: @REPO@
- Size: S
- Class: bug
- Ruling needed: no

## Lane L7 — Third eligible bug (over the cap)
- Key: K-engine-third
- Build: fix third.
- Pass: ok.
- Files: x
- Tests: y
- Repo: @REPO@
- Size: S
- Class: bug
- Ruling needed: no
