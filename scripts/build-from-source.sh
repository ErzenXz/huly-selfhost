#!/usr/bin/env bash

set -euo pipefail

# Usage:
#  scripts/build-from-source.sh --repo https://github.com/hcengineering/platform.git --ref v0.6.502
#  scripts/build-from-source.sh --path /path/to/local/platform --ref main
#
# This script builds Huly images from source and writes .images.conf
# with IMAGE_* variables that docker compose and k8s can consume.

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
WORK_DIR="${ROOT_DIR}/.build"
PLATFORM_DIR=""
REF=""
REPO=""
LOCAL_PATH=""
REGISTRY_PREFIX=""
STATE_FILE="${ROOT_DIR}/.build-source.json"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo=*)
      REPO="${1#*=}"
      shift
      ;;
    --repo)
      REPO="$2"
      shift 2
      ;;
    --path=*)
      LOCAL_PATH="${1#*=}"
      shift
      ;;
    --path)
      LOCAL_PATH="$2"
      shift 2
      ;;
    --ref=*)
      REF="${1#*=}"
      shift
      ;;
    --ref)
      REF="$2"
      shift 2
      ;;
    --registry=*)
      REGISTRY_PREFIX="${1#*=}"
      shift
      ;;
    --registry)
      REGISTRY_PREFIX="$2"
      shift 2
      ;;
    --help)
      echo "Usage: $0 [--repo URL|--path DIR] [--ref REF] [--registry PREFIX]"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

if [[ -z "$REPO" && -z "$LOCAL_PATH" ]]; then
  echo "Either --repo or --path must be provided" >&2
  exit 1
fi

mkdir -p "$WORK_DIR"

if [[ -n "$REPO" ]]; then
  PLATFORM_DIR="${WORK_DIR}/platform"
  if [[ -d "$PLATFORM_DIR/.git" ]]; then
    echo "Updating existing clone at $PLATFORM_DIR"
    git -C "$PLATFORM_DIR" fetch --all --tags
  else
    echo "Cloning $REPO into $PLATFORM_DIR"
    git clone "$REPO" "$PLATFORM_DIR"
  fi
  if [[ -n "$REF" ]]; then
    echo "Checking out $REF"
    git -C "$PLATFORM_DIR" checkout "$REF"
    git -C "$PLATFORM_DIR" pull --ff-only || true
  fi
else
  PLATFORM_DIR="$(cd "$LOCAL_PATH" && pwd)"
  if [[ -n "$REF" ]]; then
    echo "Warning: --ref is ignored when using --path"
  fi
fi

echo "Platform directory: $PLATFORM_DIR"

# Persist build source info for update scripts
cat > "$STATE_FILE" <<JSON
{
  "repo": "${REPO}",
  "path": "${LOCAL_PATH}",
  "ref": "${REF}",
  "registryPrefix": "${REGISTRY_PREFIX}",
  "platformDir": "${PLATFORM_DIR//\\/\\\\}"
}
JSON

# Build images using Rush if available, otherwise try docker build for known services.
pushd "$PLATFORM_DIR" >/dev/null

if command -v rush >/dev/null 2>&1; then
  echo "Running rush docker:build (if defined)"
  if npm run -s | grep -q "docker:build" 2>/dev/null || rush list >/dev/null 2>&1; then
    # Try common monorepo target; users can customize if needed
    npx -y @microsoft/rush list >/dev/null 2>&1 || true
    npx -y @microsoft/rush purge || true
    npx -y @microsoft/rush install
    npx -y @microsoft/rush build
    # If repo provides a dev command to build images, try it
    if npx -y @microsoft/rush list-projects 2>/dev/null | grep -qi "docker"; then
      true
    fi
  fi
fi

# Fallback: attempt to build images from known service subfolders
declare -A SERVICE_PATHS
SERVICE_PATHS[
  account
]=apps/account
SERVICE_PATHS[
  front
]=apps/front
SERVICE_PATHS[
  collaborator
]=apps/collaborator
SERVICE_PATHS[
  transactor
]=apps/transactor
SERVICE_PATHS[
  workspace
]=apps/workspace
SERVICE_PATHS[
  fulltext
]=services/fulltext
SERVICE_PATHS[
  stats
]=services/stats
SERVICE_PATHS[
  rekoni
]=services/rekoni
SERVICE_PATHS[
  love
]=services/love
SERVICE_PATHS[
  aibot
]=services/ai-bot

IMAGES_FILE="${ROOT_DIR}/.images.conf"
> "$IMAGES_FILE"

for svc in account front collaborator transactor workspace fulltext stats rekoni love aibot; do
  subdir="${SERVICE_PATHS[$svc]:-}"
  if [[ -z "$subdir" ]]; then
    continue
  fi
  context="$PLATFORM_DIR/$subdir"
  if [[ -f "$context/Dockerfile" ]]; then
    tag_base="${REGISTRY_PREFIX:+${REGISTRY_PREFIX}/}huly/${svc}:local"
    echo "Building $svc from $context as $tag_base"
    docker build -t "$tag_base" "$context"
    case "$svc" in
      rekoni)    echo "IMAGE_REKONI=$tag_base" >> "$IMAGES_FILE" ;;
      account)   echo "IMAGE_ACCOUNT=$tag_base" >> "$IMAGES_FILE" ;;
      collaborator) echo "IMAGE_COLLABORATOR=$tag_base" >> "$IMAGES_FILE" ;;
      transactor) echo "IMAGE_TRANSACTOR=$tag_base" >> "$IMAGES_FILE" ;;
      workspace) echo "IMAGE_WORKSPACE=$tag_base" >> "$IMAGES_FILE" ;;
      front)     echo "IMAGE_FRONT=$tag_base" >> "$IMAGES_FILE" ;;
      fulltext)  echo "IMAGE_FULLTEXT=$tag_base" >> "$IMAGES_FILE" ;;
      stats)     echo "IMAGE_STATS=$tag_base" >> "$IMAGES_FILE" ;;
      love)      echo "IMAGE_LOVE=$tag_base" >> "$IMAGES_FILE" ;;
      aibot)     echo "IMAGE_AIBOT=$tag_base" >> "$IMAGES_FILE" ;;
    esac
  else
    echo "Skipping $svc (no Dockerfile at $context)"
  fi
done

popd >/dev/null

echo "Written image overrides to $IMAGES_FILE"
echo "To use with compose: docker compose --env-file .images.conf up -d"


