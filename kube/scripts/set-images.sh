#!/usr/bin/env bash

set -euo pipefail

# Usage:
#  kube/scripts/set-images.sh [--env-file .images.conf] [--namespace default]
#
# Applies image overrides from env file to Kubernetes deployments.

ENV_FILE=""
NAMESPACE="default"

for arg in "$@"; do
  case $arg in
    --env-file=*) ENV_FILE="${arg#*=}" ;;
    --env-file) shift; ENV_FILE="$1"; shift ;;
    --namespace=*) NAMESPACE="${arg#*=}" ;;
    --namespace) shift; NAMESPACE="$1"; shift ;;
    --help) echo "Usage: $0 [--env-file FILE] [--namespace NS]"; exit 0 ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done

if [[ -n "$ENV_FILE" ]]; then
  set -a
  source "$ENV_FILE"
  set +a
elif [[ -f ./.images.conf ]]; then
  set -a
  source ./.images.conf
  set +a
fi

declare -A DEPLOYMENTS
DEPLOYMENTS[front]="${IMAGE_FRONT:-}"
DEPLOYMENTS[account]="${IMAGE_ACCOUNT:-}"
DEPLOYMENTS[transactor]="${IMAGE_TRANSACTOR:-}"
DEPLOYMENTS[workspace]="${IMAGE_WORKSPACE:-}"
DEPLOYMENTS[fulltext]="${IMAGE_FULLTEXT:-}"
DEPLOYMENTS[stats]="${IMAGE_STATS:-}"
DEPLOYMENTS[collaborator]="${IMAGE_COLLABORATOR:-}"
DEPLOYMENTS[rekoni]="${IMAGE_REKONI:-}"

for name in "${!DEPLOYMENTS[@]}"; do
  image="${DEPLOYMENTS[$name]}"
  if [[ -n "$image" ]]; then
    echo "Setting image for deployment/$name to $image in namespace $NAMESPACE"
    kubectl -n "$NAMESPACE" set image deployment/"$name" "$name"="$image"
  else
    echo "No override for $name; skipping"
  fi
done

echo "Done."


