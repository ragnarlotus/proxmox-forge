#!/bin/bash
# Description: Read-only application-version probes for positively identified
# Community Scripts updaters. No version cache, downloads, or updater execution.

FORGE_APP_SLUG=""
FORGE_APP_BEFORE="-"
FORGE_APP_AFTER="-"
FORGE_APP_FINISHED=false

forge_app_detect_slug() {
  local vmid="$1" updater="$2" script matches
  [[ "$vmid" =~ ^[0-9]+$ && "$updater" == /usr/bin/update ]] || return 1

  # Inspect, never execute, the installed Community Scripts update launcher.
  script="$(pct exec "$vmid" -- head -c 8192 /usr/bin/update </dev/null 2>/dev/null)" || return 1
  # Current generated launchers use variables instead of an expanded ct/*.sh
  # URL. Validate the generated identity and its official source without
  # sourcing or executing the launcher (which would perform an update).
  if grep -Fxq '# Community-Scripts update entrypoint (generated - do not edit by hand).' <<< "$script"; then
    local slug_line name_line slug name
    [[ "$(grep -c '^export SCRIPT_SLUG=' <<< "$script")" == 1 ]] || return 1
    [[ "$(grep -c '^export UPDATE_SCRIPT_NAME=' <<< "$script")" == 1 ]] || return 1
    [[ "$(grep -c '^export COMMUNITY_SCRIPTS_URL=' <<< "$script")" == 1 ]] || return 1
    [[ "$(grep -Fxc 'export COMMUNITY_SCRIPTS_URL="https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main"' <<< "$script")" == 1 ]] || return 1
    [[ "$script" == *'${COMMUNITY_SCRIPTS_URL}/ct/${UPDATE_SCRIPT_NAME}.sh'* ]] || return 1

    slug_line="$(grep -E '^export SCRIPT_SLUG="[a-z0-9_-]+"
    grep -Eo 'https?://(raw\.githubusercontent\.com/(community-scripts/ProxmoxVE|tteck/Proxmox)/((refs/heads/)?main)|github\.com/(community-scripts/ProxmoxVE|tteck/Proxmox)/raw/main)/ct/[a-z0-9_-]+\.sh' |
    sed -E 's@^.*/ct/([a-z0-9_-]+)\.sh$@\1@' | LC_ALL=C sort -u)" || return 1
  [[ -n "$matches" && "$matches" != *$'\n'* ]] || return 1
  printf '%s\n' "$matches"
}

forge_app_probe() {
  local vmid="$1" slug="$2" output state version
  [[ "$vmid" =~ ^[0-9]+$ ]] || return 1
  case "$slug" in
    plex)             output="$(pct exec "$vmid" -- dpkg-query -W '-f=${db:Status-Abbrev}\t${Version}\n' plexmediaserver </dev/null 2>/dev/null)" || return 1 ;;
    audiobookshelf)   output="$(pct exec "$vmid" -- dpkg-query -W '-f=${db:Status-Abbrev}\t${Version}\n' audiobookshelf </dev/null 2>/dev/null)" || return 1 ;;
    caddy)            output="$(pct exec "$vmid" -- caddy version </dev/null 2>/dev/null)" || return 1 ;;
    pihole)           output="$(pct exec "$vmid" -- pihole -v </dev/null 2>/dev/null)" || return 1 ;;
    vaultwarden)      output="$(pct exec "$vmid" -- /opt/vaultwarden/bin/vaultwarden --version </dev/null 2>/dev/null)" ||
                        output="$(pct exec "$vmid" -- /usr/bin/vaultwarden --version </dev/null 2>/dev/null)" || return 1 ;;
    docmost)          output="$(pct exec "$vmid" -- node -p "require('/opt/docmost/apps/server/package.json').version" </dev/null 2>/dev/null)" || return 1 ;;
    immich)           output="$(pct exec "$vmid" -- node -p "require('/opt/immich/app/package.json').version" </dev/null 2>/dev/null)" || return 1 ;;
    *) return 1 ;;
  esac
  case "$slug" in
    plex|audiobookshelf)
      [[ "$output" == *$'\t'* && "$output" != *$'\n'* ]] || return 1
      state="${output%%$'\t'*}"
      version="${output#*$'\t'}"
      [[ "$state" == ii* ]] || return 1
      ;;
    caddy)
      [[ "$output" =~ ^(v[0-9][A-Za-z0-9._+~-]*)([[:space:]]|$) ]] || return 1
      version="${BASH_REMATCH[1]}"
      ;;
    pihole)
      [[ "$output" =~ (^|$'\n')Core[[:space:]]version[[:space:]]is[[:space:]](v[0-9][A-Za-z0-9._+~-]*) ]] || return 1
      version="${BASH_REMATCH[2]}"
      ;;
    vaultwarden)
      [[ "$output" =~ ^vaultwarden[[:space:]]+(v?[0-9][A-Za-z0-9._+~-]*)[[:space:]]*$ ]] || return 1
      version="${BASH_REMATCH[1]}"
      ;;
    docmost|immich)
      [[ "$output" != *$'\n'* ]] || return 1
      version="$output"
      ;;
  esac
  [[ "$version" =~ ^v?[0-9][A-Za-z0-9._+~:-]*$ ]] || return 1
  printf '%s\n' "$version"
}

