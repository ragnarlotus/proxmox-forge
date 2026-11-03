#!/bin/bash
# Read-only local Proxmox host software facts for the final results.
# Never execute an updater, guess a version, or change host state.

forge_host_software() {
  local reboot_helper="${1:-}" pve_output="" os_id="" os_version=""
  local running="" reboot_record="" installed="" value
  local -a facts=()

  # Proxmox reports the version of the installed pve-manager package.
  if command -v pveversion >/dev/null 2>&1; then
    pve_output="$(pveversion 2>/dev/null)" || pve_output=""
    if [[ "$pve_output" =~ ^pve-manager/([0-9][A-Za-z0-9.+~:-]*)/ ]]; then
      facts+=("Proxmox VE ${BASH_REMATCH[1]}")
    fi
  fi

  # Read ID and VERSION_ID as data, never source an OS-supplied shell file.
  if [[ -r /etc/os-release ]]; then
    os_id="$(sed -n 's/^ID=//p' /etc/os-release | head -n 1)"
    os_version="$(sed -n 's/^VERSION_ID=//p' /etc/os-release | head -n 1)"
    os_id="${os_id#\"}"; os_id="${os_id%\"}"
    os_version="${os_version#\"}"; os_version="${os_version%\"}"
    if [[ "$os_id" == debian && "$os_version" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
      facts+=("Debian $os_version")
    fi
  fi

  if command -v uname >/dev/null 2>&1; then
    running="$(uname -r 2>/dev/null)" || running=""
  fi
  if [[ "$running" =~ ^[0-9][A-Za-z0-9._+~:-]*-pve$ ]]; then
    facts+=("Kernel running $running")
    # Reuse F094's existing Proxmox-kernel inventory. It reports the latest
    # installed kernel, which need not be the kernel selected for next boot.
    if [[ -r "$reboot_helper" ]]; then
      reboot_record="$(bash "$reboot_helper" host 2>/dev/null)" || reboot_record=""
      if [[ "$reboot_record" =~ latest_installed_kernel=([0-9][A-Za-z0-9._+~:-]*-pve) ]]; then
        installed="${BASH_REMATCH[1]}"
      fi
    fi
    if [[ -n "$installed" && "$installed" != "$running" ]]; then
      facts+=("Latest installed kernel $installed")
    fi
  fi

  if (("${#facts[@]}" == 0)); then
    return 0
  fi
  local joined=""
  for value in "${facts[@]}"; do
    [[ -z "$joined" ]] || joined+="; "
    joined+="$value"
  done
  printf '%s\n' "$joined"
}
