#!/usr/bin/env bash
# Idempotent Postal initialization: render config, generate keys, migrate DB, create admin.
set -euo pipefail

CONFIG_DIR="/config"
TEMPLATES_DIR="/templates"
SCRIPTS_DIR="/scripts"

log() {
  echo "[postal-init] $*"
}

# Variables consumed by envsubst when rendering templates
export POSTAL_HOSTNAME POSTAL_WEB_HOST POSTAL_SMTP_HOST
export SECRET_KEY RAILS_ENV LOG_LEVEL
export DATABASE_HOST DATABASE_PORT DATABASE_USER DATABASE_PASSWORD DATABASE_NAME
export DNS_SPF DNS_DKIM_SELECTOR DNS_RETURN_PATH

require_var() {
  local name="$1"
  if [ -z "${!name:-}" ]; then
    log "ERROR: required environment variable ${name} is not set"
    exit 1
  fi
}

require_var POSTAL_HOSTNAME
require_var POSTAL_WEB_HOST
require_var POSTAL_SMTP_HOST
require_var SECRET_KEY
require_var DATABASE_HOST
require_var DATABASE_USER
require_var DATABASE_PASSWORD
require_var DATABASE_NAME

: "${RAILS_ENV:=production}"
: "${DATABASE_PORT:=3306}"
: "${DNS_DKIM_SELECTOR:=postal}"
: "${DNS_MX:=mx1.${POSTAL_HOSTNAME}}"

# Build YAML list for mx_records from comma-separated DNS_MX
build_mx_records_yaml() {
  local IFS=','
  local -a records=()
  read -ra records <<< "${DNS_MX}"
  for record in "${records[@]}"; do
    record="$(echo "${record}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    if [ -n "${record}" ]; then
      printf '    - %s\n' "${record}"
    fi
  done
}

render_config() {
  log "Rendering configuration templates..."
  mkdir -p "${CONFIG_DIR}"

  local mx_yaml
  mx_yaml="$(build_mx_records_yaml)"

  # Render postal.yml with MX records substitution
  envsubst \
    '${POSTAL_HOSTNAME} ${POSTAL_WEB_HOST} ${POSTAL_SMTP_HOST} ${SECRET_KEY} ${RAILS_ENV} ${LOG_LEVEL} ${DATABASE_HOST} ${DATABASE_PORT} ${DATABASE_USER} ${DATABASE_PASSWORD} ${DATABASE_NAME} ${DNS_SPF} ${DNS_DKIM_SELECTOR} ${DNS_RETURN_PATH}' \
    < "${TEMPLATES_DIR}/postal.yml" > "${CONFIG_DIR}/postal.yml.tmp"

  awk -v mx="${mx_yaml}" '
    /__DNS_MX_RECORDS__/ {
      print mx
      next
    }
    { print }
  ' "${CONFIG_DIR}/postal.yml.tmp" > "${CONFIG_DIR}/postal.yml"
  rm -f "${CONFIG_DIR}/postal.yml.tmp"

  envsubst \
    '${POSTAL_HOSTNAME}' \
    < "${TEMPLATES_DIR}/smtp.yml" >> "${CONFIG_DIR}/postal.yml"

  log "Configuration written to ${CONFIG_DIR}/postal.yml"
}

generate_signing_key() {
  if [ -f "${CONFIG_DIR}/signing.key" ]; then
    log "Signing key already exists, skipping generation."
    return 0
  fi

  log "Generating DKIM signing key..."
  openssl genrsa -out "${CONFIG_DIR}/signing.key" 2048
  chmod 600 "${CONFIG_DIR}/signing.key"
  log "Signing key generated at ${CONFIG_DIR}/signing.key"
}

database_initialized() {
  ruby -r mysql2 -e "
    client = Mysql2::Client.new(
      host: ENV.fetch('DATABASE_HOST'),
      port: ENV.fetch('DATABASE_PORT', '3306').to_i,
      username: ENV.fetch('DATABASE_USER'),
      password: ENV.fetch('DATABASE_PASSWORD'),
      database: ENV.fetch('DATABASE_NAME')
    )
    result = client.query(\"SHOW TABLES LIKE 'schema_migrations'\")
    exit(result.count.positive? ? 0 : 1)
  " 2>/dev/null
}

initialize_database() {
  if database_initialized; then
    log "Database schema detected, running postal upgrade (migrations)..."
    postal upgrade
  else
    log "Database not initialized, running postal initialize..."
    postal initialize
    log "Running postal upgrade after initialize..."
    postal upgrade
  fi
}

main() {
  log "Starting Postal initialization..."
  render_config
  generate_signing_key
  initialize_database
  "${SCRIPTS_DIR}/create-user.sh"
  log "Postal initialization complete."
}

main "$@"
