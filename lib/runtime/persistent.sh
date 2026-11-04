#!/bin/bash
# F131: manually launched Forge updates can run in a tmux server managed by
# systemd, outside the initiating SSH login session. Source from the public CLI.
# This file never performs or retries an update itself.

forge_persistent_init() {
  local uid
  uid="$(id -u)" || return 1
  [[ "$uid" =~ ^[0-9]+$ ]] || return 1
  FORGE_PERSISTENT_SOCKET="proxmox-forge-f131-$uid"
  FORGE_PERSISTENT_SESSION="forge-update"
  FORGE_PERSISTENT_UNIT="proxmox-forge-f131-$uid.service"
  FORGE_PERSISTENT_STATE_DIR="/run/lock/proxmox-forge-f131-$uid"
  FORGE_PERSISTENT_RESULT_FILE="$FORGE_PERSISTENT_STATE_DIR/exit-code"
  FORGE_PERSISTENT_WORKER="$(dirname "$PERSISTENT_SCRIPT")/persistent-worker.sh"
}

forge_persistent_active() {
  command -v tmux >/dev/null 2>&1 || return 1
  tmux -L "$FORGE_PERSISTENT_SOCKET" has-session \
    -t "=$FORGE_PERSISTENT_SESSION" >/dev/null 2>&1
}

forge_persistent_back() {
  if ! forge_persistent_active; then
    printf 'No persistent update is running. View earlier results with: forge history\n'
    return 0
  fi
  if [[ ! -t 0 || ! -t 1 ]]; then
    printf 'ERROR: forge back requires an interactive terminal\n' >&2
    return 1
  fi
  forge_persistent_attach
}

forge_persistent_stop_server() {
  # Called only after this invocation successfully created its own transient
  # unit and before launching an update. Never stop an existing active update.
  systemctl --no-pager stop "$FORGE_PERSISTENT_UNIT" >/dev/null 2>&1 ||
    printf 'WARNING: unable to stop unused F131 service %s\n' \
      "$FORGE_PERSISTENT_UNIT" >&2
}

forge_persistent_prepare() {
  local tool properties
  [[ -t 0 && -t 1 && -r /dev/tty ]] || {
    printf 'ERROR: persistent updates require an interactive SSH/terminal session; disable PERSISTENT_UPDATE_SESSION to run without tmux\n' >&2
    return 1
  }
  [[ -z "${TMUX:-}" ]] || {
    printf 'ERROR: persistent Forge updates cannot be launched from inside an existing tmux client\n' >&2
    return 1
  }
  for tool in tmux systemd-run systemctl; do
    command -v "$tool" >/dev/null 2>&1 || {
      printf 'ERROR: persistent updates require %s; install/configure it or set PERSISTENT_UPDATE_SESSION=false\n' "$tool" >&2
      return 1
    }
  done
  if forge_persistent_active; then
    printf 'ERROR: a persistent Forge update is already running. Execute: forge back\n' >&2
    return 1
  fi
  if [[ ! -r "$FORGE_PERSISTENT_WORKER" ]]; then
    printf 'ERROR: F131 worker component is unavailable; no persistent update started\n' >&2
    return 1
  fi

  # Keep the short worker exit-status handoff out of the Git checkout and
  # protect it from symlinks / other local users. The authoritative result
  # and all diagnostics still belong to Forge's existing run logs.
  if [[ -L "$FORGE_PERSISTENT_STATE_DIR" ]] ||
     ! (umask 077; mkdir -p -m 0700 "$FORGE_PERSISTENT_STATE_DIR") ||
     [[ "$(stat -c '%u:%a' "$FORGE_PERSISTENT_STATE_DIR")" != "$(id -u):700" ]] ||
     [[ -L "$FORGE_PERSISTENT_RESULT_FILE" ]]; then
    printf 'ERROR: F131 runtime result directory is not a private, owned directory; update cancelled\n' >&2
    return 1
  fi
  rm -f -- "$FORGE_PERSISTENT_RESULT_FILE" || {
    printf 'ERROR: cannot reset the persistent update exit-status handoff\n' >&2
    return 1
  }

  if ! systemd-run --unit="${FORGE_PERSISTENT_UNIT%.service}" \
    --collect --property=Type=exec -- \
    "$(command -v tmux)" -D -L "$FORGE_PERSISTENT_SOCKET" -f /dev/null; then
    printf 'ERROR: cannot start a persistent tmux server outside the SSH session; configure systemd access or set PERSISTENT_UPDATE_SESSION=false\n' >&2
    return 1
  fi

  properties="$(systemctl --no-pager show "$FORGE_PERSISTENT_UNIT" \
    -p ActiveState -p MainPID -p ControlGroup)" || {
    forge_persistent_stop_server
    printf 'ERROR: cannot verify the F131 systemd service\n' >&2
    return 1
  }
  if ! grep -Fxq 'ActiveState=active' <<<"$properties" ||
     ! grep -Eq '^MainPID=[1-9][0-9]*$' <<<"$properties" ||
     ! grep -Fxq "ControlGroup=/system.slice/$FORGE_PERSISTENT_UNIT" <<<"$properties"; then
    forge_persistent_stop_server
    printf 'ERROR: F131 server is not confirmed independent of the SSH login (system.slice); update cancelled. Disable PERSISTENT_UPDATE_SESSION or fix systemd permissions\n' >&2
    return 1
  fi

  # The transient service must have opened the tmux socket already. Without
  # this check, new-session could implicitly start a second, SSH-owned server.
  # Type=exec means the tmux process was launched, not that it finished setup.
  local ready=false i
  for ((i=0; i<10; i++)); do
    if tmux -L "$FORGE_PERSISTENT_SOCKET" show-options -g -v exit-empty >/dev/null 2>&1; then
      ready=true
      break
    fi
    sleep 0.1
  done
  if [[ "$ready" != true ]]; then
    forge_persistent_stop_server
    printf 'ERROR: systemd-owned tmux server socket is not ready; persistent update cancelled\n' >&2
    return 1
  fi
  return 0
}

