#!/usr/bin/env python3
"""Repo guardrails: mistakes that keep landing, checked mechanically.

Usage:
    python3 .tools/guardrails.py [--base REF] [--head REF]

Checks the change from BASE (default: origin/main) to HEAD (default: the
working tree). CI runs the same command (.github/workflows/guardrails.yml).
Needs a Lua 5.1 compiler: `luac5.1` on PATH, or LUAC=/path/to/luac.

Line exceptions go on the offending line:
    -- guardrails-allow: <check> until YYYY-MM-DD by <approver>: <reason>
An expired exception fails like the violation it covers.
"""
import argparse
import datetime
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXCLUDED_DIRS = ("Libs/", ".tools/")
ALLOW_RE = re.compile(
    r"guardrails-allow:\s*(?P<check>[\w-]+)\s+until\s+(?P<date>\d{4}-\d{2}-\d{2})"
    r"\s+by\s+(?P<who>\S+?):\s*\S")


def git(*args):
    return subprocess.run(["git", *args], cwd=ROOT, check=True,
                          capture_output=True).stdout.decode("utf-8", "replace")


class Change:
    def __init__(self, base, head):
        self.base, self.head = base, head
        rng = [base] + ([head] if head else [])
        self.lua_files = [p for p in git("diff", "--name-only", "--diff-filter=AMR",
                                         *rng, "--", "*.lua").splitlines()
                          if p and not p.startswith(EXCLUDED_DIRS)]
        self.added_files = set(git("diff", "--name-only", "--diff-filter=A",
                                   *rng, "--", "*.lua").splitlines())
        self.added_lines = self._added_lines(rng)

    def read(self, path):
        if self.head:
            return subprocess.run(["git", "show", f"{self.head}:{path}"], cwd=ROOT,
                                  check=True, capture_output=True).stdout
        with open(os.path.join(ROOT, path), "rb") as f:
            return f.read()

    def _added_lines(self, rng):
        out, path, lineno = [], None, 0
        for line in git("diff", "-U0", *rng, "--", "*.lua").splitlines():
            if line.startswith("+++ "):
                path = line[6:] if line.startswith("+++ b/") else None
            elif line.startswith("@@"):
                lineno = int(re.search(r"\+(\d+)", line).group(1))
            elif line.startswith("+") and path and not path.startswith(EXCLUDED_DIRS):
                out.append((path, lineno, line[1:]))
                lineno += 1
        return out


def allowed(check, text, errors, where):
    m = ALLOW_RE.search(text)
    if not m or m.group("check") != check:
        return False
    if datetime.date.fromisoformat(m.group("date")) < datetime.date.today():
        errors.append(f"{where}: guardrails-allow for '{check}' expired on {m.group('date')}")
    return True


def check_compile(change, errors):
    """Lua 5.1 syntax and its 200-local / 60-upvalue limits; WoW fails the whole file."""
    luac = os.environ.get("LUAC", "luac5.1")
    for path in change.lua_files:
        src = change.read(path)
        if src.startswith(b"\xef\xbb\xbf"):
            src = src[3:]
        res = subprocess.run([luac, "-p", "-"], input=src, capture_output=True)
        if res.returncode != 0:
            msg = res.stderr.decode("utf-8", "replace").strip()
            msg = re.sub(r"^.*?stdin:", f"{path}:", msg)
            errors.append(f"{msg}\n  Fix the syntax, or split the file / move state into a "
                          f"table if a 200-local or 60-upvalue limit is hit.")


CHECKS = [check_compile]


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--base", default="origin/main")
    ap.add_argument("--head", default=None)
    args = ap.parse_args()
    change = Change(args.base, args.head)
    errors = []
    for check in CHECKS:
        check(change, errors)
    for e in errors:
        print(f"::error::{e}" if os.environ.get("GITHUB_ACTIONS") else e)
    if errors:
        print(f"{len(errors)} guardrail error(s).")
        return 1
    print(f"guardrails OK ({len(change.lua_files)} Lua files, "
          f"{len(change.added_lines)} added lines).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
