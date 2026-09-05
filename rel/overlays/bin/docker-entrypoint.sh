#!/bin/sh
set -eu

# The Fly volume mounted at DATABASE_PATH's directory is root:root on first
# boot; the release runs as nobody, so ownership must be fixed here, as
# root, before dropping privilege and exec'ing the real command.
if [ -n "${DATABASE_PATH:-}" ]; then
  mkdir -p "$(dirname "$DATABASE_PATH")"
  chown -R nobody:root "$(dirname "$DATABASE_PATH")"
fi

# Litestream fails closed when its S3 replica is unconfigured (exits before
# -exec ever runs), so only wrap the release in it when a bucket is actually
# set. Otherwise the release runs unreplicated rather than not running at
# all — true on a fresh deploy before secrets are configured, and true of
# every local/dev container run.
if [ -n "${LITESTREAM_BUCKET:-}" ]; then
  exec gosu nobody litestream replicate -config /etc/litestream.yml -exec "$1"
else
  echo "LITESTREAM_BUCKET not set; starting without replication" >&2
  exec gosu nobody "$@"
fi
