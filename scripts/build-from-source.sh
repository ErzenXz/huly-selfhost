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
    echo "Syncing and updating git submodules (recursive)"
    git -C "$PLATFORM_DIR" submodule sync --recursive || true
    git -C "$PLATFORM_DIR" submodule update --init --recursive --jobs 4 || true
  else
    echo "Cloning $REPO into $PLATFORM_DIR"
    git clone "$REPO" "$PLATFORM_DIR"
    echo "Initializing git submodules (recursive)"
    git -C "$PLATFORM_DIR" submodule sync --recursive || true
    git -C "$PLATFORM_DIR" submodule update --init --recursive --jobs 4 || true
  fi
  if [[ -n "$REF" ]]; then
    echo "Checking out $REF"
    git -C "$PLATFORM_DIR" checkout "$REF"
    git -C "$PLATFORM_DIR" pull --ff-only || true
    echo "Refreshing submodules after checkout"
    git -C "$PLATFORM_DIR" submodule sync --recursive || true
    git -C "$PLATFORM_DIR" submodule update --init --recursive --jobs 4 || true
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

# Build workspace if repo is Rush-based so pod bundles exist for Dockerfiles (e.g. pods/*/bundle)
pushd "$PLATFORM_DIR" >/dev/null

if [[ -f "rush.json" ]]; then
  echo "Detected rush.json; installing dependencies and building the monorepo"
  if ! command -v npm >/dev/null 2>&1; then
    echo "Error: npm not found. Please install Node.js (>=18) and npm, then rerun." >&2
    exit 1
  fi
  npx -y @microsoft/rush purge || true
  npx -y @microsoft/rush install
  npx -y @microsoft/rush build
fi

# Helper: choose a package manager based on lockfiles
choose_package_manager() {
  local dir="$1"
  if [[ -f "$dir/pnpm-lock.yaml" || -f "$PLATFORM_DIR/pnpm-lock.yaml" ]]; then
    echo pnpm
    return
  fi
  if [[ -f "$dir/yarn.lock" || -f "$PLATFORM_DIR/yarn.lock" ]]; then
    echo yarn
    return
  fi
  echo npm
}

# Helper: ensure bundle/bundle.js exists for a given context if Dockerfile expects it
ensure_bundle_if_needed() {
  local context="$1"
  local dockerfile="$context/Dockerfile"
  if [[ ! -f "$dockerfile" ]]; then
    return 0
  fi
  if ! grep -qE 'COPY\s+.*bundle/bundle\.js' "$dockerfile"; then
    return 0
  fi
  if [[ -f "$context/bundle/bundle.js" ]]; then
    return 0
  fi

  echo "bundle/bundle.js not found in $context; attempting to build the pod"
  # Prefer Rush targeted build for pods when available
  if [[ -f "$PLATFORM_DIR/rush.json" ]]; then
    local pod_name
    pod_name="$(basename "$context")"
    local rush_project="@hcengineering/pod-${pod_name}"
    pushd "$PLATFORM_DIR" >/dev/null
    npx -y @microsoft/rush build -t "$rush_project" || true
    popd >/dev/null
    pushd "$context" >/dev/null
    npx -y @microsoft/rushx bundle || true
    popd >/dev/null
  else
    # Fallback: try building with the detected package manager
    local pm
    pm="$(choose_package_manager "$context")"

    # Enable corepack for pnpm/yarn if available
    if command -v corepack >/dev/null 2>&1; then
      corepack enable >/dev/null 2>&1 || true
      if [[ "$pm" == "pnpm" ]]; then
        corepack prepare pnpm@latest --activate >/dev/null 2>&1 || true
      elif [[ "$pm" == "yarn" ]]; then
        corepack prepare yarn@stable --activate >/dev/null 2>&1 || true
      fi
    fi

    pushd "$context" >/dev/null
    export CI=1
    export NODE_OPTIONS="--max-old-space-size=4096"
    case "$pm" in
      pnpm)
        (pnpm install --frozen-lockfile || pnpm install) || true
        (pnpm run build || pnpm run bundle) || true
        ;;
      yarn)
        (yarn install --frozen-lockfile || yarn install) || true
        (yarn build || yarn bundle) || true
        ;;
      npm)
        (npm ci || npm install --no-audit --no-fund) || true
        (npm run build || npm run bundle) || true
        ;;
    esac
    popd >/dev/null
  fi

  # If still missing, try to locate a bundle.js somewhere under context and link/copy it
  if [[ ! -f "$context/bundle/bundle.js" ]]; then
    mapfile -t found_bundle < <(find "$context" -type f -name bundle.js | head -n 1)
    if [[ ${#found_bundle[@]} -gt 0 ]]; then
      mkdir -p "$context/bundle"
      cp -f "${found_bundle[0]}" "$context/bundle/bundle.js" || true
    fi
  fi

  if [[ ! -f "$context/bundle/bundle.js" ]]; then
    echo "Warning: Could not produce $context/bundle/bundle.js. Skipping local build for this service."
    return 1
  fi
  return 0
}

#!/usr/bin/env bash

# Fallback: attempt to build images from known service subfolders, with discovery
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

discover_context_for_service() {
  local svc="$1"
  local preset_path="${SERVICE_PATHS[$svc]:-}"
  if [[ -n "$preset_path" && -f "$PLATFORM_DIR/$preset_path/Dockerfile" ]]; then
    echo "$PLATFORM_DIR/$preset_path"
    return 0
  fi

  # Build a list of aliases/patterns to search for
  local patterns=("$svc")
  case "$svc" in
    aibot) patterns=("aibot" "ai-bot") ;;
    front) patterns=("front" "frontend") ;;
    stats) patterns=("stats" "statistics") ;;
    fulltext) patterns=("fulltext" "full-text") ;;
  esac

  # Collect all directories that contain a Dockerfile
  mapfile -t dockerfile_dirs < <(find "$PLATFORM_DIR" -type f -name Dockerfile -printf '%h\n' | sort -u)
  if [[ ${#dockerfile_dirs[@]} -eq 0 ]]; then
    return 1
  fi

  # Prefer paths under apps/ or services/ if present
  local candidates=()
  for dir in "${dockerfile_dirs[@]}"; do
    candidates+=("$dir")
  done

  # Match first directory whose path contains one of the patterns
  for pat in "${patterns[@]}"; do
    for dir in "${candidates[@]}"; do
      if echo "$dir" | grep -Eiq "/${pat}(/|$)"; then
        echo "$dir"
        return 0
      fi
    done
  done

  # As a last resort, looser match anywhere in the path
  for pat in "${patterns[@]}"; do
    for dir in "${candidates[@]}"; do
      if echo "$dir" | grep -Eiq "${pat}"; then
        echo "$dir"
        return 0
      fi
    done
  done

  return 1
}

IMAGES_FILE="${ROOT_DIR}/.images.conf"
> "$IMAGES_FILE"

for svc in account front collaborator transactor workspace fulltext stats rekoni love aibot; do
  context="$(discover_context_for_service "$svc" || true)"
  if [[ -n "$context" && -f "$context/Dockerfile" ]]; then
    ensure_bundle_if_needed "$context" || {
      echo "Skipping $svc due to missing required bundle."
      continue
    }
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
    echo "Skipping $svc (no Dockerfile found)"
  fi
done

popd >/dev/null

echo "Written image overrides to $IMAGES_FILE"
echo "To use with compose: docker compose --env-file .images.conf up -d"


