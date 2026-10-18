# Optional Forge scheduled updates (F121)

The systemd units are templates shipped **disabled** in the Git repository.
Updating the checkout does not copy or activate them. There is no scheduled
run unless an administrator explicitly installs/enables the timer **and**
configures at least one authorized target in local `forge.conf`.

## Authorization

Only `forge update scheduled` is used by the service:

```bash
SCHEDULED_UPDATE_HOST=false
SCHEDULED_UPDATE_LXC=""
```

Both defaults authorize nothing; `forge update scheduled` refuses execution.
The local administrator may set, for example, `SCHEDULED_UPDATE_LXC="107,112"`
to authorize those **exact VMIDs**, but this is only an example, not a
recommendation to update those services unattended. Names and wildcards are
not accepted; duplicate or invalid IDs fail validation. A configured VMID
that no longer exists blocks the whole run before mutations. Running,
non-template guests only; `EXCLUDE` still takes precedence. Manual
`UPDATE_HOST` and `UPDATE_RUNNING_LXC` do not widen the scheduled scope.
`SCHEDULED_UPDATE_HOST=true` explicitly authorizes a Proxmox host update;
host rollback is unsupported and no reboot is automatic.

The existing preflights, serial execution, backup/recovery, global flock,
error reporting and `LOG_KEEP` apply unchanged. An authorized LXC update may
still interrupt the service even if the VM itself remains running: eligibility
is not proof of inactivity.

## Install and activate, only after validating the maintenance window

The agreed maintenance window is **Saturday at 04:00 Europe/Madrid** (Friday
night), with `OnCalendar=Sat *-*-* 04:00:00 Europe/Madrid` in the versioned
timer. The explicit timezone keeps the intended Madrid local clock time across
daylight-saving changes, regardless of the Proxmox host timezone. Installing
or updating the Git checkout never enables the timer automatically.

After confirming the intended schedule and authorized targets, copy the two
versioned unit files to `/etc/systemd/system/` on the Proxmox host and run:

```bash
systemctl daemon-reload
systemd-analyze calendar 'Sat *-*-* 04:00:00 Europe/Madrid'
systemctl enable --now proxmox-forge-update.timer
systemctl list-timers --all --no-pager proxmox-forge-update.timer
```

No catch-up run is performed after downtime (`Persistent=false`). The
service itself is not enabled and starts only when triggered by the timer or
explicitly via `systemctl start`.

To disable future automatic runs:

```bash
systemctl disable --now proxmox-forge-update.timer
```

The timer does not change interactive `forge update all` output. Scheduled
stdout/stderr goes to `journalctl -u proxmox-forge-update.service --no-pager`,
while Forge writes its normal run and target logs. After completion,
`forge status` and `forge history` read the same F141/F228 records. During
an update, Forge's current global lock blocks other Forge commands, including
status/history; the journal and raw logs remain readable. Email notification
still requires `EMAIL_NOTIFICATIONS=true` and follows F153/F154 policy.

Do not force-stop an update merely to disconnect: the systemd service is
independent of SSH, but stopping the service can interrupt it.
