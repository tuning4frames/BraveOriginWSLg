#!/bin/bash
# Nuclear shutdown for the Brave app: kills every process this app spawned.
# Safe to run stand-alone or from the control sidecar.
#
# NATIVE MODE: no Xtigervnc / openbox / websockify. We only tear down Brave
# and the control sidecar (port 9612).
#
# Strategy (belt-and-suspenders, in order):
#   1. Walk the process tree from /run/brave.pid down: catches every child
#      that start.sh spawned (including anything that reparented to init).
#   2. fuser -k on our port: catches anything holding 9612 that somehow
#      escaped the tree (daemons that called setpgrp/setsid).
#   3. pkill -9 by short name: final paranoia net for brave.

set +e

SELF_PID=$$
kill_tree() {
    local pid=$1
    [ -z "$pid" ] && return
    [ "$pid" = "$SELF_PID" ] && return
    local children
    children=$(pgrep -P "$pid" 2>/dev/null)
    for c in $children; do
        [ "$c" = "$SELF_PID" ] && continue
        kill_tree "$c"
    done
    kill -KILL "$pid" 2>/dev/null
}

# 1. Walk the tree from the saved start.sh PID
if [ -f /run/brave.pid ]; then
    ROOT_PID=$(cat /run/brave.pid 2>/dev/null)
    kill_tree "$ROOT_PID"
    rm -f /run/brave.pid
fi

# 2. Nuke anything still holding our port
fuser -k 9612/tcp 2>/dev/null

# 3. Short-name sweep for stragglers
pkill -9 brave 2>/dev/null
pkill -9 -f brave-origin-nightly 2>/dev/null

exit 0
