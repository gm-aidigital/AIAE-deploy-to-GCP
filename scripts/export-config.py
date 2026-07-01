#!/usr/bin/env python3
"""Export a validated app config for GitHub Actions jobs."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from config_common import ConfigError, effective_ref, load_config, write_deploy_env


def append_github_output(path: str, values: dict[str, str]) -> None:
    with open(path, "a", encoding="utf-8") as handle:
        for key, value in values.items():
            handle.write(f"{key}={value}\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True, help="App config name without .yml")
    parser.add_argument("--ref", default="", help="Optional branch, tag, or SHA override")
    parser.add_argument("--github-output", required=True)
    parser.add_argument("--dist", required=True)
    args = parser.parse_args()

    try:
        config = load_config(args.app)
        ref = effective_ref(config, args.ref)
    except ConfigError as exc:
        print(f"config invalid: {exc}", file=sys.stderr)
        return 1

    dist = Path(args.dist)
    dist.mkdir(parents=True, exist_ok=True)
    write_deploy_env(config, ref, dist / "deploy.env")

    append_github_output(
        args.github_output,
        {
            "app_slug": config["app"],
            "repo": config["repo"],
            "ref": ref,
            "runtime": config["runtime"],
            "github_environment": config["github_environment"],
            "deployment_url": f"https://{config['subdomain']}/",
        },
    )
    print(f"exported config for {config['app']} at {ref}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
