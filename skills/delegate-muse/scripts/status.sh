#!/usr/bin/env bash
# delegate-muse — peek at a delegation without touching it. Read-only.
#
# Usage: status.sh <slug>
# Prints ONE JSON object: {agent, herdr_status, spinning, pending_turn, waiter_running,
#   commits, dirty, screen}. `spinning` (the braille spinner Muse puts in the pane
#   title) is the live "Muse is working" signal; herdr_status alone reads idle too early.
set -euo pipefail

die() { echo "status.sh: $*" >&2; exit 2; }

[[ $# -eq 1 ]] || die "usage: status.sh <slug>"
slug=$1
repo=$(git rev-parse --show-toplevel) || die "not inside a git repository"
common=$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir)
state="$common/delegate-muse/$slug"
[[ -f $state/state.json ]] || die "no delegation named $slug"

python3 - "$state" <<'EOF'
import json, os, subprocess, sys

state = sys.argv[1]
s = json.load(open(os.path.join(state, "state.json")))

def run(*args):
    return subprocess.run(list(args), capture_output=True, text=True).stdout

try:
    a = json.loads(run("herdr", "agent", "get", s["agent"]))["result"]["agent"]
    status, title = a["agent_status"], a.get("terminal_title") or ""
except (ValueError, KeyError):
    status, title = "gone", ""
waiter = False
try:
    os.kill(int(open(os.path.join(state, "lock", "pid")).read()), 0)
    waiter = True
except (OSError, ValueError):
    pass
wt = s["worktree"]
lines = run("herdr", "agent", "read", s["agent"], "--source", "recent-unwrapped", "--lines", "30")
print(json.dumps({
    "agent": s["agent"], "pane": s["pane"], "herdr_status": status,
    "spinning": bool(title) and "⠀" <= title[0] <= "⣿",
    "pending_turn": (s.get("pending") or {}).get("turn"), "turns_done": s["turns"],
    "waiter_running": waiter,
    "commits": run("git", "-C", wt, "log", "--oneline", f"{s['base']}..{s['branch']}").split("\n")[:-1],
    "dirty": run("git", "-C", wt, "status", "--porcelain").split("\n")[:-1],
    "screen": [l.rstrip() for l in lines.splitlines() if l.strip()][-20:],
}, indent=2, ensure_ascii=False))
EOF
