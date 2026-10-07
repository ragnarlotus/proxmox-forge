#!/bin/bash
# Description: Provides an interactive, selective Proxmox host recovery utility for restoring important configuration from Forge host backups on clean or working systems.

set -u

restore_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || {
  printf 'ERROR: could not determine restore directory\n' >&2
  exit 1
}
forge_lib_dir="$(cd "$restore_script_dir/../.." && pwd)" || {
  printf 'ERROR: could not determine Forge lib directory\n' >&2
  exit 1
}
runtime_guard="$forge_lib_dir/runtime/require-context.sh"

workspace=""
standalone_lock=false
lock_file=""

cleanup_restore_state() {
  [[ -z "$workspace" ]] || rm -rf -- "$workspace"
  if [[ "$standalone_lock" == true && -n "$lock_file" ]]; then
    : > "$lock_file" 2>/dev/null || true
  fi
}
trap cleanup_restore_state EXIT

# This is the only lib/ entry point intentionally allowed to run outside the
# public Forge CLI. It still participates in the same global lock so host
# recovery can never overlap another Forge execution.
if [[ "${FORGE_CONTEXT:-}" == active && -r "${FORGE_RUNTIME_GUARD:-}" ]]; then
  bash "$FORGE_RUNTIME_GUARD" || exit 1
else
  lock_file="/run/lock/proxmox-forge.lock"
  lock_fd=200

  command -v flock >/dev/null 2>&1 || {
    printf 'ERROR: flock is required for Forge runtime locking\n' >&2
    exit 1
  }
  [[ -r "$runtime_guard" ]] || {
    printf 'ERROR: Forge runtime guard is not readable: %s\n' "$runtime_guard" >&2
    exit 1
  }
  [[ -d /run/lock && -w /run/lock ]] || {
    printf 'ERROR: Forge lock directory is not writable: /run/lock\n' >&2
    exit 1
  }

  exec 200<>"$lock_file" || {
    printf 'ERROR: could not open Forge run lock: %s\n' "$lock_file" >&2
    exit 1
  }

  if ! flock -n "$lock_fd"; then
    holder="$(awk -F '\t' '
      $1 == "meta" && ($2 == "pid" || $2 == "run_id" || $2 == "command") {
        if (length(out)) out = out " ";
        out = out $2 "=" $3;
      }
      END { print out }
    ' "$lock_file" 2>/dev/null)"
    if [[ -z "$holder" ]]; then
      holder="$(head -n 1 "$lock_file" 2>/dev/null)"
    fi
    if [[ -n "$holder" ]]; then
      printf 'ERROR: another Forge execution is already running (%s)\n' "$holder" >&2
    else
      printf 'ERROR: another Forge execution is already running\n' >&2
    fi
    exit 1
  fi
  standalone_lock=true

  run_id="$(date '+%Y%m%dT%H%M%S')-$" || {
    printf 'ERROR: could not create Forge restore run identifier\n' >&2
    exit 1
  }
  printf 'meta\tpid\t%s\nmeta\trun_id\t%s\nmeta\tcommand\t%s\n' \
    "$" "$run_id" "host-restore" > "$lock_file" || {
    printf 'ERROR: could not record Forge restore lock metadata\n' >&2
    exit 1
  }

  export FORGE_CONTEXT=active
  export FORGE_RUN_ID="$run_id"
  export FORGE_LOCK_FILE="$lock_file"
  export FORGE_LOCK_FD="$lock_fd"
  export FORGE_RUNTIME_GUARD="$runtime_guard"
fi

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