forge_persistent_spawn() {
  local entry="$1"
  shift
  if ! tmux -L "$FORGE_PERSISTENT_SOCKET" new-session -d \
    -s "$FORGE_PERSISTENT_SESSION" -c "$PWD" \
    -e "PATH=$PATH" -e "HOME=${HOME:-/root}" \
    -e "FORGE_PERSISTENT_INNER=1" -e "FORGE_SELF_UPDATE_SKIP_PROMPT=1" \
    /bin/bash "$FORGE_PERSISTENT_WORKER" "$FORGE_PERSISTENT_RESULT_FILE" \
    "$entry" "$@"; then
    forge_persistent_stop_server
    printf 'ERROR: cannot create the persistent Forge update session; no update launched\n' >&2
    return 1
  fi

  # tmux -D intentionally disables exit-empty. Restore automatic shutdown
  # only after the worker session exists; the systemd unit then cleans up
  # when the last update pane exits.
  if ! tmux -L "$FORGE_PERSISTENT_SOCKET" set-option -g exit-empty on; then
    if forge_persistent_active; then
      printf 'WARNING: could not configure automatic tmux server shutdown; update remains accessible with forge back\n' >&2
    else
      tmux -L "$FORGE_PERSISTENT_SOCKET" kill-server 2>/dev/null || :
    fi
  fi
}

forge_persistent_attach() {
  local status
  # The initiating SSH client owns no Forge lock. If it disconnects, the
  # systemd-owned tmux server and updater remain alive.
  if forge_persistent_active; then
    tmux -L "$FORGE_PERSISTENT_SOCKET" attach-session \
      -t "=$FORGE_PERSISTENT_SESSION" || {
      if forge_persistent_active; then
        printf 'WARNING: detached from running update; reconnect with: forge back\n' >&2
        return 1
      fi
    }
  fi
  if [[ -r "$FORGE_PERSISTENT_RESULT_FILE" ]]; then
    IFS= read -r status < "$FORGE_PERSISTENT_RESULT_FILE"
    if [[ "$status" =~ ^(0|[1-9][0-9]{0,2})$ ]] && (( status <= 255 )); then
      return "$status"
    fi
  fi
  if forge_persistent_active; then
    printf 'Persistent update continues independently; reconnect with: forge back\n'
  else
    printf 'Persistent update ended; inspect its result with: forge history\n'
  fi
}
