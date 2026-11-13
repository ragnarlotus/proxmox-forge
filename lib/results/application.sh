#!/bin/bash
# Description: Read-only application-version probes for positively identified
# Community Scripts updaters. No version cache, downloads, or updater execution.

FORGE_APP_SLUG=""
FORGE_APP_REPOSITORY="-"
FORGE_APP_BEFORE="-"
FORGE_APP_AFTER="-"
FORGE_APP_FINISHED=false

forge_app_detect_slug() {
  local vmid="$1" updater="$2" script matches
  [[ "$vmid" =~ ^[0-9]+$ && "$updater" == /usr/bin/update ]] || return 1

  # Inspect, never execute, the installed Community Scripts update launcher.
  script="$(pct exec "$vmid" -- head -c 8192 /usr/bin/update </dev/null 200>&- 2>/dev/null)" || return 1
  # Current generated launchers use variables rather than an expanded ct/*.sh
  # URL. Never source or execute a launcher to learn its application identity.
  if grep -Fxq '# Community-Scripts update entrypoint (generated - do not edit by hand).' <<< "$script"; then
    local slug_line name_line slug name
    [[ "$(grep -c '^export SCRIPT_SLUG=' <<< "$script")" == 1 ]] || return 1
    [[ "$(grep -c '^export UPDATE_SCRIPT_NAME=' <<< "$script")" == 1 ]] || return 1
    [[ "$(grep -c '^export COMMUNITY_SCRIPTS_URL=' <<< "$script")" == 1 ]] || return 1
    [[ "$(grep -Fxc 'export COMMUNITY_SCRIPTS_URL="https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main"' <<< "$script")" == 1 ]] || return 1
    [[ "$script" == *'${COMMUNITY_SCRIPTS_URL}/ct/${UPDATE_SCRIPT_NAME}.sh'* ]] || return 1

    slug_line="$(grep -E '^export SCRIPT_SLUG="[a-z0-9_-]+"$' <<< "$script")" || return 1
    name_line="$(grep -E '^export UPDATE_SCRIPT_NAME="[a-z0-9_-]+"$' <<< "$script")" || return 1
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

# Retrieve application URLs from the official Community Scripts definition,
# never from a hardcoded slug-to-repository mapping. Do not execute downloaded
# shell code: parse only metadata comments near the beginning of the script.
# This is called only for a verified successful application version change.
forge_app_valid_url() {
  local pattern='^https?://[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]{1,5})?(/[A-Za-z0-9._~/%+?=&#:@,;!-]*)?$'
  [[ "$1" =~ $pattern ]]
}

forge_app_repository() {
  local slug="$1" script line source_url="" github_url="" url
  local source_pattern='^#[[:space:]]*Source:[[:space:]]*(https?://[^[:space:]|]+)'
  local github_pattern='(^|[[:space:]|])Github:[[:space:]]*(https?://[^[:space:]|]+)'
  local line_count=0

  if [[ ! "$slug" =~ ^[a-z0-9_-]+$ ]] || ! command -v curl >/dev/null 2>&1; then
    printf '%s\n' '-'
    return 0
  fi

  script="$(curl --fail --silent --show-error --location \
    --connect-timeout 3 --max-time 8 --max-filesize 1048576 \
    --proto '=https' --proto-redir '=https' \
    "https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/${slug}.sh" \
    2>/dev/null)" || {
    printf '%s\n' '-'
    return 0
  }

  while IFS= read -r line; do
    ((line_count += 1))
    (( line_count <= 40 )) || break
    [[ "$line" == \#* ]] || continue

    if [[ -z "$source_url" && "$line" =~ $source_pattern ]]; then
      source_url="${BASH_REMATCH[1]}"
    fi
    if [[ -z "$github_url" && "$line" =~ $github_pattern ]]; then
      github_url="${BASH_REMATCH[2]}"
    fi
  done <<<"$script"

  # Explicit Github wins when valid. If absent or malformed, use Source.
  # If neither yields a safe HTTP(S) URL, keep the missing-value marker.
  url="-"
  if forge_app_valid_url "$github_url"; then
    url="$github_url"
  elif forge_app_valid_url "$source_url"; then
    url="$source_url"
  fi
  printf '%s\n' "$url"
}

forge_app_probe() {
  local vmid="$1" slug="$2" output state version
  [[ "$vmid" =~ ^[0-9]+$ ]] || return 1
  case "$slug" in
    plex)             output="$(pct exec "$vmid" -- dpkg-query -W '-f=${db:Status-Abbrev}\t${Version}\n' plexmediaserver </dev/null 200>&- 2>/dev/null)" || return 1 ;;
    audiobookshelf)   output="$(pct exec "$vmid" -- dpkg-query -W '-f=${db:Status-Abbrev}\t${Version}\n' audiobookshelf </dev/null 200>&- 2>/dev/null)" || return 1 ;;
    caddy)            output="$(pct exec "$vmid" -- caddy version </dev/null 200>&- 2>/dev/null)" || return 1 ;;
    pihole)           output="$(pct exec "$vmid" -- /usr/local/bin/pihole -v </dev/null 200>&- 2>/dev/null)" || return 1 ;;
    vaultwarden)      output="$(pct exec "$vmid" -- /opt/vaultwarden/bin/vaultwarden --version </dev/null 200>&- 2>/dev/null)" ||
                        output="$(pct exec "$vmid" -- /usr/bin/vaultwarden --version </dev/null 200>&- 2>/dev/null)" || return 1 ;;
    docmost)          output="$(pct exec "$vmid" -- node -p "require('/opt/docmost/apps/server/package.json').version" </dev/null 200>&- 2>/dev/null)" || return 1 ;;
    immich)           output="$(pct exec "$vmid" -- node -p "require('/opt/immich/app/package.json').version" </dev/null 200>&- 2>/dev/null)" || return 1 ;;
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
      # The executable prints its main version on the first line and may
      # follow it with independent Web-Vault information or warnings.
      local first_line
      first_line="${output%%$'\n'*}"
      [[ "$first_line" =~ ^[Vv]aultwarden[[:space:]]+(v?[0-9][A-Za-z0-9._+~-]*)$ ]] || return 1
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

