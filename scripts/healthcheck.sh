#!/usr/bin/env bash
# Health probes for Postal services using Ruby TCPSocket (available in the Postal image).
set -euo pipefail

MODE="${1:-}"

check_port() {
  local host="$1"
  local port="$2"
  ruby -rsocket -e "
    socket = TCPSocket.new('${host}', ${port})
    socket.close
  "
}

case "${MODE}" in
  web)
    check_port "127.0.0.1" 5000
    ;;
  worker)
    check_port "127.0.0.1" 9090
    ;;
  smtp)
    check_port "127.0.0.1" 9091
    ;;
  *)
    echo "Usage: $0 {web|worker|smtp}" >&2
    exit 1
    ;;
esac
