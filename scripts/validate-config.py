#!/usr/bin/env python3
"""Validate a central app deployment config."""

from __future__ import annotations

import argparse
import sys

from config_common import ConfigError, load_config


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True, help="App config name without .yml")
    args = parser.parse_args()

    try:
        config = load_config(args.app)
    except ConfigError as exc:
        print(f"config invalid: {exc}", file=sys.stderr)
        return 1

    print(f"config ok: {config['app']} -> {config['repo']} ({config['runtime']})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

