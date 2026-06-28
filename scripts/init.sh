#!/usr/bin/env bash
# Idempotent Postal initialization: render config, generate keys, migrate DB, create admin.
set -euo pipefail

CONFIG_DIR="/config"
TEMPLATES_DIR="/templates"
SCRIPTS_DIR="/scripts"

log() {
  echo "[postal-init] $*"
}

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

# Substitute ${VAR} placeholders from the environment (Postal image has no envsubst).
render_template() {
  ruby "${SCRIPTS_DIR}/render-template.rb" "$1"
}

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

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  local mx_file="${tmp_dir}/mx-records.yaml"
  build_mx_records_yaml > "${mx_file}"

  render_template "${TEMPLATES_DIR}/postal.yml" > "${tmp_dir}/postal.yml.tmp"

  sed "/__DNS_MX_RECORDS__/{
    r ${mx_file}
    d
  }" "${tmp_dir}/postal.yml.tmp" > "${CONFIG_DIR}/postal.yml"
  rm -rf "${tmp_dir}"

  render_template "${TEMPLATES_DIR}/smtp.yml" >> "${CONFIG_DIR}/postal.yml"

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

fix_config_permissions() {
  if id postal >/dev/null 2>&1; then
    chown -R postal:postal "${CONFIG_DIR}"
  fi
  chmod 644 "${CONFIG_DIR}/postal.yml" 2>/dev/null || true
  chmod 600 "${CONFIG_DIR}/signing.key" 2>/dev/null || true
}

main() {
  log "Starting Postal initialization..."
  render_config
  generate_signing_key
  fix_config_permissions
  initialize_database
  "${SCRIPTS_DIR}/create-user.sh"
  log "Postal initialization complete."
}

main "$@"
