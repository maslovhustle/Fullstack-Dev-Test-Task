#!/usr/bin/env bash
# Writes one archive with the database and Ghost content, and keeps the last 7.
set -euo pipefail

compose=${GHOST_COMPOSE:-ghost-compose}
data_dir=${DATA_DIR:-/mnt/ghost}
keep=${BACKUP_KEEP:-7}
archive="$data_dir/backups/ghost-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# shellcheck disable=SC2016  # expanded inside the container, not here
$compose exec -T db sh -c \
  'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysqldump -u root --single-transaction --no-tablespaces ghost' \
  | gzip > "$work/db.sql.gz"
tar -C "$data_dir" -czf "$work/content.tar.gz" ghost-content
tar -C "$work" -czf "$archive" db.sql.gz content.tar.gz
chmod 600 "$archive"

find "$data_dir/backups" -name 'ghost-*.tar.gz' | sort -r | tail -n +"$((keep + 1))" | xargs -r rm -f
echo "$archive"
