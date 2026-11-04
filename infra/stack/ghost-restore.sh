#!/usr/bin/env bash
# Replaces the database and Ghost content with those from a backup archive.
set -euo pipefail

archive=${1:?usage: ghost-restore <archive.tar.gz>}
compose=${GHOST_COMPOSE:-ghost-compose}
data_dir=${DATA_DIR:-/mnt/ghost}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
tar -C "$work" -xzf "$archive" db.sql.gz content.tar.gz

$compose stop ghost
# shellcheck disable=SC2016  # expanded inside the container, not here
gzip -dc "$work/db.sql.gz" | $compose exec -T db sh -c \
  'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -u root ghost'
rm -rf "${data_dir:?}/ghost-content"
tar -C "$data_dir" -xzf "$work/content.tar.gz"
$compose start ghost
echo "Restored $archive"
