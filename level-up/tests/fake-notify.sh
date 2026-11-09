#!/usr/bin/env bash
# Test double for tg-text.sh: records the message, sends nothing.
printf '%s\n===\n' "$1" >>"${FAKE_NOTIFY_OUT:?}"
