#!/usr/bin/env python3
"""delegate-muse — submit one prompt to the Muse pane (or keep waiting on the pending one) and
block until Muse's own session log records the end of that turn or a question for the user.

Usage (from turn.sh, which holds the lock and wrote the prompt file):
    _turn.py <state-dir> send|wait

herdr runs and displays Muse, but the turn boundary is read from Muse's session log
(~/.local/share/muse/sessions/<date>/<session>/session.jsonl): herdr's Muse profile (written
for Muse 0.2.1) reports idle 10-15 s early — during Muse's end-of-turn check —, misses a
question picker whose footer wraps in a narrow pane, and reports `blocked` while Muse's own
approval judge (Auto-review) is still reviewing a command. The log states all three exactly;
herdr's `blocked` is only a last resort when the log has gone quiet.
"""
import json
import os
import re
import signal
import subprocess
import sys
import time

POLL_S = 2.0
START_GRACE_S = 90        # our prompt must show up as a run in the log within this
INPUT_SETTLE_POLLS = 2    # a question/approval wait must persist this many polls
QUIET_BLOCKED_S = 60      # herdr `blocked` counts only after the log has been quiet this long
SESSIONS = os.path.join(os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share"),
                        "muse", "sessions")


def herdr(*args):
    r = subprocess.run(["herdr", *args], capture_output=True, text=True)
    out = (r.stdout or r.stderr).strip()
    try:
        data = json.loads(out)
    except ValueError:
        data = {"error": {"code": "unparsed_output", "message": out}}
    if r.returncode != 0 and "error" not in data:
        data = {"error": {"code": "exit_%d" % r.returncode, "message": out}}
    return data


def screen(agent, lines=40):
    r = subprocess.run(["herdr", "agent", "read", agent, "--source", "recent-unwrapped",
                        "--lines", str(lines)], capture_output=True, text=True)
    return [l.rstrip() for l in r.stdout.splitlines() if l.strip()][-lines:]


def find_log(needle, since, known):
    """The session.jsonl that recorded our prompt: the known one first, then any recent one."""
    paths = [known] if known and os.path.exists(known) else []
    for root, dirs, files in os.walk(SESSIONS):
        dirs[:] = [d for d in dirs if not d.startswith(".") and d not in
                   ("subagent", "tool-outputs", "approval-review")]
        if "session.jsonl" in files:
            p = os.path.join(root, "session.jsonl")
            if p != known and os.path.getmtime(p) >= since - 5:
                paths.append(p)
    for p in paths:
        with open(p, errors="replace") as f:
            if needle in f.read():
                return p
    return None


class Run:
    """Incremental reader of one session log, tracking the run whose prompt holds `needle`."""

    def __init__(self, path, needle):
        self.f = open(path, errors="replace")
        self.needle = needle
        self.run_id = None
        self.text = ""
        self.terminal = None
        self.inputs = {}          # prompt_id -> questions, requested and not yet settled
        self.approvals = {}       # pending_action_id -> {tool, command, reviewing}, undecided
        self.buf = ""
        self.last_growth = time.time()

    def waiting_on_user(self):
        """Questions and approvals that only a person can answer now."""
        return ([q for qs in self.inputs.values() for q in qs],
                [{"tool": a["tool"], "command": a["command"]}
                 for a in self.approvals.values() if not a["reviewing"]])

    def poll(self):
        chunk = self.f.read()
        if chunk:
            self.last_growth = time.time()
        self.buf += chunk
        *lines, self.buf = self.buf.split("\n")
        for line in lines:
            try:
                d = json.loads(line)
            except ValueError:
                continue
            p = d.get("payload") or {}
            ev = p.get("event") if isinstance(p.get("event"), dict) else {}
            kind = ev.get("kind")
            if p.get("kind") == "run" and kind == "started" and self.needle in (ev.get("prompt") or ""):
                self.run_id, self.text, self.terminal = p.get("run_id"), "", None
                self.inputs, self.approvals = {}, {}
                continue
            if kind == "user_input_prompt_settled":
                self.inputs.pop(ev.get("prompt_id"), None)
                continue
            if p.get("kind") == "approval":
                aid = ev.get("pending_action_id")
                if kind == "requested" and p.get("run_id") == self.run_id:
                    subject = ev.get("approval_subject") or {}
                    self.approvals[aid] = {"tool": ev.get("tool_name"), "reviewing": False,
                                           "command": subject.get("raw_command") or ev.get("raw_args")}
                elif kind == "automated_review_started" and aid in self.approvals:
                    self.approvals[aid]["reviewing"] = True
                elif kind == "automated_review_completed" and aid in self.approvals:
                    self.approvals[aid]["reviewing"] = False
                elif kind == "decision_applied":
                    self.approvals.pop(aid, None)
                continue
            if p.get("kind") == "approval_wait_effect" and (p.get("record") or {}).get("kind") == "terminal":
                self.approvals.pop(p["record"].get("pending_action_id"), None)
                continue
            if self.run_id is None or p.get("run_id") != self.run_id:
                continue
            if kind == "assistant_message_committed":
                self.text = ev.get("text") or ""
            elif kind == "user_input_prompt_requested":
                self.inputs[ev.get("prompt_id")] = ev.get("questions") or []
            elif kind == "terminal":
                self.terminal = ev