help() {
  cat <<'HELP'
Forge Proxmox Host Restore

Usage: restore.sh [OPTIONS]

Options:
  -h, --help                 Show this help and exit.
  --backup FILE_OR_PATH      Preselect a backup. Bare names are resolved inside
                             the detected/passed backup directory; absolute paths
                             are used directly.
  --backup-dir DIRECTORY     Directory containing host backups. If omitted, Forge
                             tries the Proxmox backup storage + /pve and otherwise
                             asks for the path.
  --dry-run                  Validate and run the interactive plan without writes.

With no parameters, the script shows the parameter summary and starts the wizard.
Backups are listed newest first with dates in YYYY-MM-DD HH:MM format.

Restore subjects:
   0  ALL standard subjects (excludes Proxmox cluster state)
   1  Proxmox configuration
   2  Network
   3  Storage & mounts
   4  APT repositories & custom configuration
   5  Forge configuration
   6  Custom services & schedules
   7  Host security
   8  System tuning
   9  Local users & authentication
  10  Root SSH & credentials
  11  Root shell & editor configuration
  12  Root application configuration & state
  13  Proxmox cluster state (ADVANCED; config.db recovery)
  14  Local executables (/usr/local/bin)

Notes:
  - Restore is manual/selective, never automatic after update failure, and never
    creates another backup before restoring.
  - Network and local authentication require explicit confirmation.
  - Granular Proxmox restore excludes pmxcfs private identity/secrets. Full pmxcfs
    recovery uses subject 13 instead and supersedes subject 1.
  - Cluster-state recovery is for a lost-node recovery scenario. Forge refuses it
    while guests are running or on a detected multi-node cluster, stops pve-cluster,
    replaces config.db with mode 0600, and leaves the host requiring reboot.
  - Package-generated caches/state and transient pmxcfs status files are excluded.

Examples:
  restore.sh
  restore.sh --backup-dir /mnt/tomasz/backups/pve
  restore.sh --backup bv-config-2026-09-26_03-00-02.tar.gz
  restore.sh --backup /mnt/tomasz/backups/pve/bv-config-2026-09-26_03-00-02.tar.gz
  restore.sh --dry-run
HELP
}

