#!/usr/bin/env python3
"""Package a built source checkout into a deployable release tarball."""

from __future__ import annotations

import argparse
import fnmatch
import os
import subprocess
import sys
import tarfile
from pathlib import Path

from config_common import ConfigError, load_config, resolve_artifacts, shell_env_line


DEFAULT_EXCLUDES = [
    ".git",
    ".git/*",
    ".env",
    ".env.*",
    "*.log",
    ".DS_Store",
    "dist/release.tar.gz",
]


def git_value(source_dir: Path, args: list[str], fallback: str) -> str:
    try:
        return subprocess.check_output(["git", "-C", str(source_dir), *args], text=True).strip()
    except Exception:
        return fallback


def should_exclude(relative: str, include_node_modules: bool) -> bool:
    patterns = list(DEFAULT_EXCLUDES)
    if not include_node_modules:
        patterns.extend(["node_modules", "node_modules/*"])
    return any(fnmatch.fnmatch(relative, pattern) for pattern in patterns)


def add_directory_contents(tar: tarfile.TarFile, source: Path, include_node_modules: bool) -> None:
    for path in sorted(source.rglob("*")):
        relative = path.relative_to(source).as_posix()
        if should_exclude(relative, include_node_modules):
            continue
        tar.add(path, arcname=relative, recursive=False)


def package_java(config: dict, source_dir: Path, tar: tarfile.TarFile) -> str:
    matches = resolve_artifacts(source_dir, config["artifact"]["path"])
    files = [path for path in matches if path.is_file()]
    if len(files) != 1:
        raise ConfigError(f"java-systemd artifact.path must match exactly one jar, got {len(files)}")
    tar.add(files[0], arcname="app.jar")
    return "jar"


def package_node(config: dict, source_dir: Path, tar: tarfile.TarFile) -> str:
    artifact_path = source_dir / config["artifact"]["path"]
    include_node_modules = bool(config["artifact"].get("include_node_modules", False))
    if not artifact_path.exists():
        raise ConfigError(f"artifact.path does not exist: {artifact_path}")
    if artifact_path.is_file():
        tar.add(artifact_path, arcname=artifact_path.name)
    else:
        add_directory_contents(tar, artifact_path, include_node_modules)
    return "node-bundle"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True, help="App config name without .yml")
    parser.add_argument("--source-dir", required=True)
    parser.add_argument("--dist", required=True)
    args = parser.parse_args()

    try:
        config = load_config(args.app)
    except ConfigError as exc:
        print(f"config invalid: {exc}", file=sys.stderr)
        return 1

    source_dir = Path(args.source_dir).resolve()
    dist = Path(args.dist)
    dist.mkdir(parents=True, exist_ok=True)

    release_id = os.environ.get("GITHUB_RUN_ID", "local")
    source_sha = git_value(source_dir, ["rev-parse", "HEAD"], "unknown")
    short_sha = git_value(source_dir, ["rev-parse", "--short", "HEAD"], "unknown")
    release_name = f"{config['app']}-{release_id}-{short_sha}"

    tar_path = dist / "release.tar.gz"
    try:
        with tarfile.open(tar_path, "w:gz") as tar:
            if config["runtime"] == "java-systemd":
                artifact_kind = package_java(config, source_dir, tar)
            elif config["runtime"] == "node-pm2":
                artifact_kind = package_node(config, source_dir, tar)
            else:
                raise ConfigError(f"Unsupported runtime: {config['runtime']}")
    except ConfigError as exc:
        print(f"package failed: {exc}", file=sys.stderr)
        return 1

    release_env = "\n".join(
        [
            shell_env_line("RELEASE_ID", release_name),
            shell_env_line("SOURCE_SHA", source_sha),
            shell_env_line("ARTIFACT_KIND", artifact_kind),
        ]
    )
    (dist / "release.env").write_text(release_env + "\n", encoding="utf-8")
    print(f"packaged {tar_path} ({artifact_kind})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

