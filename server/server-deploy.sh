#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <inbox-dir>" >&2
  exit 2
fi

INBOX_DIR="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1090
source "$INBOX_DIR/deploy.env"
# shellcheck disable=SC1090
source "$INBOX_DIR/release.env"
if [[ -f "$INBOX_DIR/certbot.env" ]]; then
  # shellcheck disable=SC1090
  source "$INBOX_DIR/certbot.env"
fi

: "${APP_NAME:?APP_NAME is required}"
: "${RUNTIME:?RUNTIME is required}"
: "${SUBDOMAIN:?SUBDOMAIN is required}"
: "${RELEASE_ID:?RELEASE_ID is required}"
: "${CERTBOT_EMAIL:?CERTBOT_EMAIL is required}"
: "${REQUESTED_PORT:=auto}"
: "${HEALTHCHECK_PATH:=/}"
: "${CLIENT_MAX_BODY_SIZE:=50M}"
: "${PROXY_READ_TIMEOUT:=600s}"
: "${BASIC_AUTH_ENABLED:=false}"
: "${KEEP_RELEASES:=5}"
: "${APP_ENV_B64_REQUIRED:=true}"

APP_ROOT="${AI_DEPLOY_APP_ROOT:-$HOME/apps}"
STATE_DIR="${AI_DEPLOY_STATE_DIR:-$HOME/.ai-deploy/state}"
APP_HOME="$APP_ROOT/$APP_NAME"
RELEASES_DIR="$APP_HOME/releases"
SHARED_DIR="$APP_HOME/shared"
CURRENT_LINK="$APP_HOME/current"
RELEASE_DIR="$RELEASES_DIR/$RELEASE_ID"
PORT_REGISTRY="$STATE_DIR/ports.tsv"
APP_PORT=""

mkdir -p "$STATE_DIR" "$RELEASES_DIR" "$SHARED_DIR"

log() {
  printf '[ai-deploy] %s\n' "$*"
}

fail() {
  printf '[ai-deploy] ERROR: %s\n' "$*" >&2
  exit 1
}

is_port_free() {
  local port="$1"
  ! sudo ss -tlnp | grep -qE "[:.]${port}[[:space:]]"
}

registered_port_for_app() {
  [[ -f "$PORT_REGISTRY" ]] || return 1
  awk -v app="$APP_NAME" '$1 == app { print $2; found=1 } END { exit found ? 0 : 1 }' "$PORT_REGISTRY"
}

choose_port() {
  local requested="$REQUESTED_PORT"
  local existing=""

  if existing="$(registered_port_for_app)"; then
    APP_PORT="$existing"
    log "using registered port $APP_PORT"
    return
  fi

  if [[ "$requested" != "auto" ]]; then
    is_port_free "$requested" || fail "requested port $requested is already in use"
    APP_PORT="$requested"
    printf '%s\t%s\n' "$APP_NAME" "$APP_PORT" >> "$PORT_REGISTRY"
    return
  fi

  for port in $(seq 3101 3999); do
    if is_port_free "$port" && ! awk -v p="$port" '$2 == p { found=1 } END { exit found ? 0 : 1 }' "$PORT_REGISTRY" 2>/dev/null; then
      APP_PORT="$port"
      printf '%s\t%s\n' "$APP_NAME" "$APP_PORT" >> "$PORT_REGISTRY"
      log "allocated port $APP_PORT"
      return
    fi
  done

  fail "no free deployment port found"
}

