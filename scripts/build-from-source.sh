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
NO_CACHE=false
TAG_SUFFIX=""
FRONT_DIST_PATH=""
STATE_FILE="${ROOT_DIR}/.build-source.json"

# -------------------------
# Progress UI helpers
# -------------------------
PROGRESS_TOTAL_STEPS=${PROGRESS_TOTAL_STEPS:-13}
PROGRESS_STEP_INDEX=0
PROGRESS_START_TS=$(date +%s)
PROGRESS_STEP_START_TS=$PROGRESS_START_TS
PROGRESS_LAST_LINE=""

color_blue="\033[1;34m"
color_green="\033[1;32m"
color_yellow="\033[33m"
color_reset="\033[0m"

progress_step_start() {
  :
}

progress_step_end() {
  :
}

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
    --no-cache)
      NO_CACHE=true
      shift
      ;;
    --tag-suffix=*)
      TAG_SUFFIX="${1#*=}"
      shift
      ;;
    --tag-suffix)
      TAG_SUFFIX="$2"
      shift 2
      ;;
    --front-dist=*)
      FRONT_DIST_PATH="${1#*=}"
      shift
      ;;
    --front-dist)
      FRONT_DIST_PATH="$2"
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
:

:
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
:

:
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
:

# Build workspace if repo is Rush-based so pod bundles exist for Dockerfiles (e.g. pods/*/bundle)
:
pushd "$PLATFORM_DIR" >/dev/null

if [[ -f "rush.json" ]]; then
  echo "Detected rush.json; installing dependencies and building the monorepo"
  if ! command -v npm >/dev/null 2>&1; then
    echo "Error: npm not found. Please install Node.js (>=18) and npm, then rerun." >&2
    exit 1
  fi
    npx -y @microsoft/rush purge || true
    npx -y @microsoft/rush install
    # Build front first if present to ensure dist assets exist (use rush runner, not rushx)
    if [[ -d "apps/front" || -d "server/front" || -d "pods/front" ]]; then
      if [[ -f "common/scripts/install-run-rush.js" ]]; then
        node common/scripts/install-run-rush.js build -t front || true
      fi
    fi
    npx -y @microsoft/rush build
fi
popd >/dev/null
:

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

# Helper: find rushx runner script from a context by walking up to repo root
find_rushx_script() {
  local dir="$1"
  local attempts=0
  while [[ "$dir" != "/" && $attempts -lt 6 ]]; do
    if [[ -f "$dir/common/scripts/install-run-rushx.js" ]]; then
      echo "$dir/common/scripts/install-run-rushx.js"
      return 0
    fi
    dir="$(dirname "$dir")"
    attempts=$((attempts+1))
  done
  return 1
}

# Helper: parse package name from package.json (best-effort)
read_package_name() {
  local context="$1"
  if [[ -f "$context/package.json" ]]; then
    sed -n 's/^\s*"name"\s*:\s*"\(.*\)".*/\1/p' "$context/package.json" | head -n1
  fi
}

# Helper: best-effort copy of an alternative artifact source into the context
copy_alt_artifact_dir() {
  local src_dir="$1"
  local dst_dir="$2"
  if [[ -d "$src_dir" ]]; then
    mkdir -p "$(dirname "$dst_dir")"
    rm -rf "$dst_dir"
    cp -r "$src_dir" "$dst_dir" || true
    return 0
  fi
  return 1
}

# Helper: try to locate a suitable dist with index.html for a given context (e.g., pods/front)
populate_dist_assets() {
  local context="$1"
  local target_dist="$context/dist"
  if [[ -d "$target_dist" && -f "$target_dist/index.html" ]]; then
    return 0
  fi
  # Prefer well-known locations
  local candidates=(
    "$PLATFORM_DIR/server/front/dist"
    "$PLATFORM_DIR/apps/front/dist"
    "$PLATFORM_DIR/pods/front/dist"
    "$PLATFORM_DIR/server/front/build"
    "$PLATFORM_DIR/apps/front/build"
    "$PLATFORM_DIR/pods/front/build"
    "$PLATFORM_DIR/server/front/out"
    "$PLATFORM_DIR/apps/front/out"
    "$PLATFORM_DIR/pods/front/out"
  )
  # Fallback: any dist with index.html under repo
  mapfile -t more_candidates < <(find "$PLATFORM_DIR" -type f -name index.html \( -path "*/dist/index.html" -o -path "*/build/index.html" -o -path "*/out/index.html" \) -printf '%h\n' | sort -u | head -n 10)
  candidates+=("${more_candidates[@]}")
  for d in "${candidates[@]}"; do
    if [[ -d "$d" && -f "$d/index.html" ]]; then
      mkdir -p "$target_dist"
      rm -rf "$target_dist"
      cp -r "$d" "$target_dist" || true
      break
    fi
  done
  [[ -d "$target_dist" && -f "$target_dist/index.html" ]]
}

