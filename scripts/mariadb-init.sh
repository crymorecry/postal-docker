#!/bin/bash
# MariaDB first-boot grants for Postal message databases (postal-* prefix).
# Mounted into /docker-entrypoint-initdb.d/ — runs only on empty data directory.
set -euo pipefail

mysql -u root -p"${MARIADB_ROOT_PASSWORD}" <<-EOSQL
    GRANT ALL PRIVILEGES ON \`${MARIADB_DATABASE}\`.* TO '${MARIADB_USER}'@'%';
    GRANT ALL PRIVILEGES ON \`postal-%\`.* TO '${MARIADB_USER}'@'%';
    FLUSH PRIVILEGES;
EOSQL

echo "Postal MariaDB grants applied for ${MARIADB_USER}@'%'."