forge_app_begin() {
  local vmid="$1" updater="$2" slug version
  FORGE_APP_SLUG=""
  FORGE_APP_BEFORE="-"
  FORGE_APP_AFTER="-"
  FORGE_APP_FINISHED=false
  slug="$(forge_app_detect_slug "$vmid" "$updater")" || return 0
  FORGE_APP_SLUG="$slug"
  version="$(forge_app_probe "$vmid" "$slug")" || return 0
  FORGE_APP_BEFORE="$version"
}

forge_app_finalize() {
  local vmid="$1" version
  [[ "$FORGE_APP_FINISHED" != true ]] || return 0
  FORGE_APP_FINISHED=true
  if [[ -n "$FORGE_APP_SLUG" ]]; then
    version="$(forge_app_probe "$vmid" "$FORGE_APP_SLUG")" || version=""
    if [[ -n "$version" ]]; then
      FORGE_APP_AFTER="$version"
    fi
  fi
  # Only compare versions when both observations are verified.
  if [[ "$FORGE_APP_BEFORE" == "-" || "$FORGE_APP_AFTER" == "-" ]]; then
    FORGE_APP_BEFORE="-"
    FORGE_APP_AFTER="-"
  fi
  if [[ "${FORGE_RESULTS_AGGREGATE:-}" == bulk && -n "${FORGE_APP_RESULT_FILE:-}" ]]; then
    printf '%s\t%s\n' "$FORGE_APP_BEFORE" "$FORGE_APP_AFTER" > "$FORGE_APP_RESULT_FILE" ||
      printf 'WARNING: could not transfer application versions to bulk summary\n' >&2
  fi
}
 <<< "$script")" || return 1
    name_line="$(grep -E '^export UPDATE_SCRIPT_NAME="[a-z0-9_-]+"
    grep -Eo 'https?://(raw\.githubusercontent\.com/(community-scripts/ProxmoxVE|tteck/Proxmox)/((refs/heads/)?main)|github\.com/(community-scripts/ProxmoxVE|tteck/Proxmox)/raw/main)/ct/[a-z0-9_-]+\.sh' |
    sed -E 's@^.*/ct/([a-z0-9_-]+)\.sh$@\1@' | LC_ALL=C sort -u)" || return 1
  [[ -n "$matches" && "$matches" != *$'\n'* ]] || return 1
  printf '%s\n' "$matches"
}

