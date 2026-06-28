#!/usr/bin/env bash
# Idempotent first admin user creation.
set -euo pipefail

log() {
  echo "[create-user] $*"
}

if [ -z "${INITIAL_ADMIN_EMAIL:-}" ] || [ -z "${INITIAL_ADMIN_PASSWORD:-}" ]; then
  log "INITIAL_ADMIN_EMAIL or INITIAL_ADMIN_PASSWORD not set — skipping admin user creation."
  log "Create an admin manually: docker compose run --rm postal-web postal make-user"
  exit 0
fi

: "${INITIAL_ADMIN_FIRST_NAME:=Admin}"
: "${INITIAL_ADMIN_LAST_NAME:=User}"

user_exists() {
  ruby -r mysql2 -e "
    require 'mysql2'
    email = ENV.fetch('INITIAL_ADMIN_EMAIL')
    client = Mysql2::Client.new(
      host: ENV.fetch('DATABASE_HOST'),
      port: ENV.fetch('DATABASE_PORT', '3306').to_i,
      username: ENV.fetch('DATABASE_USER'),
      password: ENV.fetch('DATABASE_PASSWORD'),
      database: ENV.fetch('DATABASE_NAME')
    )
    stmt = client.prepare('SELECT COUNT(*) AS count FROM users WHERE email = ?')
    result = stmt.execute(email).first
    exit(result['count'].to_i.positive? ? 0 : 1)
  " 2>/dev/null
}

create_user() {
  log "Creating admin user ${INITIAL_ADMIN_EMAIL}..."
  printf '%s\n' \
    "${INITIAL_ADMIN_EMAIL}" \
    "${INITIAL_ADMIN_FIRST_NAME}" \
    "${INITIAL_ADMIN_LAST_NAME}" \
    "${INITIAL_ADMIN_PASSWORD}" \
    "${INITIAL_ADMIN_PASSWORD}" \
    | postal make-user
}

if user_exists; then
  log "Admin user ${INITIAL_ADMIN_EMAIL} already exists, skipping."
  exit 0
fi

create_user
log "Admin user created successfully."
