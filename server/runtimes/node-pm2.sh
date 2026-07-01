#!/usr/bin/env bash

quote() {
  printf '%q' "$1"
}

runtime_prepare_release() {
  [[ -f "$RELEASE_DIR/package.json" ]] || fail "node-pm2 release must contain package.json"
  command -v node >/dev/null || fail "node is not installed on the server"
  command -v npm >/dev/null || fail "npm is not installed on the server"
  command -v pm2 >/dev/null || fail "pm2 is not installed on the server"

  if [[ -n "${NODE_INSTALL_COMMAND:-}" ]]; then
    log "running explicit server-side node install command"
    (cd "$RELEASE_DIR" && bash -lc "$NODE_INSTALL_COMMAND")
  elif [[ ! -d "$RELEASE_DIR/node_modules" ]]; then
    fail "node_modules missing. Build with artifact.include_node_modules: true or set runtime_config.node_install_command explicitly."
  fi
}

runtime_start_current() {
  [[ -n "${START_COMMAND:-}" ]] || fail "START_COMMAND is required for node-pm2"

  local env_file="$SHARED_DIR/.env"
  local shell_command
  shell_command="cd $(quote "$CURRENT_LINK") && set -a; [ -f $(quote "$env_file") ] && . $(quote "$env_file"); set +a; export PORT=$(quote "$APP_PORT") NODE_ENV=$(quote "${NODE_ENV:-production}"); exec $START_COMMAND"

  pm2 delete "$APP_NAME" >/dev/null 2>&1 || true
  pm2 start bash --name "$APP_NAME" -- -lc "$shell_command"
  pm2 save
}

