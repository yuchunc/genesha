#!/bin/sh
set -eu

# The Fly volume mounted at DATABASE_PATH's directory is root:root on first
# boot; the release runs as nobody, so ownership must be fixed here, as
# root, before dropping privilege and exec'ing the real command.
if [ -n "${DATABASE_PATH:-}" ]; then
  mkdir -p "$(dirname "$DATABASE_PATH")"
  chown -R nobody:root "$(dirname "$DATABASE_PATH")"
fi

exec gosu nobody "$@"