backup_input=""; backup_dir_input=""; dry_run=false; original_argc=$#
while (( $# )); do
  case "$1" in
    -h|--help) help; exit 0 ;;
    --backup) [[ $# -ge 2 ]] || fail "--backup requires FILE_OR_PATH"; backup_input="$2"; shift 2 ;;
    --backup-dir) [[ $# -ge 2 ]] || fail "--backup-dir requires DIRECTORY"; backup_dir_input="$2"; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    *) fail "unknown option '$1' (use --help)" ;;
  esac
done
if (( original_argc == 0 )); then
  printf 'Parameters: [--backup FILE_OR_PATH] [--backup-dir DIRECTORY] [--dry-run] [-h|--help]\n'
  printf 'No parameters supplied: starting the interactive restore wizard. Use --help for details.\n\n'
fi

for cmd in tar rsync cp mkdir mktemp rm find sort date hostname systemctl grep awk basename dirname mountpoint install mv; do
  command -v "$cmd" >/dev/null 2>&1 || fail "required command is not available: $cmd"
done

script_dir="$restore_script_dir"
backup_lib="$(cd "$script_dir/.." && pwd)" || fail "could not determine backup library directory"
read_storage="$backup_lib/read-storage.sh"; storage_path="$backup_lib/storage-path.sh"

normalize_dir() {
  local d="$1"
  [[ "$d" == /* && -d "$d" ]] || return 1
  if find "$d" -maxdepth 1 -type f -name '*-config-*.tar.gz' -print -quit | grep -q .; then printf '%s\n' "$d"; return; fi
  if [[ -d "$d/pve" ]] && find "$d/pve" -maxdepth 1 -type f -name '*-config-*.tar.gz' -print -quit | grep -q .; then printf '%s\n' "$d/pve"; return; fi
  printf '%s\n' "$d"
}

auto_dir() {
  local s p
  [[ -r "$read_storage" && -r "$storage_path" ]] || return 1
  s="$(bash "$read_storage" 2>/dev/null)" || return 1
  p="$(bash "$storage_path" "$s" 2>/dev/null)" || return 1
  [[ -d "$p/pve" ]] || return 1
  printf '%s/pve\n' "$p"
}

choose_dir() {
  local d
  if [[ -n "$backup_dir_input" ]]; then normalize_dir "$backup_dir_input" || fail "invalid backup directory: $backup_dir_input"; return; fi
  if d="$(auto_dir)"; then printf '%s\n' "$d"; return; fi
  printf 'No Proxmox backup storage could be resolved automatically.\n' >&2
  while true; do
    printf 'Enter the directory containing Forge host backups: ' >&2
    IFS= read -r d || fail "could not read backup directory"
    normalize_dir "$d" && return
    printf 'Invalid directory. Use an existing absolute path.\n' >&2
  done
}

choose_backup() {
  local d="$1" epoch path answer i=0
  BACKUPS=()
  printf '\nBackup directory: %s\n\nAvailable backups (newest first):\n\n' "$d" >&2
  while IFS='|' read -r epoch path; do
    [[ -n "$path" ]] || continue
    BACKUPS+=("$path"); i=$((i + 1))
    printf '  [%d] %s  %s\n' "$i" "$(date -d "@$epoch" '+%Y-%m-%d %H:%M')" "$(basename -- "$path")" >&2
  done < <(find "$d" -maxdepth 1 -type f -name '*-config-*.tar.gz' -printf '%T@|%p\n' | LC_ALL=C sort -t'|' -k1,1nr)
  (( ${#BACKUPS[@]} )) || fail "no Forge host backups found in $d"
  while true; do
    printf '\nSelect backup [1-%d] (q to quit): ' "${#BACKUPS[@]}" >&2
    IFS= read -r answer || fail "could not read backup selection"
    [[ "$answer" =~ ^[qQ]$ ]] && exit 0
    [[ "$answer" =~ ^[0-9]+$ ]] && (( answer >= 1 && answer <= ${#BACKUPS[@]} )) && { printf '%s\n' "${BACKUPS[answer-1]}"; return; }
    printf 'Invalid selection.\n' >&2
  done
}

backup_dir=""; backup_file=""
if [[ -n "$backup_input" && "$backup_input" == /* ]]; then
  backup_file="$backup_input"
else
  backup_dir="$(choose_dir)"
  if [[ -n "$backup_input" ]]; then
    [[ "$backup_input" != */* ]] || fail "relative backup paths are not supported"
    backup_file="$backup_dir/$backup_input"
  else
    backup_file="$(choose_backup "$backup_dir")"
  fi
fi
[[ "$backup_file" == *.tar.gz && -f "$backup_file" && -r "$backup_file" ]] || fail "invalid/unreadable backup: $backup_file"
archive_list="$(tar -tzf "$backup_file")" || fail "backup archive is not readable"
printf '%s\n' "$archive_list" | grep -Eq '(^/|(^|/)\.\.(/|$))' && fail "backup archive contains an unsafe path"
archive_time="$(date -r "$backup_file" '+%Y-%m-%d %H:%M')"
printf '\nSelected backup:\n  Date: %s\n  File: %s\n' "$archive_time" "$backup_file"
workspace="$(mktemp -d /root/proxmox-forge-host-restore.XXXXXX)" || fail "could not create restore workspace"
tar -xzf "$backup_file" -C "$workspace" || fail "could not extract backup"
[[ -d "$workspace/etc" || -d "$workspace/root" || -d "$workspace/var/lib/pve-cluster" || -d "$workspace/usr/local/bin" ]] || fail "unrecognized Forge host backup layout"

subject_name() {
  case "$1" in
    1) echo 'Proxmox configuration';; 2) echo 'Network';; 3) echo 'Storage & mounts';;
    4) echo 'APT repositories & custom configuration';; 5) echo 'Forge configuration';;
    6) echo 'Custom services & schedules';; 7) echo 'Host security';; 8) echo 'System tuning';;
    9) echo 'Local users & authentication';; 10) echo 'Root SSH & credentials';;
    11) echo 'Root shell & editor configuration';; 12) echo 'Root application configuration & state';;
    13) echo 'Proxmox cluster state (ADVANCED)';; 14) echo 'Local executables (/usr/local/bin)';;
  esac
}

