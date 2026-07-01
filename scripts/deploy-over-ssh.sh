#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <release.tar.gz> <deploy.env> <release.env>" >&2
  exit 2
fi

RELEASE_TAR="$1"
DEPLOY_ENV="$2"
RELEASE_ENV="$3"

for file in "$RELEASE_TAR" "$DEPLOY_ENV" "$RELEASE_ENV"; do
  [[ -f "$file" ]] || { echo "missing file: $file" >&2; exit 1; }
done

# shellcheck disable=SC1090
source "$DEPLOY_ENV"
# shellcheck disable=SC1090
source "$RELEASE_ENV"

: "${APP_NAME:?APP_NAME is required}"
: "${RELEASE_ID:?RELEASE_ID is required}"
: "${AI_DEPLOY_SSH_HOST:?AI_DEPLOY_SSH_HOST is required}"
: "${AI_DEPLOY_SSH_USER:?AI_DEPLOY_SSH_USER is required}"
: "${AI_DEPLOY_SSH_KEY:?AI_DEPLOY_SSH_KEY is required}"
: "${AI_DEPLOY_SSH_PORT:?AI_DEPLOY_SSH_PORT is required}"
: "${AI_DEPLOY_CERTBOT_EMAIL:?AI_DEPLOY_CERTBOT_EMAIL is required}"

if [[ "$AI_DEPLOY_CERTBOT_EMAIL" != *@* || "$AI_DEPLOY_CERTBOT_EMAIL" == *$'\n'* || "$AI_DEPLOY_CERTBOT_EMAIL" == *$'\r'* ]]; then
  echo "AI_DEPLOY_CERTBOT_EMAIL must be a single-line email address" >&2
  exit 1
fi

SSH_PORT="$AI_DEPLOY_SSH_PORT"
REMOTE_ROOT="${AI_DEPLOY_REMOTE_DIR:-/home/${AI_DEPLOY_SSH_USER}/.ai-deploy}"
REMOTE_INBOX="${REMOTE_ROOT}/incoming/${APP_NAME}-${RELEASE_ID}"

KEY_FILE="$(mktemp)"
KNOWN_HOSTS="$(mktemp)"
APP_ENV_FILE=""
CERTBOT_ENV_FILE="$(mktemp)"
cleanup() {
  rm -f "$KEY_FILE" "$KNOWN_HOSTS"
  rm -f "$CERTBOT_ENV_FILE"
  if [[ -n "$APP_ENV_FILE" ]]; then
    rm -f "$APP_ENV_FILE"
  fi
}
trap cleanup EXIT

if [[ -n "${APP_ENV_B64:-}" ]]; then
  APP_ENV_FILE="$(mktemp)"
  if ! APP_ENV_FILE="$APP_ENV_FILE" APP_ENV_B64="$APP_ENV_B64" python3 - <<'PY'
import base64
import os
import sys

encoded = "".join(os.environ["APP_ENV_B64"].split())
try:
    decoded = base64.b64decode(encoded, validate=True)
except Exception:
    sys.exit(1)

with open(os.environ["APP_ENV_FILE"], "wb") as handle:
    handle.write(decoded)
PY
  then
    echo "APP_ENV_B64 is not valid base64" >&2
    exit 1
  fi
elif [[ "${APP_ENV_B64_REQUIRED:-true}" == "true" ]]; then
  echo "APP_ENV_B64 is required by this app config but is empty or missing in the GitHub Environment" >&2
  exit 1
fi

printf 'CERTBOT_EMAIL=%q\n' "$AI_DEPLOY_CERTBOT_EMAIL" > "$CERTBOT_ENV_FILE"

printf '%s\n' "$AI_DEPLOY_SSH_KEY" > "$KEY_FILE"
chmod 600 "$KEY_FILE"

ssh-keyscan -p "$SSH_PORT" "$AI_DEPLOY_SSH_HOST" > "$KNOWN_HOSTS" 2>/dev/null

SSH_OPTS=(
  -i "$KEY_FILE"
  -p "$SSH_PORT"
  -o "UserKnownHostsFile=$KNOWN_HOSTS"
  -o "StrictHostKeyChecking=yes"
)

REMOTE="${AI_DEPLOY_SSH_USER}@${AI_DEPLOY_SSH_HOST}"

ssh "${SSH_OPTS[@]}" "$REMOTE" "mkdir -p '$REMOTE_INBOX' '$REMOTE_ROOT/bin' '$REMOTE_ROOT/bin/runtimes'"

scp "${SSH_OPTS[@]}" "$RELEASE_TAR" "$DEPLOY_ENV" "$RELEASE_ENV" "$REMOTE:$REMOTE_INBOX/"
scp "${SSH_OPTS[@]}" "$CERTBOT_ENV_FILE" "$REMOTE:$REMOTE_INBOX/certbot.env"
if [[ -n "$APP_ENV_FILE" ]]; then
  scp "${SSH_OPTS[@]}" "$APP_ENV_FILE" "$REMOTE:$REMOTE_INBOX/app.env"
fi
scp "${SSH_OPTS[@]}" server/server-deploy.sh "$REMOTE:$REMOTE_ROOT/bin/server-deploy.sh"
scp "${SSH_OPTS[@]}" server/runtimes/*.sh "$REMOTE:$REMOTE_ROOT/bin/runtimes/"

ssh "${SSH_OPTS[@]}" "$REMOTE" "bash '$REMOTE_ROOT/bin/server-deploy.sh' '$REMOTE_INBOX'"