# Helper: create a minimal SPA index.html referencing the bundle
create_minimal_index_html() {
  local context="$1"
  local target_dist="$context/dist"
  mkdir -p "$target_dist"
  cat > "$target_dist/index.html" <<'HTML'
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Huly</title>
  </head>
  <body>
    <div id="root"></div>
    <script src="/bundle/bundle.js"></script>
  </body>
  </html>
HTML
}

# Helper: ensure required build artifacts exist based on Dockerfile expectations
ensure_bundle_if_needed() {
  local context="$1"
  local dockerfile="$context/Dockerfile"
  if [[ ! -f "$dockerfile" ]]; then
    return 0
  fi
  local needs_bundle=false
  local needs_lib=false
  local needs_dist=false
  local needs_model_json=false
  if grep -qE 'COPY\s+.*bundle/bundle\.js' "$dockerfile"; then needs_bundle=true; fi
  if grep -qE 'COPY\s+\./lib(\s|$)|COPY\s+lib(\s|$)' "$dockerfile"; then needs_lib=true; fi
  if grep -qE 'COPY\s+\./dist/?(\s|$)|COPY\s+dist/?(\s|$)' "$dockerfile"; then needs_dist=true; fi
  if grep -qE 'COPY\s+.*bundle/model\.json' "$dockerfile"; then needs_model_json=true; fi

  # Quick exit if nothing special needed
  if [[ "$needs_bundle" != true && "$needs_lib" != true && "$needs_dist" != true && "$needs_model_json" != true ]]; then
    return 0
  fi

  local pkg_name
  pkg_name="$(read_package_name "$context")"

  # Try Rush targeted build first when available
  if [[ -f "$PLATFORM_DIR/rush.json" && -n "$pkg_name" ]]; then
    pushd "$PLATFORM_DIR" >/dev/null
    npx -y @microsoft/rush build -t "$pkg_name" || true
    popd >/dev/null
    # Try rushx inside the package for bundle/build
    local rushx_js
    rushx_js="$(find_rushx_script "$context")" || true
    if [[ -n "$rushx_js" ]]; then
      if [[ "$needs_bundle" == true && ! -f "$context/bundle/bundle.js" ]]; then
        (cd "$context" && node "$rushx_js" bundle) || true
      fi
      if [[ "$needs_lib" == true && ! -d "$context/lib" ]]; then
        (cd "$context" && node "$rushx_js" build) || true
      fi
      if [[ "$needs_dist" == true && ! -d "$context/dist" ]]; then
        (cd "$context" && node "$rushx_js" bundle) || true
        if [[ ! -d "$context/dist" ]]; then (cd "$context" && node "$rushx_js" package) || true; fi
        if [[ ! -d "$context/dist" ]]; then (cd "$context" && node "$rushx_js" build) || true; fi
      fi
      if [[ "$needs_model_json" == true && ! -f "$context/bundle/model.json" ]]; then
        (cd "$context" && node "$rushx_js" bundle) || true
      fi
    fi
  fi

  # If this looks like a front context and dist is still missing, try repo-wide bundle/package
  if [[ "$context" =~ /front(/|$) && -f "$PLATFORM_DIR/rush.json" && ! -d "$context/dist" ]]; then
    pushd "$PLATFORM_DIR" >/dev/null
    npx -y @microsoft/rush bundle || true
    npx -y @microsoft/rush package || true
    popd >/dev/null
  fi

  # Fallback: try building with the detected package manager directly in the context
  if [[ "$needs_bundle" == true && ! -f "$context/bundle/bundle.js" ]] || [[ "$needs_lib" == true && ! -d "$context/lib" ]] || [[ "$needs_dist" == true && ! -d "$context/dist" ]] || [[ "$needs_model_json" == true && ! -f "$context/bundle/model.json" ]]; then
    local pm
    pm="$(choose_package_manager "$context")"
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
    export HUSKY=0
    case "$pm" in
      pnpm)
        (pnpm install --frozen-lockfile || pnpm install) || true
        if [[ "$needs_bundle" == true ]]; then (pnpm run bundle || pnpm run build) || true; fi
        if [[ "$needs_lib" == true ]]; then (pnpm run build || pnpm run compile) || true; fi
        if [[ "$needs_dist" == true ]]; then (pnpm run build || pnpm run bundle || pnpm run package || pnpm run compile) || true; fi
        if [[ "$needs_model_json" == true && ! -f "$context/bundle/model.json" ]]; then (pnpm run bundle || true); fi
        ;;
      yarn)
        (yarn install --frozen-lockfile || yarn install) || true
        if [[ "$needs_bundle" == true ]]; then (yarn bundle || yarn build) || true; fi
        if [[ "$needs_lib" == true ]]; then (yarn build || yarn compile) || true; fi
        if [[ "$needs_dist" == true ]]; then (yarn build || yarn bundle || yarn package || yarn compile) || true; fi
        if [[ "$needs_model_json" == true && ! -f "$context/bundle/model.json" ]]; then (yarn bundle || true); fi
        ;;
      npm)
        (npm install --no-audit --no-fund) || true
        if [[ "$needs_bundle" == true ]]; then (npm run bundle || npm run build) || true; fi
        if [[ "$needs_lib" == true ]]; then (npm run build || npm run compile) || true; fi
        if [[ "$needs_dist" == true ]]; then (npm run build || npm run bundle || npm run package || npm run compile) || true; fi
        if [[ "$needs_model_json" == true && ! -f "$context/bundle/model.json" ]]; then (npm run bundle || true); fi
        ;;
    esac
    popd >/dev/null
  fi

  # Final checks and last-resort copy
  if [[ "$needs_bundle" == true && ! -f "$context/bundle/bundle.js" ]]; then
    mapfile -t found_bundle < <(find "$context" -type f -name bundle.js | head -n 1)
    if [[ ${#found_bundle[@]} -gt 0 ]]; then
      mkdir -p "$context/bundle"
      cp -f "${found_bundle[0]}" "$context/bundle/bundle.js" || true
    fi
  fi
  if [[ "$needs_lib" == true && ! -d "$context/lib" ]]; then
    # Some repos build into dist/. Accept either and copy if needed
    copy_alt_artifact_dir "$context/dist" "$context/lib" || true
  fi
  if [[ "$needs_dist" == true && ! -d "$context/dist" ]]; then
    # Some repos build into lib/. Accept either and copy if needed
    copy_alt_artifact_dir "$context/lib" "$context/dist" || true
    # Also accept build/ and out/
    if [[ ! -d "$context/dist" ]]; then copy_alt_artifact_dir "$context/build" "$context/dist" || true; fi
    if [[ ! -d "$context/dist" ]]; then copy_alt_artifact_dir "$context/out" "$context/dist" || true; fi
    # As a stronger fallback, search repo for a suitable dist with index.html
    if [[ ! -f "$context/dist/index.html" ]]; then
      populate_dist_assets "$context" || true
    fi
    # Last resort: generate a minimal index.html that loads the bundle
    if [[ ! -f "$context/dist/index.html" && -f "$context/bundle/bundle.js" ]]; then
      create_minimal_index_html "$context" || true
    fi
  fi
  if [[ "$needs_model_json" == true && ! -f "$context/bundle/model.json" ]]; then
    # Try to locate model.json within context or repo
    mapfile -t found_model < <(find "$context" -type f -name model.json | head -n 1)
    if [[ ${#found_model[@]} -eq 0 ]]; then
      mapfile -t found_model < <(find "$PLATFORM_DIR" -type f -name model.json | grep -E "/(fulltext|pods/fulltext|services/fulltext)/" | head -n 1)
    fi
    if [[ ${#found_model[@]} -gt 0 ]]; then
      mkdir -p "$context/bundle"
      cp -f "${found_model[0]}" "$context/bundle/model.json" || true
    fi
  fi

  # Extra fallback for front: if dist/index.html is missing but bundle exists, create a minimal index.html
  if echo "$context" | grep -Eq "/front(/|$)"; then
    if [[ -f "$context/bundle/bundle.js" && ! -f "$context/dist/index.html" ]]; then
      create_minimal_index_html "$context" || true
    fi
  fi

  # If still missing required artifacts, signal failure
  if [[ "$needs_bundle" == true && ! -f "$context/bundle/bundle.js" ]]; then
    echo "Warning: Could not produce $context/bundle/bundle.js. Skipping local build for this service."
    return 1
  fi
  if [[ "$needs_lib" == true && ! -d "$context/lib" ]]; then
    echo "Warning: Could not produce $context/lib. Skipping local build for this service."
    return 1
  fi
  if [[ "$needs_dist" == true && ! -d "$context/dist" ]]; then
    echo "Warning: Could not produce $context/dist. Skipping local build for this service."
    return 1
  fi
  if [[ "$needs_model_json" == true && ! -f "$context/bundle/model.json" ]]; then
    echo "Warning: Could not produce $context/bundle/model.json. Skipping local build for this service."
    return 1
  fi
  return 0
}

# Build the image using a minimal, controlled context to avoid .dockerignore exclusions
build_service_image() {
  local svc="$1"
  local context="$2"
  local tag_base="$3"
  local dockerfile="$context/Dockerfile"
  local tmp_ctx_dir="$WORK_DIR/build-${svc}"

  rm -rf "$tmp_ctx_dir"
  mkdir -p "$tmp_ctx_dir"

  # Copy Dockerfile
  cp "$dockerfile" "$tmp_ctx_dir/Dockerfile"
  # Ensure no excludes
  : > "$tmp_ctx_dir/.dockerignore"

  # Determine what the Dockerfile expects
  local needs_dist=false
  local needs_lib=false
  local needs_bundle=false
  if grep -qE 'COPY\s+.*bundle/bundle\.js' "$dockerfile"; then needs_bundle=true; fi
  if grep -qE 'COPY\s+\./dist/?|COPY\s+dist/?' "$dockerfile"; then needs_dist=true; fi
  if grep -qE 'COPY\s+\./lib(\s|$)|COPY\s+lib(\s|$)' "$dockerfile"; then needs_lib=true; fi

  # Populate artifacts
  # If front and explicit dist path provided, copy it in first
  if [[ "$svc" == "front" && -n "$FRONT_DIST_PATH" && -f "$FRONT_DIST_PATH/index.html" ]]; then
    mkdir -p "$context/dist"
    rm -rf "$context/dist"
    cp -r "$FRONT_DIST_PATH" "$context/dist"
  fi
  if [[ "$needs_bundle" == true && -f "$context/bundle/bundle.js" ]]; then
    mkdir -p "$tmp_ctx_dir/bundle"
    cp -f "$context/bundle/bundle.js" "$tmp_ctx_dir/bundle/" || true
    if [[ -f "$context/bundle/bundle.js.map" ]]; then
      cp -f "$context/bundle/bundle.js.map" "$tmp_ctx_dir/bundle/" || true
    fi
    if [[ -f "$context/bundle/model.json" ]]; then
      cp -f "$context/bundle/model.json" "$tmp_ctx_dir/bundle/" || true
    fi
  fi
  if [[ "$needs_dist" == true ]]; then
    if [[ -d "$context/dist" ]]; then
      cp -r "$context/dist" "$tmp_ctx_dir/dist" || true
    elif [[ -d "$context/lib" ]]; then
      # Map lib as dist if only lib exists
      cp -r "$context/lib" "$tmp_ctx_dir/dist" || true
    elif [[ -d "$context/build" ]]; then
      cp -r "$context/build" "$tmp_ctx_dir/dist" || true
    elif [[ -d "$context/out" ]]; then
      cp -r "$context/out" "$tmp_ctx_dir/dist" || true
    fi
  fi
  # Even if Dockerfile does not explicitly copy dist, include it in the context if available
  if [[ -d "$context/dist" && ! -d "$tmp_ctx_dir/dist" ]]; then
    cp -r "$context/dist" "$tmp_ctx_dir/dist" || true
  fi

  # Ensure front image always contains static assets if we have them
  if [[ "$svc" == "front" && -f "$tmp_ctx_dir/dist/index.html" ]]; then
    if ! grep -Eq 'COPY\s+\.?/dist(\s|$)|COPY\s+\./dist(\s|$)' "$tmp_ctx_dir/Dockerfile"; then
      if grep -Eq 'COPY\s+\.?/lib(\s|$)|COPY\s+\./lib(\s|$)' "$tmp_ctx_dir/Dockerfile"; then
        sed -i -E '/COPY\s+\.?\/lib(\s|$)|COPY\s+\.\/lib(\s|$)/a COPY ./dist /app/dist' "$tmp_ctx_dir/Dockerfile"
      elif grep -Eq '^(CMD|ENTRYPOINT)\b' "$tmp_ctx_dir/Dockerfile"; then
        sed -i -E '0,/^(CMD|ENTRYPOINT)\b/s//COPY \.\/dist \/app\/dist\n\1/' "$tmp_ctx_dir/Dockerfile"
      else
        echo 'COPY ./dist /app/dist' >> "$tmp_ctx_dir/Dockerfile"
      fi
    fi
    # If bundle exists, ensure it's copied under /app/dist/bundle so the fallback index can load it
    if [[ -f "$tmp_ctx_dir/bundle/bundle.js" ]]; then
      if ! grep -Eq 'COPY\s+\.?/bundle(\s|$)|COPY\s+\./bundle(\s|$)' "$tmp_ctx_dir/Dockerfile"; then
        if grep -Eq 'COPY\s+\.?/dist(\s|$)|COPY\s+\./dist(\s|$)' "$tmp_ctx_dir/Dockerfile"; then
          sed -i -E '/COPY\s+\.?\/dist(\s|$)|COPY\s+\.\/dist(\s|$)/a COPY ./bundle /app/dist/bundle' "$tmp_ctx_dir/Dockerfile"
        elif grep -Eq '^(CMD|ENTRYPOINT)\b' "$tmp_ctx_dir/Dockerfile"; then
          sed -i -E '0,/^(CMD|ENTRYPOINT)\b/s//COPY \.\/bundle \/app\/dist\/bundle\n\1/' "$tmp_ctx_dir/Dockerfile"
        else
          echo 'COPY ./bundle /app/dist/bundle' >> "$tmp_ctx_dir/Dockerfile"
        fi
      fi
    fi
  fi
  if [[ "$needs_lib" == true && -d "$context/lib" ]]; then
    cp -r "$context/lib" "$tmp_ctx_dir/lib" || true
  fi

  # Copy common files some Dockerfiles expect
  for f in package.json pnpm-lock.yaml yarn.lock package-lock.json; do
    if [[ -f "$context/$f" ]]; then
      cp -f "$context/$f" "$tmp_ctx_dir/" || true
    fi
  done

  echo "Building $svc from $context using minimal context at $tmp_ctx_dir as $tag_base"
  if [[ "$NO_CACHE" == true ]]; then
    docker build --no-cache --pull -t "$tag_base" -f "$tmp_ctx_dir/Dockerfile" "$tmp_ctx_dir"
  else
    docker build -t "$tag_base" -f "$tmp_ctx_dir/Dockerfile" "$tmp_ctx_dir"
  fi
}

#!/usr/bin/env bash

# Fallback: attempt to build images from known service subfolders, with discovery
declare -A SERVICE_PATHS
SERVICE_PATHS[
  account
]=apps/account
SERVICE_PATHS[
  front
]=server/front
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

:
IMAGES_FILE="${ROOT_DIR}/.images.conf"
> "$IMAGES_FILE"
:

BUILD_TAG_SUFFIX="${TAG_SUFFIX:-$(date -u +%Y%m%d%H%M%S)}"

for svc in account front collaborator transactor workspace fulltext stats rekoni love aibot; do
  :
  context="$(discover_context_for_service "$svc" || true)"
  if [[ -n "$context" && -f "$context/Dockerfile" ]]; then
    ensure_bundle_if_needed "$context" || {
      echo "Skipping $svc due to missing required bundle."
      :
    continue
    }
    tag_base="${REGISTRY_PREFIX:+${REGISTRY_PREFIX}/}huly/${svc}:local-${BUILD_TAG_SUFFIX}"
    build_service_image "$svc" "$context" "$tag_base"
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
  :
done

echo "Written image overrides to $IMAGES_FILE"
echo "To use with compose: docker compose --env-file .images.conf up -d"
echo -e "${color_yellow}Build completed. Images are ready.${color_reset}"