forge_app_probe() {
  local vmid="$1" slug="$2" output state version
  [[ "$vmid" =~ ^[0-9]+$ ]] || return 1
  case "$slug" in
    plex)             output="$(pct exec "$vmid" -- dpkg-query -W '-f=${db:Status-Abbrev}\t${Version}\n' plexmediaserver </dev/null 2>/dev/null)" || return 1 ;;
    audiobookshelf)   output="$(pct exec "$vmid" -- dpkg-query -W '-f=${db:Status-Abbrev}\t${Version}\n' audiobookshelf </dev/null 2>/dev/null)" || return 1 ;;
    caddy)            output="$(pct exec "$vmid" -- caddy version </dev/null 2>/dev/null)" || return 1 ;;
    pihole)           output="$(pct exec "$vmid" -- pihole -v </dev/null 2>/dev/null)" || return 1 ;;
    vaultwarden)      output="$(pct exec "$vmid" -- /opt/vaultwarden/bin/vaultwarden --version </dev/null 2>/dev/null)" ||
                        output="$(pct exec "$vmid" -- /usr/bin/vaultwarden --version </dev/null 2>/dev/null)" || return 1 ;;
    docmost)          output="$(pct exec "$vmid" -- node -p "require('/opt/docmost/apps/server/package.json').version" </dev/null 2>/dev/null)" || return 1 ;;
    immich)           output="$(pct exec "$vmid" -- node -p "require('/opt/immich/app/package.json').version" </dev/null 2>/dev/null)" || return 1 ;;
    *) return 1 ;;
  esac
  case "$slug" in
    plex|audiobookshelf)
      [[ "$output" == *$'\t'* && "$output" != *$'\n'* ]] || return 1
      state="${output%%$'\t'*}"
      version="${output#*$'\t'}"
      [[ "$state" == ii* ]] || return 1
      ;;
    caddy)
      [[ "$output" =~ ^(v[0-9][A-Za-z0-9._+~-]*)([[:space:]]|$) ]] || return 1
      version="${BASH_REMATCH[1]}"
      ;;
    pihole)
      [[ "$output" =~ (^|$'\n')Core[[:space:]]version[[:space:]]is[[:space:]](v[0-9][A-Za-z0-9._+~-]*) ]] || return 1
      version="${BASH_REMATCH[2]}"
      ;;
    vaultwarden)
      [[ "$output" =~ ^vaultwarden[[:space:]]+(v?[0-9][A-Za-z0-9._+~-]*)[[:space:]]*$ ]] || return 1
      version="${BASH_REMATCH[1]}"
      ;;
    docmost|immich)
      [[ "$output" != *$'\n'* ]] || return 1
      version="$output"
      ;;
  esac
  [[ "$version" =~ ^v?[0-9][A-Za-z0-9._+~:-]*$ ]] || return 1
  printf '%s\n' "$version"
}

forge_app_begin() {
  local vmid="$1" updater="$2" slug version
  FORGE_APP_SLUG=""
  FORGE_APP_BEFORE="-"
  FORGE_APP_AFTER="-"
  FORGE_APP_FINISHED=false
  slug="$(forge_app_detect_slug "$vmid" "$updater")" || return 0
  FORGE_APP_SLUG="$slug"
  version="$(forge_app_probe "$vmid" "$slug")" || return 0
  FORGE_APP_BEFORE="$version"
}

forge_app_finalize() {
  local vmid="$1" version
  [[ "$FORGE_APP_FINISHED" != true ]] || return 0
  FORGE_APP_FINISHED=true
  if [[ -n "$FORGE_APP_SLUG" ]]; then
    version="$(forge_app_probe "$vmid" "$FORGE_APP_SLUG")" || version=""
    if [[ -n "$version" ]]; then
      FORGE_APP_AFTER="$version"
    fi
  fi
  # Only compare versions when both observations are verified.
  if [[ "$FORGE_APP_BEFORE" == "-" || "$FORGE_APP_AFTER" == "-" ]]; then
    FORGE_APP_BEFORE="-"
    FORGE_APP_AFTER="-"
  fi
  if [[ "${FORGE_RESULTS_AGGREGATE:-}" == bulk && -n "${FORGE_APP_RESULT_FILE:-}" ]]; then
    printf '%s\t%s\n' "$FORGE_APP_BEFORE" "$FORGE_APP_AFTER" > "$FORGE_APP_RESULT_FILE" ||
      printf 'WARNING: could not transfer application versions to bulk summary\n' >&2
  fi
}
 <<< "$script")" || return 1
    slug="${slug_line#export SCRIPT_SLUG=\"}"
    slug="${slug%\"}"
    name="${name_line#export UPDATE_SCRIPT_NAME=\"}"
    name="${name%\"}"
    [[ "$slug" == "$name" ]] || return 1
    printf '%s\n' "$slug"
    return 0
  fi

  matches="$(printf '%s\n' "$script" |
    grep -Eo 'https?://(raw\.githubusercontent\.com/(community-scripts/ProxmoxVE|tteck/Proxmox)/((refs/heads/)?main)|github\.com/(community-scripts/ProxmoxVE|tteck/Proxmox)/raw/main)/ct/[a-z0-9_-]+\.sh' |
    sed -E 's@^.*/ct/([a-z0-9_-]+)\.sh$@\1@' | LC_ALL=C sort -u)" || return 1
  [[ -n "$matches" && "$matches" != *$'\n'* ]] || return 1
  printf '%s\n' "$matches"
}

