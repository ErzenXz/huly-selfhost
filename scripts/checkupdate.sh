#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
STATE_FILE="${ROOT_DIR}/.build-source.json"

if [[ ! -f "$STATE_FILE" ]]; then
  echo "No ${STATE_FILE} found. Run scripts/build-from-source.sh first." >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required for checkupdate.sh. Install jq and retry (e.g., apt-get install -y jq)." >&2
  exit 3
fi

REPO=$(jq -r '.repo // empty' "$STATE_FILE" 2>/dev/null || echo "")
LOCAL_PATH=$(jq -r '.path // empty' "$STATE_FILE" 2>/dev/null || echo "")
REF=$(jq -r '.ref // empty' "$STATE_FILE" 2>/dev/null || echo "")
PLATFORM_DIR=$(jq -r '.platformDir // empty' "$STATE_FILE" 2>/dev/null || echo "")

if [[ -z "$REPO" ]]; then
  echo "State indicates a local path build; automatic update check needs --repo." >&2
  exit 3
fi

if [[ -z "$PLATFORM_DIR" ]]; then
  PLATFORM_DIR="${ROOT_DIR}/.build/platform"
fi

if [[ ! -d "$PLATFORM_DIR/.git" ]]; then
  echo "Missing clone at $PLATFORM_DIR; run scripts/build-from-source.sh --repo $REPO" >&2
  exit 4
fi

current_ref=$(git -C "$PLATFORM_DIR" rev-parse HEAD)
git -C "$PLATFORM_DIR" fetch --all --tags

if [[ -n "$REF" ]]; then
  remote_ref=$(git -C "$PLATFORM_DIR" rev-parse "$REF" || true)
else
  # default to origin/default branch
  default_branch=$(git -C "$PLATFORM_DIR" remote show origin | sed -n '/HEAD branch/s/.*: //p')
  remote_ref=$(git -C "$PLATFORM_DIR" rev-parse "origin/${default_branch}" )
fi

if [[ "$current_ref" == "$remote_ref" ]]; then
  echo "Up to date: $current_ref"
  exit 0
else
  echo "Update available"
  echo "Current: $current_ref"
  echo "Remote : $remote_ref"
  exit 10
fi


