#!/usr/bin/env python3
"""Report users with the most failed login records."""

from __future__ import annotations

import argparse
import re
import sys
from collections import Counter
from collections.abc import Iterable
from pathlib import Path
from typing import TextIO

FAILED_LOGIN = re.compile(r"failed\s+login", re.IGNORECASE)
# Accepts both formats in the assignment: Username=[alice] and Username[alice].
USERNAME = re.compile(r"\bUsername\s*=?\s*\[([^]\r\n]+)]", re.IGNORECASE)


def count_failed_logins(lines: Iterable[str]) -> tuple[Counter[str], int]:
    """Return username counts and the number of malformed failed-login lines."""
    counts: Counter[str] = Counter()
    malformed = 0

    for line in lines:
        if not FAILED_LOGIN.search(line):
            continue
        match = USERNAME.search(line)
        username = match.group(1).strip() if match else ""
        if username:
            counts[username] += 1
        else:
            malformed += 1

    return counts, malformed


def top_users(counts: Counter[str], limit: int) -> list[tuple[str, int]]:
    """Sort by descending count, then username for reproducible ties."""
    return sorted(counts.items(), key=lambda item: (-item[1], item[0]))[:limit]


def run(argv: list[str] | None = None, stderr: TextIO = sys.stderr) -> int:
    parser = argparse.ArgumentParser(description="Find users with the most failed logins")
    parser.add_argument("log_file", type=Path)
    parser.add_argument("--limit", type=int, default=5)
    args = parser.parse_args(argv)

    if args.limit < 1:
        print("error: --limit must be at least 1", file=stderr)
        return 2

    try:
        with args.log_file.open(encoding="utf-8", errors="replace") as log:
            counts, malformed = count_failed_logins(log)
    except OSError as exc:
        print(f"error: cannot read {args.log_file}: {exc}", file=stderr)
        return 2

    for username, count in top_users(counts, args.limit):
        print(f"{count} {username}")
    if malformed:
        print(f"warning: skipped {malformed} malformed failed-login record(s)", file=stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(run())