def git(wt, *args):
    return subprocess.run(["git", "-C", wt, *args], capture_output=True, text=True).stdout.strip()


def main():
    state_dir, mode = sys.argv[1], sys.argv[2]
    state_path = os.path.join(state_dir, "state.json")
    lock = os.path.join(state_dir, "lock")
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    s = json.load(open(state_path))

    def save():
        with open(state_path, "w") as f:
            json.dump(s, f, indent=2)

    def emit(verdict, **extra):
        out = {"slug": s["slug"], "agent": s["agent"], "turn": (s.get("pending") or {}).get("turn", s["turns"]),
               "verdict": verdict}
        out.update(extra)
        print(json.dumps(out, indent=2, ensure_ascii=False))

    agent = s["agent"]
    try:
        if mode == "send":
            n = s["turns"] + 1
            prompt = os.path.join(state_dir, "turn-%d.prompt.md" % n)
            r = herdr("agent", "prompt", agent, "Read the file %s and follow its instructions." % prompt,
                      "--wait", "--until", "working", "--until", "blocked", "--timeout", "30000")
            code = (r.get("error") or {}).get("code")
            if code in ("agent_not_found", "agent_blocked") or (code and "not_found" in code):
                s["pending"] = None
                return emit("failed" if code != "agent_blocked" else "input", reason=code,
                            screen=screen(agent) if code == "agent_blocked" else [])
            # agent_prompt_stalled / timeout do not prove the prompt was lost: the log decides.
            s["pending"] = {"turn": n, "prompt": prompt, "sent_at": time.time()}
            save()
        pending = s.get("pending")
        if not pending:
            return emit("failed", reason="no pending turn")

        log, run, input_polls = None, None, 0
        while True:
            a = herdr("agent", "get", agent)
            if "error" in a:
                return emit("failed", reason="agent gone: %s" % a["error"].get("code"), session_log=log)
            status = a["result"]["agent"]["agent_status"]

            if run is None:
                log = find_log(pending["prompt"], pending["sent_at"], s.get("session_log"))
                if log:
                    s["session_log"] = log
                    save()
                    run = Run(log, pending["prompt"])
            if run is not None:
                run.poll()
            if run is None or run.run_id is None:
                if time.time() - pending["sent_at"] > START_GRACE_S:
                    return emit("failed", reason="prompt never started a Muse run", session_log=log,
                                screen=screen(agent))
                time.sleep(POLL_S)
                continue

            if run.terminal is not None:
                break
            questions, approvals = run.waiting_on_user()
            input_polls = input_polls + 1 if (questions or approvals) else 0
            quiet_blocked = status == "blocked" and time.time() - run.last_growth > QUIET_BLOCKED_S
            if input_polls >= INPUT_SETTLE_POLLS or quiet_blocked:
                return emit("input", input=questions, approvals=approvals, herdr_status=status,
                            session_log=log, screen=screen(agent))
            time.sleep(POLL_S)

        # The turn ended.
        s["turns"], s["pending"] = pending["turn"], None
        save()
        wt = s["worktree"]
        commits = git(wt, "log", "--oneline", "%s..%s" % (s["base"], s["branch"])).splitlines()
        dirty = git(wt, "status", "--porcelain").splitlines()
        head = git(wt, "rev-parse", "--abbrev-ref", "HEAD")
        missing = [p for p in s["expect"] if not os.path.exists(os.path.join(wt, p))]
        questions = [q.strip() for q in
                     re.findall(r"^[\s>*_`-]*QUESTION:[\s*_`]*(.+)$", run.text, re.M)]
        term = run.terminal
        if term.get("terminal") != "completed":
            verdict = "failed"
        elif questions:
            verdict = "question"
        elif dirty or missing or not commits or head != s["branch"]:
            verdict = "incomplete"
        else:
            verdict = "completed"
        emit(verdict, turn=pending["turn"], questions=questions, final_text=run.text,
             commits=commits, dirty=dirty, missing=missing, head_branch=head,
             terminal=term.get("terminal"), reason=term.get("reason"),
             turn_duration_s=round((term.get("turn_duration_ms") or 0) / 1000, 1),
             session_log=log, screen=screen(agent, 25) if verdict == "failed" else [])
    finally:
        try:
            os.remove(os.path.join(lock, "pid"))
            os.rmdir(lock)
        except OSError:
            pass


if __name__ == "__main__":
    main()
