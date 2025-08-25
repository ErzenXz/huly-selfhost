#!/usr/bin/env bash

set -euo pipefail

# Usage: scripts/redeploy.sh [--from-source] [--repo URL|--path DIR] [--ref REF] [--registry PREFIX] [--no-cache]

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT_DIR"

FROM_SOURCE=false
BUILD_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from-source)
      FROM_SOURCE=true
      shift
      ;;
    --repo|--path|--ref|--registry)
      BUILD_ARGS+=("$1" "$2")
      shift 2
      ;;
    --no-cache)
      BUILD_ARGS+=("--no-cache")
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

# Load deployment configuration so docker compose has variables
if [[ -f huly.conf ]]; then
  set -a
  # shellcheck disable=SC1091
  source huly.conf
  set +a
fi

# Ensure required defaults
export DOCKER_NAME="${DOCKER_NAME:-huly}"
if [[ -z "${SECRET:-}" && -f .huly.secret ]]; then
  export SECRET="$(cat .huly.secret)"
fi

echo "Generating Nginx configs (.huly.nginx and nginx.conf)"
printf 'n\n' | ./nginx.sh

if [[ "$FROM_SOURCE" == true ]]; then
  echo "Building images from source with unique tags to avoid stale cache..."
  bash scripts/build-from-source.sh "${BUILD_ARGS[@]}"
fi

# Prefer passing env files explicitly so compose has all variables
if [[ -f .images.conf && -f huly.conf ]]; then
  docker compose --env-file huly.conf --env-file .images.conf pull --ignore-pull-failures || true
  docker compose --env-file huly.conf --env-file .images.conf up -d --force-recreate --remove-orphans --pull always
elif [[ -f huly.conf ]]; then
  docker compose --env-file huly.conf pull --ignore-pull-failures || true
  docker compose --env-file huly.conf up -d --force-recreate --remove-orphans --pull always
elif [[ -f .images.conf ]]; then
  docker compose --env-file .images.conf pull --ignore-pull-failures || true
  docker compose --env-file .images.conf up -d --force-recreate --remove-orphans --pull always
else
  docker compose pull --ignore-pull-failures || true
  docker compose up -d --force-recreate --remove-orphans --pull always
fi

echo "Nginx container logs (last 50 lines):"
docker logs huly-nginx-1 --tail 50 | cat || true

echo "Front container image:"
docker inspect -f '{{.Config.Image}}' huly-front-1 || true

echo "Check front index.html presence:"
docker exec huly-front-1 sh -lc 'ls -l /app/dist/index.html || true' || true

echo "Done."