choose_subjects() {
  local a t valid
  declare -gA SELECTED=()
  while true; do
    cat <<'MENU'

What do you want to restore?

   [0] ALL standard subjects (excludes Proxmox cluster state)
   [1] Proxmox configuration
   [2] Network
   [3] Storage & mounts
   [4] APT repositories & custom configuration
   [5] Forge configuration
   [6] Custom services & schedules
   [7] Host security
   [8] System tuning
   [9] Local users & authentication
  [10] Root SSH & credentials
  [11] Root shell & editor configuration
  [12] Root application configuration & state
  [13] Proxmox cluster state (ADVANCED; alternate to subject 1)
  [14] Local executables (/usr/local/bin)
MENU
    printf '\nSelection (comma-separated): '; IFS= read -r a || fail "could not read restore selection"
    a="${a//[[:space:]]/}"; [[ -n "$a" ]] || continue; SELECTED=()
    if [[ "$a" == 0 ]]; then for t in {1..12} 14; do SELECTED[$t]=1; done; break; fi
    IFS=',' read -r -a tokens <<<"$a"; valid=true
    for t in "${tokens[@]}"; do [[ "$t" =~ ^([1-9]|1[0-4])$ ]] && SELECTED[$t]=1 || { valid=false; break; }; done
    [[ "$valid" == true && ${#SELECTED[@]} -gt 0 ]] && break
    printf 'Invalid selection.\n' >&2
  done
  if [[ -n "${SELECTED[13]+x}" && -n "${SELECTED[1]+x}" ]]; then unset 'SELECTED[1]'; printf 'Cluster state selected: granular Proxmox configuration deselected.\n'; fi
}
choose_subjects

printf '\nRestore plan:\n'; for n in $(printf '%s\n' "${!SELECTED[@]}" | sort -n); do printf '  - %s\n' "$(subject_name "$n")"; done
[[ "$dry_run" == true ]] && printf '  - DRY RUN: no changes will be written\n'
printf '\nContinue with this restore plan? [yes/no]: '; IFS= read -r answer || fail "could not read confirmation"
[[ "$answer" == yes ]] || { printf 'Restore cancelled.\n'; exit 0; }

RESTORED=(); SKIPPED=(); WARNINGS=(); reboot_required=false; cluster_state_restored=false
warn() { WARNINGS+=("$1"); printf 'WARNING: %s\n' "$1" >&2; }
copy_file() { local s="$1" d="$2"; [[ -f "$s" || -L "$s" ]] || return; printf '  file: %s\n' "$d"; [[ "$dry_run" == true ]] && return; mkdir -p "$(dirname "$d")"; cp -a -- "$s" "$d" || fail "could not restore $d"; }
copy_dir() { local s="$1" d="$2"; [[ -d "$s" ]] || return; printf '  directory: %s\n' "$d"; [[ "$dry_run" == true ]] && return; mkdir -p "$d"; rsync -a "$s"/ "$d"/ || fail "could not restore $d"; }
copy_path() { [[ -d "$workspace/$1" ]] && copy_dir "$workspace/$1" "/$1" || copy_file "$workspace/$1" "/$1"; }
restore_paths() { local label="$1"; shift; printf '\n== %s ==\n' "$label"; for p in "$@"; do copy_path "$p"; done; RESTORED+=("$label"); }

restore_proxmox() {
  local src="$workspace/etc/pve" current backup_node; printf '\n== Proxmox configuration ==\n'
  [[ -d "$src" ]] || { SKIPPED+=("Proxmox configuration (missing)"); return; }
  mountpoint -q /etc/pve || fail "/etc/pve is not mounted; granular Proxmox restore requires pmxcfs"
  for p in datacenter.cfg jobs.cfg replication.cfg storage.cfg user.cfg vzdump.cron; do copy_file "$src/$p" "/etc/pve/$p"; done
  for p in mapping firewall sdn virtual-guest; do copy_dir "$src/$p" "/etc/pve/$p"; done
  copy_file "$src/ha/resources.cfg" /etc/pve/ha/resources.cfg; copy_file "$src/ha/rules.cfg" /etc/pve/ha/rules.cfg
  mapfile -t nodes < <(find "$src/nodes" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort)
  if (( ${#nodes[@]} == 1 )); then
    backup_node="${nodes[0]}"; current="$(hostname -s)"
    copy_dir "$src/nodes/$backup_node/lxc" "/etc/pve/nodes/$current/lxc"; copy_dir "$src/nodes/$backup_node/qemu-server" "/etc/pve/nodes/$current/qemu-server"; copy_file "$src/nodes/$backup_node/host.fw" "/etc/pve/nodes/$current/host.fw"
    [[ "$backup_node" == "$current" ]] || warn "guest configuration mapped from backup node '$backup_node' to '$current'"
  elif (( ${#nodes[@]} > 1 )); then warn "multiple backup nodes found; node-specific guest configuration skipped"; fi
  RESTORED+=("Proxmox configuration")
}

restore_network() {
  printf '\n== Network ==\nNetwork restore can change connectivity/interface naming. Restore it? [yes/no]: '; IFS= read -r answer
  [[ "$answer" == yes ]] || { SKIPPED+=("Network (declined)"); return; }
  for p in etc/network/interfaces etc/network/interfaces.d etc/hostname etc/hosts etc/resolv.conf; do copy_path "$p"; done
  RESTORED+=("Network"); reboot_required=true
}

restore_apt() {
  local f b; printf '\n== APT repositories & custom configuration ==\n'
  copy_path etc/apt/sources.list; for p in sources.list.d preferences.d auth.conf.d keyrings; do copy_path "etc/apt/$p"; done
  if [[ -d "$workspace/etc/apt/apt.conf.d" ]]; then while IFS= read -r -d '' f; do b="$(basename "$f")"; case "$b" in 99-*|no-*) copy_file "$f" "/etc/apt/apt.conf.d/$b";; esac; done < <(find "$workspace/etc/apt/apt.conf.d" -maxdepth 1 -type f -print0); fi
  RESTORED+=("APT repositories & custom configuration")
}

restore_custom_services() {
  local f rel dst; printf '\n== Custom services & schedules ==\n'
  for root in etc/systemd/system etc/cron.d etc/cron.hourly etc/cron.daily etc/cron.weekly etc/cron.monthly etc/cron.yearly; do
    [[ -d "$workspace/$root" ]] || continue
    while IFS= read -r -d '' f; do rel="${f#"$workspace/$root"/}"; dst="/$root/$rel"; if command -v dpkg-query >/dev/null 2>&1 && dpkg-query -S "$dst" >/dev/null 2>&1; then continue; fi; copy_file "$f" "$dst"; done < <(find "$workspace/$root" -type f -print0)
  done
  copy_path etc/crontab; RESTORED+=("Custom services & schedules"); warn "custom systemd units restored without package-generated *.wants symlinks; review enablement"
}

restore_users() {
  printf '\n== Local users & authentication ==\nThis replaces passwd/shadow/group/gshadow/subuid/subgid. Continue? [yes/no]: '; IFS= read -r answer
  [[ "$answer" == yes ]] || { SKIPPED+=("Local users & authentication (declined)"); return; }
  for p in passwd shadow group gshadow subuid subgid shells; do copy_file "$workspace/etc/$p" "/etc/$p"; done; RESTORED+=("Local users & authentication")
}

restore_root_credentials() {
  local f; printf '\n== Root SSH & credentials ==\n'; copy_path root/.ssh; copy_path root/.forward
  while IFS= read -r -d '' f; do copy_file "$f" "/root/$(basename "$f")"; done < <(find "$workspace/root" -maxdepth 1 -type f -name '.smbcredentials-*' -print0 2>/dev/null)
  RESTORED+=("Root SSH & credentials")
}

no_running_guests() {
  local r=""; command -v pct >/dev/null 2>&1 && r+="$(pct list 2>/dev/null | awk 'NR>1 && $2=="running" {print "LXC " $1}')"
  if command -v qm >/dev/null 2>&1; then [[ -z "$r" ]] || r+=$'\n'; r+="$(qm list 2>/dev/null | awk 'NR>1 && $3=="running" {print "VM " $1}')"; fi
  [[ -z "$r" ]] || fail "cluster-state recovery refused while guests are running:\n$r"
}

restore_cluster_state() {
  local db="$workspace/var/lib/pve-cluster/config.db" status nodes newdb; printf '\n== Proxmox cluster state (ADVANCED) ==\n'; [[ -f "$db" ]] || fail "backup contains no config.db"
  no_running_guests
  if command -v pvecm >/dev/null 2>&1; then status="$(pvecm status 2>/dev/null)" || status=""; nodes="$(printf '%s\n' "$status" | awk -F: '/^Nodes:/ {gsub(/[[:space:]]/,"",$2); print $2; exit}')"; [[ "$nodes" =~ ^[0-9]+$ ]] && (( nodes > 1 )) && fail "cluster-state recovery refused on multi-node cluster (nodes: $nodes)"; fi
  printf 'This replaces the complete pmxcfs database and requires reboot. Type RESTORE to continue: '; IFS= read -r answer
  [[ "$answer" == RESTORE ]] || { SKIPPED+=("Proxmox cluster state (confirmation not provided)"); return; }
  if [[ "$dry_run" == true ]]; then printf '  would stop pve-cluster and install config.db mode 0600\n'; else
    systemctl stop pve-cluster || fail "could not stop pve-cluster"; systemctl is-active --quiet pve-cluster && fail "pve-cluster is still active"
    newdb="/var/lib/pve-cluster/.config.db.forge-new.$$"; install -o root -g root -m 0600 "$db" "$newdb" || { systemctl start pve-cluster >/dev/null 2>&1 || true; fail "could not stage config.db"; }
    mv -f "$newdb" /var/lib/pve-cluster/config.db || { rm -f "$newdb"; systemctl start pve-cluster >/dev/null 2>&1 || true; fail "could not replace config.db"; }
  fi
  RESTORED+=("Proxmox cluster state"); cluster_state_restored=true; reboot_required=true; warn "pve-cluster left stopped after config.db recovery; verify hostname/hosts and reboot"
}

for n in $(printf '%s\n' "${!SELECTED[@]}" | sort -n); do
  case "$n" in
    1) restore_proxmox;; 2) restore_network;;
    3) restore_paths 'Storage & mounts' etc/fstab etc/nfs.conf etc/nfs.conf.d etc/idmapd.conf etc/iscsi etc/lvm etc/zfs;;
    4) restore_apt;; 5) restore_paths 'Forge configuration' etc/proxmox-forge;; 6) restore_custom_services;;
    7) restore_paths 'Host security' etc/ssh etc/fail2ban etc/nftables.conf etc/ufw etc/hosts.allow etc/hosts.deny;;
    8) restore_paths 'System tuning' etc/sysctl.conf etc/sysctl.d etc/modprobe.d etc/modules etc/modules-load.d etc/hdparm.conf etc/default/grub; warn "review restored kernel/module/GRUB tuning before reboot";;
    9) restore_users;; 10) restore_root_credentials;;
    11) restore_paths 'Root shell & editor configuration' root/.bashrc root/.bash_profile root/.profile root/.selected_editor;;
    12) restore_paths 'Root application configuration & state' root/.config root/.joe_state;;
    13) ;; 14) restore_paths 'Local executables (/usr/local/bin)' usr/local/bin;;
  esac
