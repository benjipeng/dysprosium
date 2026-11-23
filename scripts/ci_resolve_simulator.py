#!/usr/bin/env python3
"""Resolve a lightweight, available iOS Simulator for headless CI test runs.

Prefers a single-display iPhone (e.g. "iPhone 17") on the target iOS runtime
and excludes high-RAM dual-display simulators (e.g. "Duo") so CI stays fast
and deterministic; iPhone Duo layout invariants are covered by pure geometry
unit tests.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys


def resolve_simulator(runtime_version: str, preferred_name: str, excluded_substrings: list[str]) -> tuple[str, str]:
    runtime_token = f"iOS-{runtime_version.replace('.', '-')}"
    raw = subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"])
    data = json.loads(raw)

    preferred: tuple[str, str] | None = None
    fallback: tuple[str, str] | None = None

    for runtime, devices in data.get("devices", {}).items():
        if runtime_token not in runtime:
            continue
        for device in devices:
            if not device.get("isAvailable", False):
                continue
            name = device.get("name", "")
            udid = device.get("udid", "")
            if not udid:
                continue
            if any(token.lower() in name.lower() for token in excluded_substrings):
                continue
            if name.lower() == preferred_name.lower() and preferred is None:
                preferred = (udid, name)
            elif "iphone" in name.lower() and fallback is None:
                fallback = (udid, name)

    chosen = preferred or fallback
    if not chosen:
        sys.exit(
            f"Error: No available simulator found for runtime '{runtime_token}' "
            f"(preferred='{preferred_name}', excluded={excluded_substrings})."
        )
    return chosen


def main() -> None:
    parser = argparse.ArgumentParser(description="Resolve an available iOS Simulator for CI.")
    parser.add_argument("--runtime", default="27.2", help="Target iOS runtime version (default: 27.2)")
    parser.add_argument("--preferred", default="iPhone 17", help="Preferred device name (default: iPhone 17)")
    parser.add_argument(
        "--exclude",
        action="append",
        default=[],
        help="Case-insensitive device-name substring to skip (default: Duo)",
    )
    parser.add_argument("--github-output", default="", help="Optional path to $GITHUB_OUTPUT file")
    args = parser.parse_args()

    excluded = args.exclude if args.exclude else ["Duo"]
    udid, name = resolve_simulator(args.runtime, args.preferred, excluded)

    print(f"Resolved Simulator: {name} ({udid})")
    if args.github_output:
        with open(args.github_output, "a", encoding="utf-8") as handle:
            handle.write(f"udid={udid}\n")
            handle.write(f"name={name}\n")


if __name__ == "__main__":
    main()