# Community Scripts' check_for_gh_release stores the installed release in
# /root/.<app>. Use the verified launcher slug as the marker name.
# Missing/unparseable files remain unknown. Never execute a script to inspect.
forge_app_marker_version() {
  local vmid="$1" slug="$2" output
  [[ "$vmid" =~ ^[0-9]+$ && "$slug" =~ ^[a-z0-9_-]+$ ]] || return 1
  output="$(pct exec "$vmid" -- cat "/root/.$slug" </dev/null 200>&- 2>/dev/null)" || return 1
  [[ "$output" =~ ^v?[0-9][A-Za-z0-9._+~:-]*$ ]] || return 1
  printf '%s\n' "$output"
}

# For updaters without a marker, require the successful application stage to
# confirm an old/new version AND the exact deployed version. Neither progress
# text nor a failed stage is evidence of the final installed application.
forge_app_log_versions() {
  local log_file="$1" slug="$2" observation old new
  [[ -f "$log_file" && "$slug" =~ ^[a-z0-9_-]+$ ]] || return 1
  observation="$(awk -v slug="$slug" '
    / event=stage_start / {
      active=(index($0," stage=application_update ")>0)
      if (active) { old=""; new=""; deployed=""; succeeded=0 }
      next
    }
    / event=stage_end / {
      if (active && index($0," stage=application_update ")>0) {
        succeeded=(index($0," status=success ")>0)
        active=0
      }
      next
    }
    active {
      if (index($0,"Update available: " slug " ")>0) {
        line=$0
        sub(/^.*Update available: /,"",line)
        count=split(line,part,/ +/)
        if (count>=4 && part[1]==slug && part[3]=="->") {
          old=part[2]; new=part[4]
        }
      }
      if (index($0,"Deployed: " slug " (")>0) {
        line=$0
        sub(/^.*Deployed: /,"",line)
        if (index(line,slug " (")==1) {
          sub(/^[^(]*\(/,"",line)
          sub(/\).*$/,"",line)
          deployed=line
        }
      }
    }
    END {
      if (succeeded && old!="" && new!="" && deployed==new)
        printf "%s|%s\n",old,new
    }
  ' "$log_file")" || return 1
  [[ "$observation" == *"|"* ]] || return 1
  old="${observation%%|*}"
  new="${observation#*|}"
  [[ "$old" =~ ^v?[0-9][A-Za-z0-9._+~:-]*$ && "$new" =~ ^v?[0-9][A-Za-z0-9._+~:-]*$ ]] || return 1
  printf '%s|%s\n' "$old" "$new"
}

forge_app_begin() {
  local vmid="$1" updater="$2" slug version
  FORGE_APP_SLUG=""
  FORGE_APP_REPOSITORY="-"
  FORGE_APP_BEFORE="-"
  FORGE_APP_AFTER="-"
  FORGE_APP_FINISHED=false
  slug="$(forge_app_detect_slug "$vmid" "$updater")" || return 0
  FORGE_APP_SLUG="$slug"
  version="$(forge_app_probe "$vmid" "$slug")" ||
    version="$(forge_app_marker_version "$vmid" "$slug")" || return 0
  FORGE_APP_BEFORE="$version"
}

forge_app_finalize() {
  local vmid="$1" log_file="${2:-}" allow_log_fallback="${3:-false}" version observed old new
  [[ "$FORGE_APP_FINISHED" != true ]] || return 0
  FORGE_APP_FINISHED=true
  if [[ -n "$FORGE_APP_SLUG" ]]; then
    version="$(forge_app_probe "$vmid" "$FORGE_APP_SLUG")" ||
      version="$(forge_app_marker_version "$vmid" "$FORGE_APP_SLUG")" || version=""
    if [[ -n "$version" ]]; then
      FORGE_APP_AFTER="$version"
    fi
  fi
  # Success-only fallback from the updater's explicit deployed-version text.
  # A failed update or rollback must be measured from the restored guest.
  if [[ "$allow_log_fallback" == true && -n "$FORGE_APP_SLUG" && -n "$log_file" ]]; then
    observed="$(forge_app_log_versions "$log_file" "$FORGE_APP_SLUG")" || observed=""
    if [[ -n "$observed" ]]; then
      old="${observed%%|*}"
      new="${observed#*|}"
      if [[ "$FORGE_APP_BEFORE" == "-" || "$FORGE_APP_BEFORE" == "$old" ]]; then
        if [[ "$FORGE_APP_AFTER" == "-" || "$FORGE_APP_AFTER" == "$new" ]]; then
          FORGE_APP_BEFORE="$old"
          FORGE_APP_AFTER="$new"
        fi
      fi
    fi
  fi
  # Only compare versions when both observations are verified.
  if [[ "$FORGE_APP_BEFORE" == "-" || "$FORGE_APP_AFTER" == "-" ]]; then
    FORGE_APP_BEFORE="-"
    FORGE_APP_AFTER="-"
  fi
  # No network request for no-op/unknown/failed or recovered updates.
  if [[ "$allow_log_fallback" == true && -n "$FORGE_APP_SLUG" &&
        "$FORGE_APP_BEFORE" != "-" && "$FORGE_APP_AFTER" != "-" &&
        "$FORGE_APP_BEFORE" != "$FORGE_APP_AFTER" ]]; then
    FORGE_APP_REPOSITORY="$(forge_app_repository "$FORGE_APP_SLUG")"
  fi
  if [[ "${FORGE_RESULTS_AGGREGATE:-}" == bulk && -n "${FORGE_APP_RESULT_FILE:-}" ]]; then
    printf '%s\t%s\t%s\n' "$FORGE_APP_BEFORE" "$FORGE_APP_AFTER" "$FORGE_APP_REPOSITORY" > "$FORGE_APP_RESULT_FILE" ||
      printf 'WARNING: could not transfer application versions to bulk summary\n' >&2
  fi
}