done
[[ -n "${SELECTED[13]+x}" ]] && restore_cluster_state

printf '\n=== Restore summary ===\nBackup: %s (%s)\n' "$backup_file" "$archive_time"; [[ "$dry_run" == true ]] && printf 'Mode: DRY RUN\n'
printf '\nRestored/planned:\n'; (( ${#RESTORED[@]} )) && printf '  - %s\n' "${RESTORED[@]}" || printf '  - none\n'
if (( ${#SKIPPED[@]} )); then printf '\nSkipped:\n'; printf '  - %s\n' "${SKIPPED[@]}"; fi
if (( ${#WARNINGS[@]} )); then printf '\nReview:\n'; printf '  - %s\n' "${WARNINGS[@]}"; fi
cat <<'NEXT'

Post-restore checks:
  1. Review Proxmox storage and Datacenter configuration.
  2. Verify VM/LXC configuration and referenced storage/mount paths.
  3. If network files were restored, verify interface names before reboot.
  4. Review restored custom systemd services and enable/start only those required.
  5. Review APT repositories before the next package operation.
NEXT
[[ "$cluster_state_restored" == true ]] && printf '  6. Cluster state restored: verify hostname/hosts and reboot before normal Proxmox operation.\n'
[[ "$cluster_state_restored" != true && "$reboot_required" == true ]] && printf '  6. A reboot is recommended after the selected restore operations.\n'
printf '\nrestore=success type=host backup=%s dry_run=%s\n' "$backup_file" "$dry_run"
