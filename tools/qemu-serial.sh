#!/usr/bin/env bash
# Run a command on the test VM's serial shell and print what comes back.
# Usage: tools/qemu-serial.sh '<command>' [wait seconds] [logdir]
CMD=$1; WAIT=${2:-3}; LOG=${3:-/tmp/churro-qemu}
before=$(stat -c %s "$LOG/serial.log")
{ printf '%s\r' "$CMD"; sleep "$WAIT"; } | socat - UNIX-CONNECT:"$LOG/serial.sock" >/dev/null 2>&1
tail -c +$((before + 1)) "$LOG/serial.log" | sed 's/\x1b\[[0-9;=?]*[A-Za-z]//g' | tr -d '\r'
