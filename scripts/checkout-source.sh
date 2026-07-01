#!/usr/bin/env bash
set -euo pipefail

: "${SOURCE_REPO:?SOURCE_REPO is required}"
: "${SOURCE_REF:?SOURCE_REF is required}"
: "${SOURCE_DIR:=source}"

rm -rf "$SOURCE_DIR"
mkdir -p "$SOURCE_DIR"

git init "$SOURCE_DIR" >/dev/null
git -C "$SOURCE_DIR" remote add origin "https://github.com/${SOURCE_REPO}.git"

if [[ -n "${SOURCE_REPO_TOKEN:-}" ]]; then
  auth_header="$(printf 'x-access-token:%s' "$SOURCE_REPO_TOKEN" | base64 | tr -d '\n')"
  git -C "$SOURCE_DIR" \
    -c "http.https://github.com/.extraheader=AUTHORIZATION: basic ${auth_header}" \
    fetch --depth=1 origin "$SOURCE_REF"
else
  git -C "$SOURCE_DIR" fetch --depth=1 origin "$SOURCE_REF"
fi

git -C "$SOURCE_DIR" checkout --detach FETCH_HEAD >/dev/null
git -C "$SOURCE_DIR" submodule update --init --recursive

echo "checked out ${SOURCE_REPO}@$(git -C "$SOURCE_DIR" rev-parse --short HEAD)"