forge_app_probe() {
  local vmid="$1" slug="$2" output state version
  [[ "$vmid" =~ ^[0-9]+$ ]] || return 1
  case "$slug" in
    plex)             output="$(pct exec "$vmid" -- dpkg-query -W '-f=${db:Status-Abbrev}\t${Version}\n' plexmediaserver </dev/null 2>/dev/null)" || return 1 ;;
    audiobookshelf)   output="$(pct exec "$vmid" -- dpkg-query -W '-f=${db:Status-Abbrev}\t${Version}\n' audiobookshelf </dev/null 2>/dev/null)" || return 1 ;;
    caddy)            output="$(pct exec "$vmid" -- caddy version </dev/null 2>/dev/null)" || return 1 ;;
    pihole)           output="$(pct exec "$vmid" -- pihole -v </dev/null 2>/dev/null)" || return 1 ;;
    vaultwarden)      output="$(pct exec "$vmid" -- /opt/vaultwarden/bin/vaultwarden --version </dev/null 2>/dev/null)" ||
                        output="$(pct exec "$vmid" -- /usr/bin/vaultwarden --version </dev/null 2>/dev/null)" || return 1 ;;
    docmost)          output="$(pct exec "$vmid" -- node -p "require('/opt/docmost/apps/server/package.json').version" </dev/null 2>/dev/null)" || return 1 ;;
    immich)           output="$(pct exec "$vmid" -- node -p "require('/opt/immich/app/package.json').version" </dev/null 2>/dev/null)" || return 1 ;;
    *) return 1 ;;
  esac
  case "$slug" in
    plex|audiobookshelf)
      [[ "$output" == *$'\t'* && "$output" != *$'\n'* ]] || return 1
      state="${output%%$'\t'*}"
      version="${output#*$'\t'}"
      [[ "$state" == ii* ]] || return 1
      ;;
    caddy)
      [[ "$output" =~ ^(v[0-9][A-Za-z0-9._+~-]*)([[:space:]]|$) ]] || return 1
      version="${BASH_REMATCH[1]}"
      ;;
    pihole)
      [[ "$output" =~ (^|$'\n')Core[[:space:]]version[[:space:]]is[[:space:]](v[0-9][A-Za-z0-9._+~-]*) ]] || return 1
      version="${BASH_REMATCH[2]}"
      ;;
    vaultwarden)
      [[ "$output" =~ ^vaultwarden[[:space:]]+(v?[0-9][A-Za-z0-9._+~-]*)[[:space:]]*$ ]] || return 1
      version="${BASH_REMATCH[1]}"
      ;;
    docmost|immich)
      [[ "$output" != *$'\n'* ]] || return 1
      version="$output"
      ;;
  esac
  [[ "$version" =~ ^v?[0-9][A-Za-z0-9._+~:-]*$ ]] || return 1
  printf '%s\n' "$version"
}

forge_app_begin() {
  local vmid="$1" updater="$2" slug version
  FORGE_APP_SLUG=""
  FORGE_APP_BEFORE="-"
  FORGE_APP_AFTER="-"
  FORGE_APP_FINISHED=false
  slug="$(forge_app_detect_slug "$vmid" "$updater")" || return 0
  FORGE_APP_SLUG="$slug"
  version="$(forge_app_probe "$vmid" "$slug")" || return 0
  FORGE_APP_BEFORE="$version"
}

forge_app_finalize() {
  local vmid="$1" version
  [[ "$FORGE_APP_FINISHED" != true ]] || return 0
  FORGE_APP_FINISHED=true
  if [[ -n "$FORGE_APP_SLUG" ]]; then
    version="$(forge_app_probe "$vmid" "$FORGE_APP_SLUG")" || version=""
    if [[ -n "$version" ]]; then
      FORGE_APP_AFTER="$version"
    fi
  fi
  # Only compare versions when both observations are verified.
  if [[ "$FORGE_APP_BEFORE" == "-" || "$FORGE_APP_AFTER" == "-" ]]; then
    FORGE_APP_BEFORE="-"
    FORGE_APP_AFTER="-"
  fi
  if [[ "${FORGE_RESULTS_AGGREGATE:-}" == bulk && -n "${FORGE_APP_RESULT_FILE:-}" ]]; then
    printf '%s\t%s\n' "$FORGE_APP_BEFORE" "$FORGE_APP_AFTER" > "$FORGE_APP_RESULT_FILE" ||
      printf 'WARNING: could not transfer application versions to bulk summary\n' >&2
  fi
}
