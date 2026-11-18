#!/usr/bin/env bash
# Resuelve qué imagen desplegar a partir de un push a una rama de ambiente.
#
# Problema: con "squash" o "merge commit", el SHA del push a main NO es el SHA con el
# que el CI del PR construyó y probó la imagen. Reconstruir en el push produce una
# imagen distinta a la que se probó.
#
# Solución: preguntarle a la API qué PR contiene este commit y usar el head SHA de ese
# PR, que es el tag con el que se publicó la imagen.
set -euo pipefail

log() { echo "[resolve-artifact-sha] $*" >&2; }
out() { echo "$1=$2" >> "$GITHUB_OUTPUT"; }

# 1. PR asociado al commit. Si hay varios (cherry-picks), el último mergeado.
pr_json=$(gh api "repos/${REPO}/commits/${SHA}/pulls" \
  -H "Accept: application/vnd.github+json" \
  --jq '[.[] | select(.merged_at != null)] | sort_by(.merged_at) | last // empty')

if [[ -z "$pr_json" ]]; then
  # Push directo sin PR (hotfix de emergencia): la imagen se buscó con el SHA del push.
  log "El commit ${SHA} no viene de un PR mergeado; se usa el SHA del push."
  pr_number=""
  artifact_sha="$SHA"
else
  pr_number=$(jq -r '.number' <<<"$pr_json")
  artifact_sha=$(jq -r '.head.sha' <<<"$pr_json")
  log "Commit ${SHA:0:7} -> PR #${pr_number} -> imagen ${artifact_sha:0:7}"
fi

out pr-number "$pr_number"
out artifact-sha "$artifact_sha"

# 2. Opcional: confirmar que la imagen existe antes de intentar desplegarla.
if [[ -n "$REGISTRY_IMAGE" ]]; then
  image="${REGISTRY_IMAGE}:${artifact_sha}"
  if docker manifest inspect "$image" >/dev/null 2>&1; then
    log "Imagen encontrada: ${image}"
  else
    echo "::error::No existe ${image}. ¿Corrió el CI del PR #${pr_number:-?} hasta el push de la imagen?"
    exit 1
  fi
  out image "$image"
fi
