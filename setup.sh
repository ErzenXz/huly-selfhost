#!/usr/bin/env bash

HULY_VERSION="v0.6.502"
DOCKER_NAME="huly"
CONFIG_FILE="huly.conf"

# Parse command line arguments
RESET_VOLUMES=false
SECRET=false
BUILD_REPO=""
BUILD_PATH=""
BUILD_REF=""
BUILD_REGISTRY_PREFIX=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --secret)
            SECRET=true
            shift
            ;;
        --reset-volumes)
            RESET_VOLUMES=true
            shift
            ;;
        --build-from-repo=*)
            BUILD_REPO="${1#*=}"
            shift
            ;;
        --build-from-repo)
            BUILD_REPO="$2"
            shift 2
            ;;
        --build-from-path=*)
            BUILD_PATH="${1#*=}"
            shift
            ;;
        --build-from-path)
            BUILD_PATH="$2"
            shift 2
            ;;
        --build-ref=*)
            BUILD_REF="${1#*=}"
            shift
            ;;
        --build-ref)
            BUILD_REF="$2"
            shift 2
            ;;
        --build-registry=*)
            BUILD_REGISTRY_PREFIX="${1#*=}"
            shift
            ;;
        --build-registry)
            BUILD_REGISTRY_PREFIX="$2"
            shift 2
            ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo "Options:"
            echo "  --secret                    Generate a new secret key"
            echo "  --reset-volumes             Reset all volume paths to default Docker named volumes"
            echo "  --build-from-repo <URL>     Clone and build images from repository"
            echo "  --build-from-path <DIR>     Use local path to build images"
            echo "  --build-ref <REF>           Git ref (branch/tag/commit) when using --build-from-repo"
            echo "  --build-registry <PREFIX>   Optional registry/user prefix for built images"
            echo "  --help                      Show this help message"
            exit 0
            ;;
        *)
            # Heuristics: allow split URLs across lines (e.g., "https://github.com/org" "\/repo")
            if [[ -z "$BUILD_REPO" && "$1" =~ ^https?:// ]]; then
                if [[ $# -ge 2 && "$2" == /* ]]; then
                    BUILD_REPO="$1$2"
                    shift 2
                else
                    BUILD_REPO="$1"
                    shift
                fi
                ;;
            elif [[ -n "$BUILD_REPO" && "$BUILD_REPO" =~ ^https?://[^/]+$ && "$1" == /* ]]; then
                BUILD_REPO="$BUILD_REPO$1"
                shift
                ;;
            elif [[ -z "$BUILD_PATH" && -d "$1" ]]; then
                BUILD_PATH="$1"
                shift
                ;;
            else
                echo "Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
            fi
            ;;
    esac
done

if [ "$RESET_VOLUMES" == true ]; then
    echo -e "\033[33m--reset-volumes flag detected: Resetting all volume paths to default Docker named volumes.\033[0m"
    sed -i \
        -e '/^VOLUME_DB_PATH=/s|=.*|=|' \
        -e '/^VOLUME_ELASTIC_PATH=/s|=.*|=|' \
        -e '/^VOLUME_FILES_PATH=/s|=.*|=|' \
        "$CONFIG_FILE"
    exit 0
fi

if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

# If user requested to build images from source, run the builder
if [[ -n "$BUILD_REPO" || -n "$BUILD_PATH" ]]; then
    echo -e "\n\033[1;34mBuilding images from source...\033[0m"
    BUILD_ARGS=()
    if [[ -n "$BUILD_REPO" ]]; then
        BUILD_ARGS+=("--repo" "$BUILD_REPO")
    fi
    if [[ -n "$BUILD_PATH" ]]; then
        BUILD_ARGS+=("--path" "$BUILD_PATH")
    fi
    if [[ -n "$BUILD_REF" ]]; then
        BUILD_ARGS+=("--ref" "$BUILD_REF")
    fi
    if [[ -n "$BUILD_REGISTRY_PREFIX" ]]; then
        BUILD_ARGS+=("--registry" "$BUILD_REGISTRY_PREFIX")
    fi
    bash scripts/build-from-source.sh "${BUILD_ARGS[@]}"
    if [[ -f .images.conf ]]; then
        echo "Loading built image overrides from .images.conf"
        set -a
        source ./.images.conf
        set +a
    else
        echo "Warning: .images.conf not found after build; proceeding with default images"
    fi
fi

while true; do
    if [[ -n "$HOST_ADDRESS" ]]; then
        prompt_type="current"
        prompt_value="${HOST_ADDRESS}"
    else
        prompt_type="default"
        prompt_value="localhost"
    fi
    read -p "Enter the host address (domain name or IP) [${prompt_type}: ${prompt_value}]: " input
    _HOST_ADDRESS="${input:-${HOST_ADDRESS:-localhost}}"
    break
done

while true; do
    if [[ -n "$HTTP_PORT" ]]; then
        prompt_type="current"
        prompt_value="${HTTP_PORT}"
    else
        prompt_type="default"
        prompt_value="80"
    fi
    read -p "Enter the port for HTTP [${prompt_type}: ${prompt_value}]: " input
    _HTTP_PORT="${input:-${HTTP_PORT:-80}}"
    if [[ "$_HTTP_PORT" =~ ^[0-9]+$ && "$_HTTP_PORT" -ge 1 && "$_HTTP_PORT" -le 65535 ]]; then
        break
    else
        echo "Invalid port. Please enter a number between 1 and 65535."
    fi
done

echo "$_HOST_ADDRESS $HOST_ADDRESS $_HTTP_PORT $HTTP_PORT"

if [[ "$_HOST_ADDRESS" == "localhost" || "$_HOST_ADDRESS" == "127.0.0.1" || "$_HOST_ADDRESS" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}:?$ ]]; then
    _HOST_ADDRESS="${_HOST_ADDRESS%:}:${_HTTP_PORT}"
    SECURE=""
else
    while true; do
        if [[ -n "$SECURE" ]]; then
            prompt_type="current"
            prompt_value="Yes"
        else
            prompt_type="default"
            prompt_value="No"
        fi
        read -p "Will you serve Huly over SSL? (y/n) [${prompt_type}: ${prompt_value}]: " input
        case "${input}" in
            [Yy]* )
                _SECURE="true"; break;;
            [Nn]* )
                _SECURE=""; break;;
            "" )
                _SECURE="${SECURE:+true}"; break;;
            * )
                echo "Invalid input. Please enter Y or N.";;
        esac
    done
fi

# Volume path configuration
echo -e "\n\033[1;34mDocker Volume Configuration:\033[0m"

    echo "You can specify custom paths for persistent data storage, or leave empty to use default Docker named volumes."
    echo -e "\033[33mTip: To revert from custom paths to default volumes, enter 'default' or just press Enter when prompted.\033[0m"

    # Database volume configuration
    if [[ -n "$VOLUME_DB_PATH" ]]; then
        current_db="custom: $VOLUME_DB_PATH"
    else
        current_db="default Docker volume"
    fi
    read -p "Enter custom path for database volume [current: ${current_db}]: " input
    if [[ "$input" == "default" ]]; then
        _VOLUME_DB_PATH=""
    else
        _VOLUME_DB_PATH="${input:-${VOLUME_DB_PATH}}"
    fi

    # Elasticsearch volume configuration
    if [[ -n "$VOLUME_ELASTIC_PATH" ]]; then
        current_elastic="custom: $VOLUME_ELASTIC_PATH"
    else
        current_elastic="default Docker volume"
    fi
    read -p "Enter custom path for Elasticsearch volume [current: ${current_elastic}]: " input
    if [[ "$input" == "default" ]]; then
        _VOLUME_ELASTIC_PATH=""
    else
        _VOLUME_ELASTIC_PATH="${input:-${VOLUME_ELASTIC_PATH}}"
    fi

    # Files volume configuration
    if [[ -n "$VOLUME_FILES_PATH" ]]; then
        current_files="custom: $VOLUME_FILES_PATH"
    else
        current_files="default Docker volume"
    fi
    read -p "Enter custom path for files volume [current: ${current_files}]: " input
    if [[ "$input" == "default" ]]; then
        _VOLUME_FILES_PATH=""
    else
        _VOLUME_FILES_PATH="${input:-${VOLUME_FILES_PATH}}"
    fi

if [ ! -f .huly.secret ] || [ "$SECRET" == true ]; then
  openssl rand -hex 32 > .huly.secret
  echo "Secret generated and stored in .huly.secret"
else
  echo -e "\033[33m.huly.secret already exists, not overwriting."
  echo "Run this script with --secret to generate a new secret."
fi

export HOST_ADDRESS=$_HOST_ADDRESS
export SECURE=$_SECURE
export HTTP_PORT=$_HTTP_PORT
export HTTP_BIND=$HTTP_BIND
export TITLE=${TITLE:-Huly}
export DEFAULT_LANGUAGE=${DEFAULT_LANGUAGE:-en}
export LAST_NAME_FIRST=${LAST_NAME_FIRST:-true}
export VOLUME_DB_PATH=$_VOLUME_DB_PATH
export VOLUME_ELASTIC_PATH=$_VOLUME_ELASTIC_PATH
export VOLUME_FILES_PATH=$_VOLUME_FILES_PATH
export HULY_SECRET=$(cat .huly.secret)

# Optional services configuration prompts
echo -e "\n\033[1;34mOptional services configuration:\033[0m"

read -p "Enable AI Bot service? (y/N): " _ENABLE_AIBOT
if [[ "${_ENABLE_AIBOT,,}" == "y" ]]; then
  read -p "OPENAI_API_KEY (leave empty to set later): " _OPENAI_API_KEY
  read -p "OPENAI_BASE_URL (optional): " _OPENAI_BASE_URL
  read -p "AI Bot password (for service account): " _AI_BOT_PASSWORD
  export OPENAI_API_KEY="${_OPENAI_API_KEY}"
  export OPENAI_BASE_URL="${_OPENAI_BASE_URL}"
  export AI_BOT_PASSWORD="${_AI_BOT_PASSWORD}"
  export AI_URL="http${_SECURE:+s}://${_HOST_ADDRESS}/aibot"
  export AI_BOT_URL="http://aibot:4010"
fi

read -p "Enable Love (LiveKit) service? (y/N): " _ENABLE_LOVE
if [[ "${_ENABLE_LOVE,,}" == "y" ]]; then
  read -p "LIVEKIT_HOST (e.g., wss://your.livekit.host): " _LIVEKIT_HOST
  read -p "LIVEKIT_API_KEY: " _LIVEKIT_API_KEY
  read -p "LIVEKIT_API_SECRET: " _LIVEKIT_API_SECRET
  export LIVEKIT_HOST="${_LIVEKIT_HOST}"
  export LIVEKIT_API_KEY="${_LIVEKIT_API_KEY}"
  export LIVEKIT_API_SECRET="${_LIVEKIT_API_SECRET}"
fi

envsubst < .template.huly.conf > $CONFIG_FILE

echo -e "\n\033[1;34mConfiguration Summary:\033[0m"
echo -e "Host Address: \033[1;32m$_HOST_ADDRESS\033[0m"
echo -e "HTTP Port: \033[1;32m$_HTTP_PORT\033[0m"
if [[ -n "$SECURE" ]]; then
    echo -e "SSL Enabled: \033[1;32mYes\033[0m"
else
    echo -e "SSL Enabled: \033[1;31mNo\033[0m"
fi
echo -e "Database Volume: \033[1;32m${_VOLUME_DB_PATH:-Docker named volume}\033[0m"
echo -e "Elasticsearch Volume: \033[1;32m${_VOLUME_ELASTIC_PATH:-Docker named volume}\033[0m"
echo -e "Files Volume: \033[1;32m${_VOLUME_FILES_PATH:-Docker named volume}\033[0m"

read -p "Do you want to run 'docker compose up -d' now to start Huly? (Y/n): " RUN_DOCKER
case "${RUN_DOCKER:-Y}" in
    [Yy]* )
         echo -e "\033[1;32mRunning 'docker compose up -d' now...\033[0m"
         if [[ -f .images.conf ]]; then
           docker compose --env-file .images.conf up -d
         else
           docker compose up -d
         fi
         ;;
    [Nn]* )
        echo "You can run 'docker compose up -d' later to start Huly."
        ;;
esac

echo -e "\033[1;32mSetup is complete!\n Generating nginx.conf...\033[0m"
./nginx.sh
