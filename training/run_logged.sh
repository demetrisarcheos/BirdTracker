#!/usr/bin/env bash
# Runs a command; on failure posts the last log lines as a GitHub annotation, which can be
# read through the public API without signing in.
#   usage: training/run_logged.sh "Step title" command args...
title="$1"; shift
log=$(mktemp)
"$@" 2>&1 | tee "$log"
code=${PIPESTATUS[0]}
if [ "$code" -ne 0 ]; then
  msg=$(tr '\r' '\n' < "$log" | grep -v '^[[:space:]]*$' | tail -15 | cut -c1-240 \
        | sed 's/%/%25/g' | awk '{printf "%s%%0A", $0}')
  echo "::error title=${title} failed::${msg}"
fi
exit "$code"
