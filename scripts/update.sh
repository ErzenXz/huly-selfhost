#!/usr/bin/env bash

set -euo pipefail

# Rebuild images from the recorded source and restart services

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
STATE_FILE="${ROOT_DIR}/.build-source.json"

# Concurrency lock
FORCE=false
for arg in "$@"; do
  case $arg in
    --force) FORCE=true ;;
    --help) echo "Usage: $0 [--force]"; exit 0 ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done

LOCK_DIR="${ROOT_DIR}/.update.lock"
if [[ "$FORCE" == true && -d "$LOCK_DIR" ]]; then
  echo "Forcing removal of existing update lock..."
  rm -rf "$LOCK_DIR"
fi
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo "Another update is in progress (lock: $LOCK_DIR). Use --force to override." >&2
  exit 1
fi
cleanup() { rm -rf "$LOCK_DIR"; }
trap cleanup EXIT

if [[ ! -f "$STATE_FILE" ]]; then
  echo "No ${STATE_FILE} found. Run scripts/build-from-source.sh first." >&2
  exit 2
fi

REPO=$(jq -r '.repo // empty' "$STATE_FILE" 2>/dev/null || echo "")
LOCAL_PATH=$(jq -r '.path // empty' "$STATE_FILE" 2>/dev/null || echo "")
REF=$(jq -r '.ref // empty' "$STATE_FILE" 2>/dev/null || echo "")
REGISTRY_PREFIX=$(jq -r '.registryPrefix // empty' "$STATE_FILE" 2>/dev/null || echo "")

if [[ -n "$REPO" ]]; then
  echo "Fetching latest from $REPO ${REF:+(ref: $REF)}"
  if ! bash scripts/checkupdate.sh; then
    echo "Updates found; proceeding to rebuild"
  else
    echo "No updates; rebuilding anyway (cache may apply)"
  fi
  BUILD_ARGS=(--repo "$REPO")
  if [[ -n "$REF" ]]; then BUILD_ARGS+=(--ref "$REF"); fi
else
  echo "Using local path: ${LOCAL_PATH}"
  BUILD_ARGS=(--path "$LOCAL_PATH")
fi

if [[ -n "$REGISTRY_PREFIX" ]]; then
  BUILD_ARGS+=(--registry "$REGISTRY_PREFIX")
fi

scripts/build-from-source.sh "${BUILD_ARGS[@]}"

echo "Restarting services (docker compose)"
if [[ -f "${ROOT_DIR}/.images.conf" ]]; then
  docker compose --env-file "${ROOT_DIR}/.images.conf" up -d --force-recreate
else
  docker compose up -d --force-recreate
fi

echo "Update complete."


