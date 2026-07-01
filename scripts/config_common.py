#!/usr/bin/env python3
"""Shared config loading and validation for ai-deploy scripts."""

from __future__ import annotations

import glob
import os
import re
import shlex
from pathlib import Path
from typing import Any

import yaml


ROOT = Path(__file__).resolve().parents[1]
APPS_DIR = ROOT / "apps"

ALLOWED_TOP_LEVEL = {
    "app",
    "repo",
    "default_ref",
    "github_environment",
    "subdomain",
    "runtime",
    "build",
    "start",
    "artifact",
    "server",
    "secrets",
    "runtime_config",
}

ALLOWED_RUNTIMES = {"java-systemd", "node-pm2"}
ALLOWED_SERVER_KEYS = {
    "port",
    "healthcheck",
    "client_max_body_size",
    "proxy_read_timeout",
    "basic_auth",
    "keep_releases",
}

APP_RE = re.compile(r"^[a-z][a-z0-9-]{1,48}[a-z0-9]$")
GITHUB_ENVIRONMENT_RE = re.compile(r"^[A-Za-z0-9_.-]{3,64}$")
REPO_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
REF_RE = re.compile(r"^[A-Za-z0-9_./@+-]{1,200}$")
SUBDOMAIN_RE = re.compile(r"^[a-z0-9-]+\.aidigital\.tech$")
PORT_RE = re.compile(r"^(auto|[0-9]{2,5})$")
SIZE_RE = re.compile(r"^[0-9]+[kKmMgG]?$")
TIMEOUT_RE = re.compile(r"^[0-9]+s$")


class ConfigError(ValueError):
    """Raised when an app config is invalid."""


def app_config_path(app: str) -> Path:
    if not APP_RE.fullmatch(app):
        raise ConfigError(f"Invalid app input: {app!r}")
    return APPS_DIR / f"{app}.yml"


def load_config(app: str) -> dict[str, Any]:
    path = app_config_path(app)
    if not path.exists():
        raise ConfigError(f"App config not found: {path}")
    with path.open("r", encoding="utf-8") as handle:
        loaded = yaml.safe_load(handle)
    if not isinstance(loaded, dict):
        raise ConfigError(f"App config must be a mapping: {path}")
    validate_config(loaded, expected_app=app)
    return loaded


def validate_config(config: dict[str, Any], expected_app: str | None = None) -> None:
    unknown = set(config) - ALLOWED_TOP_LEVEL
    if unknown:
        raise ConfigError(f"Unknown top-level keys: {sorted(unknown)}")

    app = require_string(config, "app")
    if expected_app and app != expected_app:
        raise ConfigError(f"Config app {app!r} does not match file/input {expected_app!r}")
    if not APP_RE.fullmatch(app):
        raise ConfigError("app must be lowercase kebab-case, 3-50 chars")

    repo = require_string(config, "repo")
    if not REPO_RE.fullmatch(repo):
        raise ConfigError("repo must look like owner/name")

    default_ref = require_string(config, "default_ref")
    if not REF_RE.fullmatch(default_ref):
        raise ConfigError("default_ref contains unsupported characters")

    github_environment = require_string(config, "github_environment")
    if not GITHUB_ENVIRONMENT_RE.fullmatch(github_environment):
        raise ConfigError("github_environment must be 3-64 chars using letters, numbers, underscore, dot, or hyphen")

    subdomain = require_string(config, "subdomain")
    if not SUBDOMAIN_RE.fullmatch(subdomain):
        raise ConfigError("subdomain must be a *.aidigital.tech host")

    runtime = require_string(config, "runtime")
    if runtime not in ALLOWED_RUNTIMES:
        raise ConfigError(f"runtime must be one of {sorted(ALLOWED_RUNTIMES)}")

    build = require_mapping(config, "build")
    commands = build.get("commands")
    if not isinstance(commands, list) or not commands:
        raise ConfigError("build.commands must be a non-empty list")
    for command in commands:
        validate_command(command, "build.commands")

    artifact = require_mapping(config, "artifact")
    artifact_path = require_string(artifact, "path")
    if artifact_path.startswith("/") or ".." in Path(artifact_path).parts:
        raise ConfigError("artifact.path must be relative and stay inside the source checkout")
    if not isinstance(artifact.get("include_node_modules", False), bool):
        raise ConfigError("artifact.include_node_modules must be boolean when present")

    secrets = config.get("secrets", {})
    if secrets and not isinstance(secrets, dict):
        raise ConfigError("secrets must be a mapping when present")
    if not isinstance(secrets.get("app_env_b64_required", True), bool):
        raise ConfigError("secrets.app_env_b64_required must be boolean when present")

    server = require_mapping(config, "server")
    unknown_server_keys = set(server) - ALLOWED_SERVER_KEYS
    if unknown_server_keys:
        raise ConfigError(f"Unknown server keys: {sorted(unknown_server_keys)}")

    port = str(server.get("port", "auto"))
    if not PORT_RE.fullmatch(port):
        raise ConfigError("server.port must be auto or a numeric port")
    if port != "auto":
        port_number = int(port)
        if port_number < 1024 or port_number > 65535:
            raise ConfigError("server.port must be between 1024 and 65535")

    healthcheck = str(server.get("healthcheck", "/"))
    if not healthcheck.startswith("/") or "\n" in healthcheck:
        raise ConfigError("server.healthcheck must be an absolute path")

    client_max_body_size = str(server.get("client_max_body_size", "50M"))
    if not SIZE_RE.fullmatch(client_max_body_size):
        raise ConfigError("server.client_max_body_size must look like 50M")

    proxy_read_timeout = str(server.get("proxy_read_timeout", "600s"))
    if not TIMEOUT_RE.fullmatch(proxy_read_timeout):
        raise ConfigError("server.proxy_read_timeout must look like 600s")

    basic_auth = server.get("basic_auth", False)
    if not isinstance(basic_auth, bool):
        raise ConfigError("server.basic_auth must be boolean when present")

    if runtime == "node-pm2":
        start = require_mapping(config, "start")
        validate_command(require_string(start, "command"), "start.command")
    elif "start" in config:
        raise ConfigError("start is only supported for node-pm2 runtime")

    runtime_config = config.get("runtime_config", {})
    if runtime_config and not isinstance(runtime_config, dict):
        raise ConfigError("runtime_config must be a mapping when present")
    for value_key in ("java_opts", "node_env", "node_install_command"):
        if value_key in runtime_config:
            validate_no_newlines(str(runtime_config[value_key]), f"runtime_config.{value_key}")


