#!/bin/bash
# Description: Resolves the local absolute filesystem path of one configured Proxmox backup storage from the live storage configuration.

set -u

[[ -r "${FORGE_RUNTIME_GUARD:-}" ]] || {
  printf 'ERROR: this Forge component is internal; run it through the forge CLI\n' >&2
  exit 1
}
bash "$FORGE_RUNTIME_GUARD" || exit 1

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ $# -eq 1 ]] || fail "usage: storage-path.sh STORAGE"
storage="$1"
[[ "$storage" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail "invalid storage identifier '$storage'"

command -v pvesm >/dev/null 2>&1 || fail "pvesm is not available"
[[ -r /etc/pve/storage.cfg ]] || fail "/etc/pve/storage.cfg is not readable"

pvesm status --storage "$storage" >/dev/null 2>&1 || fail "Proxmox storage is not currently available: $storage"

active=false
path=""
content=""

while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ "$line" =~ ^[^[:space:]][^:]*:[[:space:]]+([^[:space:]#]+) ]]; then
    [[ "$active" == true ]] && break

    if [[ "${BASH_REMATCH[1]}" == "$storage" ]]; then
      active=true
    else
      active=false
    fi
    continue
  fi

  [[ "$active" == true ]] || continue

  if [[ "$line" =~ ^[[:space:]]+path[[:space:]]+(.+[^[:space:]])[[:space:]]*$ ]]; then
    path="${BASH_REMATCH[1]}"
    continue
  fi

  if [[ "$line" =~ ^[[:space:]]+content[[:space:]]+(.+[^[:space:]])[[:space:]]*$ ]]; then
    content="${BASH_REMATCH[1]}"
  fi
done < /etc/pve/storage.cfg

[[ -n "$path" ]] || fail "storage $storage has no explicit local path"

allows_backup=false
IFS=',' read -r -a content_types <<<"$content"
for content_type in "${content_types[@]}"; do
  content_type="${content_type//[[:space:]]/}"
  if [[ "$content_type" == backup ]]; then
    allows_backup=true
    break
  fi
done

[[ "$allows_backup" == true ]] || fail "storage $storage does not allow backup content"
[[ "$path" == /* ]] || fail "storage $storage returned a non-absolute path"
[[ -d "$path" ]] || fail "storage path does not exist: $path"

printf '%s\n' "$path"