render_proxy_location() {
  local auth_lines=""
  if [[ "$BASIC_AUTH_ENABLED" == "true" ]]; then
    local htpasswd="/etc/nginx/.htpasswd-$APP_NAME"
    [[ -f "$htpasswd" ]] || fail "basic auth enabled but $htpasswd does not exist"
    auth_lines="        auth_basic \"$APP_NAME\";
        auth_basic_user_file $htpasswd;"
  fi

  cat <<EOF
    location / {
$auth_lines
        proxy_pass http://127.0.0.1:$APP_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
EOF
}

write_nginx_vhost() {
  local available="/etc/nginx/sites-available/$SUBDOMAIN.conf"
  local enabled="/etc/nginx/sites-enabled/$SUBDOMAIN.conf"
  local cert_dir="/etc/letsencrypt/live/$SUBDOMAIN"
  local tmp
  tmp="$(mktemp)"

  if [[ -f "$cert_dir/fullchain.pem" && -f "$cert_dir/privkey.pem" ]]; then
    cat > "$tmp" <<EOF
# $APP_NAME - $SUBDOMAIN -> 127.0.0.1:$APP_PORT
server {
    listen 80;
    server_name $SUBDOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $SUBDOMAIN;

    ssl_certificate $cert_dir/fullchain.pem;
    ssl_certificate_key $cert_dir/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    client_max_body_size $CLIENT_MAX_BODY_SIZE;
    proxy_read_timeout $PROXY_READ_TIMEOUT;

$(render_proxy_location)
}
EOF
  else
    cat > "$tmp" <<EOF
# $APP_NAME - $SUBDOMAIN -> 127.0.0.1:$APP_PORT
server {
    listen 80;
    server_name $SUBDOMAIN;

    client_max_body_size $CLIENT_MAX_BODY_SIZE;
    proxy_read_timeout $PROXY_READ_TIMEOUT;

$(render_proxy_location)
}
EOF
  fi

  sudo cp "$tmp" "$available"
  rm -f "$tmp"
  sudo ln -sf "$available" "$enabled"
  sudo nginx -t
  sudo systemctl reload nginx

  if [[ ! -f "$cert_dir/fullchain.pem" ]]; then
    log "requesting certificate for $SUBDOMAIN"
    sudo certbot --nginx -d "$SUBDOMAIN" --non-interactive --agree-tos -m "$CERTBOT_EMAIL" --redirect
    write_nginx_vhost
  fi
}

healthcheck() {
  local url="http://127.0.0.1:${APP_PORT}${HEALTHCHECK_PATH}"
  log "checking $url"
  for _ in $(seq 1 30); do
    if curl -fsS -o /dev/null "$url"; then
      return 0
    fi
    sleep 2
  done
  return 1
}

rollback() {
  local previous="$1"
  if [[ -n "$previous" && -d "$previous" ]]; then
    log "rolling back to $previous"
    ln -sfn "$previous" "$CURRENT_LINK"
    runtime_start_current
  fi
}

cleanup_old_releases() {
  local keep="$KEEP_RELEASES"
  [[ "$keep" =~ ^[0-9]+$ ]] || keep=5
  find "$RELEASES_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn \
    | awk -v keep="$keep" 'NR > keep { print $2 }' \
    | xargs -r rm -rf
}

install_app_env() {
  if [[ -f "$INBOX_DIR/app.env" ]]; then
    cp "$INBOX_DIR/app.env" "$SHARED_DIR/.env"
    chmod 600 "$SHARED_DIR/.env"
    log "installed app environment file"
  elif [[ "$APP_ENV_B64_REQUIRED" == "true" && ! -f "$SHARED_DIR/.env" ]]; then
    fail "app env is required, but no app.env was uploaded and $SHARED_DIR/.env does not exist"
  fi
}

runtime_file="$SCRIPT_DIR/runtimes/${RUNTIME}.sh"
[[ -f "$runtime_file" ]] || fail "runtime adapter not found: $runtime_file"
# shellcheck disable=SC1090
source "$runtime_file"

choose_port
install_app_env

previous_release=""
if [[ -L "$CURRENT_LINK" ]]; then
  previous_release="$(readlink "$CURRENT_LINK")"
fi

rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"
tar -xzf "$INBOX_DIR/release.tar.gz" -C "$RELEASE_DIR"

log "preparing $APP_NAME release $RELEASE_ID"
runtime_prepare_release

ln -sfn "$RELEASE_DIR" "$CURRENT_LINK"

if ! runtime_start_current; then
  rollback "$previous_release"
  fail "runtime failed to start"
fi

if ! healthcheck; then
  rollback "$previous_release"
  fail "healthcheck failed"
fi

write_nginx_vhost
cleanup_old_releases

log "deployed $APP_NAME to https://$SUBDOMAIN/ on port $APP_PORT"
