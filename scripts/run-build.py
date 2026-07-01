#!/usr/bin/env python3
"""Run configured build commands for a checked-out source repository."""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

from config_common import ConfigError, load_config


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True, help="App config name without .yml")
    parser.add_argument("--source-dir", required=True)
    args = parser.parse_args()

    try:
        config = load_config(args.app)
    except ConfigError as exc:
        print(f"config invalid: {exc}", file=sys.stderr)
        return 1

    source_dir = Path(args.source_dir).resolve()
    if not source_dir.exists():
        print(f"source dir not found: {source_dir}", file=sys.stderr)
        return 1

    env = os.environ.copy()
    env.pop("SOURCE_REPO_TOKEN", None)
    env.pop("AI_DEPLOY_SSH_KEY", None)

    for index, command in enumerate(config["build"]["commands"], start=1):
        print(f"::group::build command {index}")
        print(command)
        completed = subprocess.run(command, shell=True, cwd=source_dir, env=env)
        print("::endgroup::")
        if completed.returncode != 0:
            return completed.returncode

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

