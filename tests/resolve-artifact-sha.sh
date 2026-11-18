#!/usr/bin/env bash
# Tests de resolve.sh con gh y docker simulados en el PATH.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../actions/resolve-artifact-sha/resolve.sh"
fails=0

setup() {
  tmp=$(mktemp -d)
  mkdir -p "$tmp/bin"
  export GITHUB_OUTPUT="$tmp/out" REPO="acme/orders-api" SHA="aaaaaaa1111111" REGISTRY_IMAGE=""
  : > "$GITHUB_OUTPUT"
  export PATH="$tmp/bin:$PATH"
}

# gh falso: responde con el JSON de FAKE_PULLS aplicando el --jq real con jq.
fake_gh() {
  cat > "$tmp/bin/gh" <<'SH'
#!/usr/bin/env bash
filter=""
while [[ $# -gt 0 ]]; do [[ "$1" == "--jq" ]] && filter="$2"; shift; done
jq -r "$filter" <<<"$FAKE_PULLS"
SH
  chmod +x "$tmp/bin/gh"
}

fake_docker() {
  printf '#!/usr/bin/env bash\nexit %s\n' "$1" > "$tmp/bin/docker"
  chmod +x "$tmp/bin/docker"
}

expect() {
  local name="$1" key="$2" want="$3" got
  got=$(grep "^${key}=" "$GITHUB_OUTPUT" | cut -d= -f2-)
  if [[ "$got" == "$want" ]]; then echo "ok   - $name"; else echo "FAIL - $name: $key='$got', esperaba '$want'"; fails=$((fails + 1)); fi
}

# 1. Commit de un PR mergeado: usa el head sha del PR.
setup; fake_gh
export FAKE_PULLS='[{"number":42,"merged_at":"2024-05-01T10:00:00Z","head":{"sha":"bbbbbbb2222222"}}]'
bash "$script" 2>/dev/null
expect "PR mergeado -> head sha" artifact-sha bbbbbbb2222222
expect "PR mergeado -> número" pr-number 42

# 2. Varios PRs: el último mergeado gana; los abiertos se ignoran.
setup; fake_gh
export FAKE_PULLS='[{"number":10,"merged_at":"2024-05-01T10:00:00Z","head":{"sha":"old"}},{"number":11,"merged_at":null,"head":{"sha":"open"}},{"number":12,"merged_at":"2024-06-01T10:00:00Z","head":{"sha":"new"}}]'
bash "$script" 2>/dev/null
expect "varios PRs -> último mergeado" pr-number 12
expect "varios PRs -> su head sha" artifact-sha new

# 3. Push directo sin PR: cae al sha del push.
setup; fake_gh
export FAKE_PULLS='[]'
bash "$script" 2>/dev/null
expect "sin PR -> sha del push" artifact-sha aaaaaaa1111111
expect "sin PR -> pr vacío" pr-number ""

# 4. La imagen existe en el registry.
setup; fake_gh; fake_docker 0
export FAKE_PULLS='[{"number":7,"merged_at":"2024-05-01T10:00:00Z","head":{"sha":"ccc"}}]' REGISTRY_IMAGE="registry.example.com/apps/api"
bash "$script" 2>/dev/null
expect "imagen existente" image registry.example.com/apps/api:ccc

# 5. La imagen no existe: tiene que fallar.
setup; fake_gh; fake_docker 1
export FAKE_PULLS='[{"number":7,"merged_at":"2024-05-01T10:00:00Z","head":{"sha":"ccc"}}]' REGISTRY_IMAGE="registry.example.com/apps/api"
if bash "$script" >/dev/null 2>&1; then echo "FAIL - imagen faltante debería fallar"; fails=$((fails + 1)); else echo "ok   - imagen faltante falla"; fi

echo
if [[ $fails -eq 0 ]]; then
  echo "todos los tests pasaron"
else
  echo "$fails test(s) fallaron"
  exit 1
fi
