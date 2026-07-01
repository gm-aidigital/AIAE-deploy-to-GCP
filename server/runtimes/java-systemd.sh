#!/usr/bin/env bash

runtime_prepare_release() {
  [[ -f "$RELEASE_DIR/app.jar" ]] || fail "java-systemd release must contain app.jar"
  command -v java >/dev/null || fail "java is not installed on the server"
}

runtime_start_current() {
  local java_bin
  java_bin="$(command -v java)"
  local service_name="${APP_NAME}.service"
  local env_file="$SHARED_DIR/.env"
  local unit_tmp
  unit_tmp="$(mktemp)"

  cat > "$unit_tmp" <<EOF
[Unit]
Description=$APP_NAME
After=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$CURRENT_LINK
Environment=PORT=$APP_PORT
Environment=SERVER_PORT=$APP_PORT
EnvironmentFile=-$env_file
ExecStart=$java_bin $JAVA_OPTS -jar $CURRENT_LINK/app.jar
Restart=on-failure
RestartSec=5
SuccessExitStatus=143

[Install]
WantedBy=multi-user.target
EOF

  sudo cp "$unit_tmp" "/etc/systemd/system/$service_name"
  rm -f "$unit_tmp"
  sudo systemctl daemon-reload
  sudo systemctl enable "$service_name" >/dev/null
  sudo systemctl restart "$service_name"
}