def require_string(mapping: dict[str, Any], key: str) -> str:
    value = mapping.get(key)
    if not isinstance(value, str) or not value.strip():
        raise ConfigError(f"{key} must be a non-empty string")
    validate_no_newlines(value, key)
    return value


def require_mapping(mapping: dict[str, Any], key: str) -> dict[str, Any]:
    value = mapping.get(key)
    if not isinstance(value, dict):
        raise ConfigError(f"{key} must be a mapping")
    return value


def validate_no_newlines(value: str, field: str) -> None:
    if "\n" in value or "\r" in value:
        raise ConfigError(f"{field} must not contain newlines")


def validate_command(value: Any, field: str) -> None:
    if not isinstance(value, str) or not value.strip():
        raise ConfigError(f"{field} entries must be non-empty strings")
    validate_no_newlines(value, field)


def effective_ref(config: dict[str, Any], override_ref: str | None) -> str:
    ref = (override_ref or "").strip() or config["default_ref"]
    if not REF_RE.fullmatch(ref):
        raise ConfigError("ref contains unsupported characters")
    return ref


def shell_env_line(key: str, value: str | int | bool) -> str:
    if isinstance(value, bool):
        text = "true" if value else "false"
    else:
        text = str(value)
    validate_no_newlines(text, key)
    return f"{key}={shlex.quote(text)}"


def write_deploy_env(config: dict[str, Any], ref: str, target: Path) -> None:
    server = config.get("server", {})
    runtime_config = config.get("runtime_config", {})
    start = config.get("start", {})

    lines = [
        shell_env_line("APP_NAME", config["app"]),
        shell_env_line("SOURCE_REPO", config["repo"]),
        shell_env_line("SOURCE_REF", ref),
        shell_env_line("GITHUB_ENVIRONMENT", config["github_environment"]),
        shell_env_line("RUNTIME", config["runtime"]),
        shell_env_line("SUBDOMAIN", config["subdomain"]),
        shell_env_line("REQUESTED_PORT", str(server.get("port", "auto"))),
        shell_env_line("HEALTHCHECK_PATH", str(server.get("healthcheck", "/"))),
        shell_env_line("CLIENT_MAX_BODY_SIZE", str(server.get("client_max_body_size", "50M"))),
        shell_env_line("PROXY_READ_TIMEOUT", str(server.get("proxy_read_timeout", "600s"))),
        shell_env_line("BASIC_AUTH_ENABLED", bool(server.get("basic_auth", False))),
        shell_env_line("START_COMMAND", str(start.get("command", ""))),
        shell_env_line("JAVA_OPTS", str(runtime_config.get("java_opts", ""))),
        shell_env_line("NODE_ENV", str(runtime_config.get("node_env", "production"))),
        shell_env_line("NODE_INSTALL_COMMAND", str(runtime_config.get("node_install_command", ""))),
        shell_env_line("KEEP_RELEASES", str(server.get("keep_releases", 5))),
        shell_env_line("APP_ENV_B64_REQUIRED", bool(config.get("secrets", {}).get("app_env_b64_required", True))),
    ]
    target.write_text("\n".join(lines) + "\n", encoding="utf-8")


def resolve_artifacts(source_dir: Path, pattern: str) -> list[Path]:
    matches = [Path(path) for path in glob.glob(str(source_dir / pattern))]
    return sorted(path for path in matches if path.exists())
