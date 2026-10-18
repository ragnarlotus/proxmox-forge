# Forge — Feature Checklist

Practical capability checklist for Forge's Proxmox host and LXC updater, including agreed improvements and separately identified future candidates from comparisons with other updaters.

Existing feature IDs are intentionally preserved for historical traceability, so gaps are expected. Unchecked items are candidates, not commitments. The comparison candidates at the end do not supersede the current scope constraints or approve implementation.

Implemented means the capability exists in the current `main` branch at the scope described. Partial plumbing, collected-but-unused data, or behaviour that only happens incidentally is not marked as implemented.

## Status

- [ ] Not implemented
- [x] Implemented

## Initial scope constraints

These are the agreed behavioural requirements of the current implementation.

- [x] **Exact target resolution** — a guest may be selected by exact Proxmox VMID or exact guest name only. Partial, prefix or fuzzy name matching is forbidden. No exact match must fail; an ambiguous exact name must also fail.
- [x] **Stopped LXC automatic-scope exclusion** — bulk updates never select stopped containers automatically. An explicitly requested stopped LXC may be started temporarily for its update and is returned to stopped state afterwards.
- [x] **Guest transaction boundary** — each guest is handled independently. A required step failure makes that guest fail, recovery/rollback is attempted when supported, the real failure remains authoritative, and processing may continue with later guests.
- [x] **No host rollback** — Forge must never claim or attempt guest-style rollback for the Proxmox host itself. Host update failures are reported as failures.
- [x] **Validate before mutation** — load and validate the complete configuration and determine the selected target identities/scope before the first mutating operation; mutable LXC properties such as current state and template status are revalidated when each guest update begins.
- [x] **Manual invocation preserved** — interactive update commands still execute in the calling terminal. Optional F121 scheduling is a separate, explicit, disabled-by-default systemd timer with independently authorized targets; there is no general background-job daemon or Web UI.

Forge performs updates rather than checking what is available in advance. Repository metadata is refreshed as part of actual package updates; standalone pending-update discovery, package previews and pre-execution update-plan generation are intentionally outside the product scope.

---

## A. Discovery and inventory

- [x] **F001** Detect the local Proxmox host automatically.
- [x] **F002** Discover all LXC containers.
- [ ] **F003** Discover all virtual machines.
- [x] **F006** Detect target state: running, stopped, template, etc.
- [x] **F007** Detect target OS, distribution and version.
- [x] **F010** Inventory available application/special updater mechanisms.

## B. Package-update diagnostics

- [x] **F022** Detect actionable held APT upgrades. After the OS APT stage (using refreshed lists when `apt-get update` succeeds), Forge checks only explicitly held packages with a newer APT candidate (`apt-mark showhold`, `apt-cache policy`, `dpkg --compare-versions`); reports affected package, installed and candidate versions, and count. No noise for holds without available upgrades, no unhold or impact on update/recovery exit status. On OS failures findings provide diagnosis; on Community Scripts updater failures they are context only, not proof of causation. If LXC OS updates are disabled but the app updater is active, cached candidate versions are checked before the app stage. Automated regression tests cover both flows, empty/non-outdated holds, diagnostic failures and warnings.

## C. Selection and policies

- [x] **F026** `EXCLUDE` selection by ID/name. `EXCLUDE=""` defaults to no exclusions. Comma-separated exact VMIDs or hostnames are removed from the running-LXC selection used by `forge lxc list-targets`, `forge lxc update all`, `forge update all` and `validate-config`. Filtering occurs before resource and recovery preflights, backup and update. Explicit `forge lxc update TARGET` and host updates remain unaffected. Malformed configuration is rejected; automated tests cover matching and bulk enforcement.
- [x] **F029** Filter automatic LXC scope by running state. `UPDATE_RUNNING_LXC` controls inclusion of currently running LXCs; stopped LXCs are never selected automatically.
- [x] **F030** Skip templates automatically.

## D. Update execution

- [x] **F040** No interactive prompts during update execution.
- [x] **F041** Execute each mutating operation exactly once.
- [x] **F042** Deterministic terminal output capture during updates.

## E. Operating systems and package managers

- [x] **F046** Debian/Ubuntu updates through APT.
- [x] **F054** Automatically detect the supported update strategy.

> The current LXC update scope is APT-only. F054 means detecting APT as supported and rejecting unsupported package managers.

## F. Application updates and custom scripts

- [x] **F056** Update applications installed through Proxmox Community Scripts.
- [x] **F057** Detect `/usr/bin/update` or another known application updater.
- [x] **F059** Per-target custom scripts.
- [x] **F063** Every plugin/script returns an authoritative result.
- [x] **F234 — Optional temporary LXC CPU/RAM limits.** A common resource-boost mechanism for host/LXC maintenance, available to all LXC updates (not tied to an application name). `LXC_UPDATE_TEMP_CORES=0` and `LXC_UPDATE_TEMP_MEMORY_MB=0` disable it by default. Positive values in the local `forge.conf` request **minimum** limits for the duration of a guest update; Forge never reduces higher existing limits. After the same-run backup but before OS/application/custom update steps, a guarded helper reads `pct config --current`, verifies original explicit limits, checks requested CPUs against online host CPUs and additional RAM against host `MemAvailable` plus `MIN_MEM_AVAILABLE_MB`, saves originals to a private state file and uses `pct set`. The helper verifies the effective changes and restores/verifies original limits before health checks and before rollback, including partial `pct set` failures and shell exit/signal cleanup. Failing an enabled resource requirement blocks that guest update without silently falling back to normal limits. If an administrator changes limits externally, Forge refuses to overwrite the new value and reports a failed cleanup; this is not a guarantee against SIGKILL or host power loss. No changes are made to swap, CPU quotas, CPU weights or other LXC settings. Fake-PVE regression tests exercise apply/restore, failure, resources, ordering and authoritative exit codes; a live-host resource-change test remains pending.


## G. Preflight

- [x] **F064** Check free filesystem space. `MIN_ROOT_FREE_MB` (default 1024 MiB) enforces free space on `/` for host/LXC updates. Bulk runs check all selected running LXCs before host/guest changes, and individual target requirements check before mutation.
- [x] **F066** Check available memory. Configurable `MIN_MEM_AVAILABLE_MB` (128 MiB by default) enforces a minimum `MemAvailable` for the Proxmox host and running LXCs; bulk operations check selected LXC memory before any host/guest mutation and individual target requirements recheck immediately before updates. Missing/invalid readings block mutation. The real inspection shell payload and preflight paths are covered by automated regression tests.
- **F068 — DESCARTADO (2026-10-15).** No implementar una comprobación propia de LVM-thin `Data%` / `Meta%` en Forge. Proxmox ya expone estas métricas y Forge ha dejado de crear snapshots persistentes: sus puntos de recuperación son backups `vzdump` en el almacenamiento configurado en Proxmox.
- [ ] **F069** Check storage required for snapshots/backups.
- [x] **F071** Detect package-manager locks/conflicting processes.
- [x] **F075** A failed mandatory preflight blocks the update.

> Root space (F064) and available memory (F066) are enforced preflight requirements. F068 was explicitly dropped from the roadmap; F069 remains deferred.

## H. Backup and recovery

- [x] **F077** Proxmox-native pre-update backup, required for LXC mutations in backup-only mode.
- [x] **F078** Require validated same-run `vzdump` backup before LXC mutations; no persistent snapshots created.
- [x] **F079** Select backup storage. Current implementation derives it from the authoritative Proxmox backup configuration instead of maintaining a second Forge storage policy.
- [x] **F080** Support applicable backup modes: snapshot/suspend/stop. Current LXC backup execution inherits supported options from the applicable Proxmox backup job.
- [x] **F082** Verify backup actually completed successfully.
- [x] **F083** Record the exact recovery artifact identifier.
- [x] **F086** Configurable automatic rollback after failure.
- [x] **F087** Retention delegated to the applicable Proxmox backup job. Forge does not create, prune or delete persistent LXC snapshots; existing `Update_*` snapshots are preserved until manually removed.
- [x] **F088** Never remove the recovery artifact before the final result is known.

> Guest rollback capabilities do not apply to the Proxmox host itself.
>
> Forge uses only the same-run `vzdump` backup for LXC recovery, regardless of snapshot support. `CREATE_BACKUP_BEFORE_LXC_UPDATE=true` and an applicable Proxmox backup job are mandatory for updates. With `ROLLBACK_ON_FAILURE=true`, automatic `pct restore --force` is permitted only for a storage-backed rootfs with no existing persistent LXC snapshots; the preflight blocks unsafe cases before mutation and the restore helper rechecks before forcing replacement. Forge never deletes old `Update_*` or manual snapshots; they must be reviewed/removed manually before enabling safe automatic recovery. Proxmox's backup job controls storage, mode and retention; temporary `vzdump --mode snapshot` snapshots are not persistent Forge snapshots. Bulk preflight covers selected running LXCs, not stopped containers.

## I. Guest lifecycle

- [x] **F089** Detect original guest state.
- [x] **F090** Temporarily start an explicitly selected stopped LXC for its update; automatic bulk-update scope never starts stopped guests.
- [x] **F091** Wait for readiness after temporary startup — only when an explicitly selected LXC was initially stopped and Forge starts it, retry a minimal `pct exec` readiness probe for up to 30 seconds before requirements/update stages; LXCs that were already running skip this phase.
- [x] **F092** Update the guest.
- [x] **F093** Restore an explicitly selected originally-stopped LXC to stopped state after the update attempt, including after eligible failure/recovery paths.
- [x] **F094** Detect reboot-required state. After successful host/LXC updates, report `reboot_required=yes|no|unknown` in terminal and logs, with a notice when a restart is indicated; never reboot automatically. Host detection combines Debian's `/run/reboot-required` marker with installed-versus-running Proxmox kernel comparison; LXC detection reads the guest marker while running, before restoring a stopped guest's state. Detection failure is a nonfatal warning, never an update failure, rollback or repeated mutation. Automated tests cover the real detector and actual host/LXC orchestration.

## J. Health and recovery

- [x] **F099** Run health checks after updating.
- [x] **F100** Check relevant systemd services.
- [x] **F101** Configurable functional health checks. `health.d/<VMID>/*.sh` scripts (default `HEALTH_SCRIPTS_DIR=/opt/proxmox-forge/health.d`) run inside the LXC in lexical order after generic health checks; missing directories or scripts preserve generic-only behavior. Failures are authoritative health-stage failures and invoke the existing rollback policy. The same checks also run after rollback because the recovery path reuses `health.sh`. The configuration and effective per-target behavior are regression-tested; host-local scripts are Git-ignored and included in Forge host configuration backups.
- [x] **F106** Roll back when a mandatory health check does not recover.
- [x] **F107** Verify health again after rollback, using the existing LXC health check after the guest is restarted and responds to `pct exec`; record recovery as failed if the check fails.

## K. Correct error semantics

- [x] **F108** Preserve the real exit code of every operation.
- [x] **F109** Preserve stdout.
- [x] **F110** Preserve stderr.
- [x] **F111** Never repeat a mutating operation just to capture its error.
- [x] **F112** A failed required step makes the target fail.
- [x] **F113** A failed target remains failed even when later targets continue.
- [x] **F114** `continue_on_error` means continue processing, never convert failure into success.
- [x] **F115** Correctly aggregate the final run result. Every nonzero LXC update exit code counts as failure; no special exit code is reserved for skipped containers.
- [x] **F116** Distinguish primary failure from cleanup failure.
- [x] **F119** Structured result per step, target and run.

## L. Scheduling and orchestration

- [x] **F120** Immediate manual execution.
- [x] **F121 — Opt-in systemd scheduling with positive target authorization.** Add `forge update scheduled` and ship disabled-by-default `systemd/proxmox-forge-update.service`/`.timer` templates. `SCHEDULED_UPDATE_HOST=false` and `SCHEDULED_UPDATE_LXC=""` authorize no unattended updates by default; only unique numeric VMIDs from the local allowlist may be scheduled, independently of manual `UPDATE_HOST`/`UPDATE_RUNNING_LXC` flags. Continue to honor `EXCLUDE`; never start stopped guests or update templates; reject nonexistent authorized VMIDs before any mutation. Reuse the existing serial bulk engine, full-scope preflights, backup/rollback, single global lock, F141 logging and F225/F228 reporting, without changing interactive terminal capture or host reboot policy. Schedule activation and calendar selection both require deliberate host-admin action. No persistent timer catch-up after host downtime. Regression tests cover empty authorization, manual independence, eligible subset, exclusion, stopped/template, stale IDs, preflight failures and partial results. Systemd integration remains to be installed and observed on the actual Proxmox host.
- [x] **F127** Serial updates.
- [x] **F129** Global lock for incompatible simultaneous runs. Forge currently uses a stricter single-run policy: every `forge` invocation acquires one global non-blocking lock, so a second Forge execution is rejected until the first exits. The standalone PVE restore utility participates in the same lock.
- [ ] **F131** Jobs survive SSH/session disconnection.

> Forge serializes the whole CLI using one global lock. All `lib/**/*.sh` components are internal, except `lib/backup/host/restore.sh`, which acquires the same lock for disaster recovery.

## N. Logging, history and reporting

- [x] **F141** General log per update run. Each explicit host, LXC or bulk update creates a distinct, access-restricted `LOG_DIR/<PVE_FQDN>/runs/<FORGE_RUN_ID>.log` before update preflight; failure to initialize this log blocks mutation. The run log mirrors existing per-target structured events and sanitized stage output as stages complete, records authoritative `result_target` rows and a plain-text rendering of the same F225/F157 final table, and adds run start/end events with the actual CLI exit code. It does not replace per-host/LXC logs, repeat update stages, intercept/modify terminal output or change update/rollback decisions. `LOG_KEEP` also retains the newest general run logs. Best-effort secondary write failures are warned about without masking the real update exit code; early invalid CLI/configuration calls do not create update logs. Regression tests cover run retention, non-overwrite, mirrored events, ANSI/CR handling, TTY colour, target exit codes and CLI run completion.
- [x] **F142** Independent log per target.
- [x] **F144** Precise timestamps.
- [x] **F145** Persist exit codes.
- [ ] **F146** Record duration per step/target/run.
- [x] **F228 — Queryable status and history (2026-10-15).** `forge status [--json]` and `forge history [RUN_ID] [--json]` query retained F141 general run logs using authoritative F220–F225 target/global records. Detail includes actual CLI exit code, error stage/recovery, APT upgrade count, application before/after version, reboot requirement and exact same-run backup when logged. Missing/incomplete records remain unknown; inconsistent totals fail rather than inventing results. Read-only queries run no guest/Proxmox actions or new logging, but retain the global CLI lock. Available history is limited by `LOG_KEEP`; mocked-log and public-CLI regression tests cover behaviour.
- [x] **F147** Basic human-readable final summary (existing scope). The CLI currently prints a readable outcome for individual host/LXC and bulk updates, including success/failure counts, failed VMIDs/exit codes and disabled scopes. **The richer F225 table is now implemented separately**; existing structured result lines, recovery behaviour and exit codes remain intact.

### Final update-results roadmap (agreed scope; implement in order)

The final summary is a **per-execution results table**, inspired by the presentation concept of Ultimate Updater but implemented independently in Forge. It is not an email notification and does not replace authoritative per-target results, persistent logs, or exit codes. The existing F147 summary is the basic view; F220–F225 implement the richer final table, and F157 derives its global status from the same records.

- [x] **F220 — Complete inventory and outcome classification.** Bulk runs snapshot the entire local LXC inventory in numeric VMID order, independently of the authoritative selected update scope, and include the host only for combined runs. On completion each applicable host/LXC has a machine-readable `result_target` record with exact name, selected/attempted flags, `OK`/`ERROR`/`SKIPPED`/`NOT_RUN`, stable reason and authoritative exit code for attempted failures. Stopped, template, excluded and disabled-scope LXCs stay visible as SKIPPED; eligible unattempted targets are NOT_RUN after preflight blockers; an individual host update failure does not suppress the already-approved LXC scope. Selection/inventory mismatch blocks mutation. Single host/LXC updates print their own records; nested bulk records are suppressed. No additional mutations, email or separate F157 logic. If inventory is unreadable Forge fails rather than inventing data; early CLI/config validation is outside per-target reporting. F221–F225 and F157 have since been implemented; regression tests cover policy overlap, numerical order, blocked/mixed outcomes and compatibility with existing update behaviour.
- [x] **F221 — Actual APT package-upgrade counts.** Installed Debian package versions are captured read-only before the first mutation and compared with the final persisted dpkg state using Debian's `dpkg --compare-versions`. One actual upgrade is counted only when a package was installed before and after with a strictly newer version; newly installed, removed, autoremoved, held/unchanged and downgraded packages are not counted. This covers host and LXC, including applications/custom scripts that invoke APT, partial failures, and LXC recovery/rollback (the post-rollback state is authoritative). For initially stopped guests, the final snapshot is taken before restoring the stopped lifecycle state. The same `apt_upgraded=N|-` field is included in F220's final target records for single and bulk runs, transferred through private temporary handoff files without intercepting update output. `0` means measured with no upgrades; `-` means not attempted or unmeasurable. A measurement failure is informational and never changes updates, recovery, selection or authoritative exit codes. Automated tests cover Debian version semantics, zero/unknown, exclusion of non-upgrades, failed/partial updates, rollback and bulk transport; F225 now renders these counts.
- [x] **F222 — Community Scripts application versions (verified adapters).** Read-only probes identify a Community Scripts-managed application by inspecting, never executing, its installed `/usr/bin/update` launcher and accepting the verified generated `SCRIPT_SLUG`/`UPDATE_SCRIPT_NAME` metadata with the official Community Scripts source URL, as well as legacy direct official CT URLs. Supported verified version sources currently cover Plex and Audiobookshelf (installed APT package), Caddy (binary), Pi-hole (Core version), Vaultwarden (installed binary), and Docmost/Immich (installed package.json). Unsupported applications, ambiguous/non-Community-Scripts launchers, invalid metadata and failed probes yield `-`, not a guessed version. Capture installed versions before updates and from the final persisted state after any LXC rollback, while the guest is running; store `app_before` and `app_after` in the same F220 result model for individual and bulk updates. When both match, F225 shows only the current version; when different it shows `before → after`. No use of stale release caches or updater exit status as evidence of a version change. No updater invocation, selection, rollback or exit code is changed by these informational probes. Additional application-specific adapters can be added only with evidence/tests; F223 repository URL and F225 formatted table are separate. **Real-host validation completed 2026-10-13:** all seven configured detector adapters recognized the installed LXC application's identity and version without making changes (101 Pi-hole `v6.4.3`, 102 Plex `1.43.4.10903-e5521bd8c`, 104 Immich `3.3.0`, 105 Caddy `v2.11.6`, 107 Vaultwarden `1.37.4`, 108 Docmost `0.96.0`, 112 Audiobookshelf `2.37.1`). Initial identification and Pi-hole/Vaultwarden probes were fixed using the actual installed outputs, with updated regression tests. This validates read-only detection, not an actual mutating update; state-after-update/rollback behaviour remains covered by automated tests.
- [x] **F223 — Official application source repository (Changelog metadata).** For a positively identified Community Scripts application, record `app_repository=<full URL|->` in the existing F220 `result_target` model, independently of its installed version and update outcome; `-` represents an unknown, unsupported or non-verifiable public source repository. A conservative locally verified allowlist maps `pihole` → `https://github.com/pi-hole/pi-hole`, `caddy` → `https://github.com/caddyserver/caddy`, `vaultwarden` → `https://github.com/dani-garcia/vaultwarden`, `immich` → `https://github.com/immich-app/immich`, `docmost` → `https://github.com/docmost/docmost`, `audiobookshelf` → `https://github.com/advplyr/audiobookshelf`, and `whisparr` → `https://github.com/Whisparr/Whisparr`. These repositories were checked against their canonical GitHub records and Community Scripts source metadata (2026-10-13). Plex is proprietary and has no verified official public *source* repository, so its URL is `-` rather than its website or installer script. The repo field is transported alongside application versions through the existing private bulk handoff and is validated before inclusion in final structured records; host, skipped and blocked targets stay `-`. No live network calls, CT mutations, updater execution, dynamic GitHub inference or separate reporting model were introduced. F225 renders this full URL in the Changelog column; F223 does not render a table.
- [x] **F224 — Actionable target result details.** Extend the authoritative F220 `result_target` model with `failed_stage`, `recovery` and percent-escaped UTF-8 `result_detail` for the F225 Result column. `OK`, intentional `SKIPPED` reasons and preflight/host-blocked `NOT RUN` results have human-readable descriptions. Mandatory failures show `ERROR: <actual failed stage> (exit <original code>)`, plus a bounded, chronologically ordered selection of up to 12 **literal diagnostic lines from the failed stage only** when present in its sanitized log (the first four and last eight if there are more). Preserve verbatim diagnostic lines in multiline npm/APT/Community Scripts excerpts (deduplicating only generic severity prefixes in single-line summaries), and explicitly mark omitted/truncated lines; without reliable diagnostic evidence, report only stage and exit code. Do not infer a root cause or propose fixes. Recovery is independently reported as `success`, `failed:<exit>`, `disabled` or `unavailable` and cannot replace the original update failure. Nonfatal held-package, fstrim and reboot-indicator warnings, plus failure to restore an originally stopped guest, are preserved as warnings rather than misleadingly converting successes into failures. An isolated escaped private-file handoff carries the detail/stage/recovery from nested host/LXC updates to the existing bulk record, preserving all old fields, target selection, backup/rollback behaviour, stage execution counts, logging, technical exit codes and one-record-per-target policy. F225 table formatting is separate; F224 only records the actual text it will display. Tests cover status/reason descriptions, explicit/fallback error provenance, warning/success separation, recovery success/failure, hostile/multiline diagnostics, preflight blockers and mixed bulk outcomes.
- [x] **F225 — Rich final console table (F147 extension).** Render **VMID | Name | APT | Application version | Changelog | Result**, followed by accurate totals, for host-only, explicit individual-LXC, LXC-only bulk and combined bulk updates. Show outcomes in readable colour when the output supports it, but preserve legibility without ANSI colour. Keep result descriptions readable even if names/URLs are long; show repository URLs as usable plain links in the console. The table must use F220–F224's collected data as its single source of truth, appear exactly once at completion (including partial/failing runs and preflight blockers), and not replace/alter technical exit codes. Preserve existing F147 behaviour until this richer view is ready. **Implementation in PR #25:** a read-only Python renderer consumes the same F220–F224 `result_target` lines emitted by single host/LXC and bulk orchestrators, after the existing structured records; prints one final six-field table with per-row details and factual totals. Uses full repository URLs, actual version deltas, escaped diagnostic decoding with terminal-control sanitization, TTY colour/plain fallback and narrow-terminal continuation lines. Existing F147 summaries, logs and exit codes are retained. **Accepted 2026-10-13:** the F226 automated matrix covers successful, failed, partial, skipped, blocked, empty and non-interactive results (including F157 consistency), and a read-only synthetic mixed-result check was confirmed on the actual Proxmox host. Colour handling remains covered by automated TTY/NO_COLOR tests, not by the pasted terminal capture.

> **Implementation order:** F220 → F221 → F222 → F223 → F224 → F225 → F157 (derive the global SUCCESS/FAILED/PARTIAL result from the finalized per-target table) → F159 (reuse the same recorded failure facts for notifications) → F153/F154 (email delivery and policy). F157 must reuse the F220–F225 result model; do not introduce independent aggregation or notification-only result logic.

- [x] **F150** Configurable log/history retention. Current `LOG_KEEP` retention applies to timestamped per-LXC logs.
- [x] **F151** Distinguish warnings from errors.
- [x] **F152** Audit what was attempted and its result.

## O. Notifications

- [x] **F153** Email notifications. `EMAIL_NOTIFICATIONS=false` by default; opt in with a local `forge.conf` override. The final-result owner invokes a separate best-effort mail helper once per completed host, LXC, or bulk run, using the **same F225/F157/F159 authoritative records**, rather than collecting results again. Messages are addressed to the Proxmox host's local `root` mailbox via `sendmail` so the existing Proxmox `system-mail` notification routing and `root@pam` recipient configuration apply. Neither SMTP credentials, mail recipients, notification matchers nor templates are managed by Forge. The email contains the global status, complete plain-text final table and failed/blocked-target causes. Missing/unavailable mail transport is reported as a warning and never changes updater execution, recovery or exit code. Unit/integration tests use mocked mail delivery; **real inbox delivery remains unverified until mail is explicitly enabled and tested.**
- [x] **F154** Notify only on errors. `NOTIFY_ONLY_ERRORS=true` by default; with F153 enabled, send only for global `FAILED` or `PARTIAL` derived by F157 (including blocked eligible targets). Intentional `SKIPPED` targets and warning-only `OK` outcomes do not trigger mail. Setting this option to `false` also sends `SUCCESS`, including empty/all-skipped runs. F153's disabled default takes precedence. Fake-sendmail tests cover both defaults, all four flag combinations, host/LXC/bulk, success, failure, preflight blocking, and transport errors.
- [x] **F157** Final consolidated SUCCESS/FAILED/PARTIAL result derived exclusively from the same authoritative host/LXC records used by F225, including zero-selected/all-skipped, fully failed and mixed outcomes. **Implementation:** the existing F225 renderer now derives the global status from its parsed `result_target` rows, prints a single `result_global` machine-readable record plus an `Overall result` label, and reuses those same row totals. `SUCCESS` means no `ERROR`/`NOT_RUN` (including no-selected/all-skipped); `FAILED` means one or more `ERROR`/`NOT_RUN` and zero `OK`; `PARTIAL` means both completed and failed/blocked targets exist. An intentional skip is not a failure. Existing F147 technical summaries and exit codes are unchanged; no notification renderer, separate collector or email delivery is added. **Accepted 2026-10-13:** F226 validates the global status against the very same F225 rows for individual host/LXC, bulk, mixed, failed, blocked, skipped and empty cases.
- [x] **F159** Summary with failed targets and causes. The existing F225/F157 renderer now adds a single `Failed and blocked targets (N)` digest only when authoritative `result_target` rows contain `ERROR` or `NOT_RUN`. It identifies each affected host/VMID and exact name, distinguishes actual failure from targets not attempted, and presents the same authoritative F224 content as the Result column, with each original diagnostic line on a separate safely prefixed line: confirmed failing stage, original exit code, explicit error output when available, independent recovery outcome or actual blocking reason. It never invents causes, counts intentional `SKIPPED`/warning-only `OK` targets as failures, or collects results again. The F226 matrix and dedicated F159 tests cover mixed/multiple host/guest errors, recovery success/failure, preflight blocks, no-failure cases, control injection, long diagnostics, plain/colour output and unchanged exit/selection semantics. No email is sent; F153/F154 are separate.

## Q. Configuration

- [x] **F170** One coherent configuration model/schema.
- [x] **F171** Explicit defaults.
- [x] **F172** Global configuration.
- [x] **F176** Validate the complete configuration before execution.
- [x] **F177** Defined policy for unknown/invalid configuration values.
- [x] **F179** Preserve custom configuration across upgrades.
- [x] **F180** Print the effective configuration. `forge show-config` validates and prints the merged defaults/overrides in stable sorted order, with per-key origin, Bash-safe quoting and redaction of sensitive-looking keys. It does not query Proxmox or mutate state. Regression tests cover real CLI dispatch, precedence, origins, invalid values and output safety.
- [x] **F181** Validate configuration without updating anything.

> Configuration is now layered like a defaults/local model: versioned `forge.conf.default` is always loaded first and optional Git-ignored `forge.conf` is loaded afterwards as host-local overrides. Duplicate keys inside one file and unknown keys are errors.

## R. Extensibility and architecture

- [x] **F184** Local transport.
- [x] **F185** `pct` transport.
- [ ] **F187** QGA transport.
- [x] **F190** Hooks/plugins without modifying the core. Current implementation is target-local `scripts.d/<VMID>/*.sh` execution.
- [x] **F194** Components testable in isolation.

## T. Tests and quality

- [x] **F206** Exit-code propagation tests. Eight automated test cases use the real stage-output capture and LXC OS/application/custom-script helpers with fake `pct` commands to verify success/failure exit codes (including controlled exit 42), stdout/stderr preservation, APT-stage failure isolation, and stopping subsequent custom scripts after failure. GitHub Actions runs them alongside F209/F213 without accessing Proxmox.
- [x] **F207** Tests proving each mutating operation executes only once. Eight automated cases exercise the real LXC update orchestrator with isolated helper fakes (single backup/OS/application/custom-script/health/fstrim stage, one backup restore attempt, failure short-circuit, backup-only recovery and no mutation when stages are disabled) and the real Proxmox host APT updater with a fake `apt-get` (each package stage once, no retry after failure). GitHub Actions verifies these paths without modifying host or guest systems.
- [x] **F209** Configuration tests. Twelve automated cases exercise the real defaults/local-override loader and validator (valid configuration, precedence, invalid syntax, duplicate/unknown/missing keys, booleans, paths and retention). GitHub Actions runs them and checks Bash syntax on pushes to `main` and pull requests, without contacting Proxmox.
- [x] **F211** Result aggregation tests. Automated cases exercise the real host/LXC bulk-update coordinator with isolated helper fakes: all-success, single/multiple/all guest failures, continued processing after a guest fails, authoritative host failure exit code with continued guest updates, host-then-guest partial failure, preflight blocking before mutation, empty/disabled scopes, mode-specific host exclusion, snapshot-incompatible fallback plan propagation and invalid target records. GitHub Actions verifies exit statuses, counts, ordering and final result reporting without accessing Proxmox.
- [x] **F213** Integration tests with mocks/fakes. Eleven automated integration cases exercise the real LXC recovery preflight and configuration loading against fake `pvesh`, `pct` and `hostname` commands: snapshot-supported vs. snapshot-incompatible guests, same-run `vzdump` fallback, existing snapshots, combined conflicts, policy opt-out, disabled backup, missing/ambiguous jobs, invalid retention, API failures and invalid rootfs. Unexpected/mutating Proxmox calls are rejected by the test doubles. These tests run in GitHub Actions alongside F209 without connecting to Proxmox.
- [x] **F214** End-to-end tests on real Proxmox for critical paths. Manually verified on live LXC 110: snapshot creation and preservation, `vzdump` backup, automatic `pct rollback` after a controlled custom-script failure (exit 42), removal of a post-snapshot filesystem marker, restoration of the original stopped state, and `keep-last=3` snapshot pruning. On October 12, 2026, live LXC 111 additionally verified snapshot-incompatible backup-only recovery: a same-run `vzdump` backup, controlled custom-script failure (exit 42), automatic `pct restore --force`, preserved external `mp0` bind-mount configuration, successful guest restart and health check, functional SnowShare web UI after restoration, and preservation of the original failure exit code.

> Live Proxmox validations include a combined host/LXC update, guest failure recovery, terminal output handling, APT maintenance, `pct fstrim` and an explicit update of an initially stopped LXC. On October 11, 2026, LXC 110 tests additionally verified persistent snapshots, rollback after a controlled failure, restored filesystem content, original lifecycle state and retention. F214 represents these manual end-to-end tests; repeatable automated tests remain pending.


- [x] **F226 — Exhaustive final-summary regression matrix (acceptance gate for F225/F157).** Automated tests must exercise the real aggregation and formatting boundaries with mocked external Proxmox/APT/application operations and assert **every row**, VMID ordering, reason, numeric count, version text, repository URL, colour/fallback, totals, and unchanged exit semantics. Cover all meaningful permutations and edge conditions, at minimum:
  - **Invocation and selection:** host-only; one running LXC; explicitly updated stopped LXC restored to stopped; LXC-only bulk; host+LXC bulk; zero LXCs; all running; mixed running/stopped; all stopped; templates; excluded by VMID/name; running scope disabled; host scope disabled; no selectable targets; explicit update of an otherwise excluded guest; missing/invalid inventory records; overlapping skip conditions; numeric sort (\`9, 10, 100\`) and exact names.
  - **Execution results:** every target succeeds; zero APT/app changes; one or multiple guest failures with subsequent guests continuing; all guests fail; host fails yet eligible guests continue; preflight blocks all mutations; partially successful host+guest run; host success but every guest fails; target failure followed by successful or failed rollback; recovery/cleanup failure that must not conceal the primary error; skipped vs eligible-but-not-run; disabled or absent OS/application stages; warning-only success versus authoritative error.
  - **APT facts:** zero, one or many upgrades; available-but-not-installed packages; newly installed/removals/autoremovals not counted as upgrades; held/kept-back packages not miscounted; failed APT refresh or upgrade; interrupted/partial upgrade; successful rollback undoing changes; unreliable measurement shown as \`—\`, not \`0\`; independently correct counts for host and each LXC.
  - **Application metadata:** unchanged known version shown alone; real \`old → new\`; updater succeeds with no version change; updater fails with/without version change; unknown/missing/unparseable version; no supported Community Scripts updater; official repository available with unchanged version; missing/ambiguous repository shown as \`—\`; no guessed GitHub URLs or Docker versions; version text and URLs with unexpected punctuation.
  - **Diagnosis and rendering:** correct stage, exit code and explicit failure message; no fabricated reason when no message is available; errors across multiple targets attributed correctly; distinct preflight/selection/rollback/cleanup reasons; normal skip reasons; totals and global SUCCESS/FAILED/PARTIAL consistent with rows; long names, long repository URLs and long/multiline diagnostics remain readable; no terminal escape injection; ANSI colour on supported terminals and clean plain text when redirected; exactly one final table on success/failure/preflight block and no duplicate nested summaries.
  - **Safety and regression:** collecting/presenting results must never add an update attempt, start skipped LXCs, alter snapshot/restore policy, change selected targets, mask an exit code, or break existing CLI/log output. Run tests in CI; perform only minimal representative live read-only checks where mocks cannot establish real Proxmox behaviour. A passing happy-path screenshot is **not** sufficient to mark F225/F157 complete.

> **Acceptance verified 2026-10-13:** F225/F157/F226 were closed after the F226 regression matrix and related integration tests passed in GitHub Actions (276 tests on `main`, commit `2e4b3d0`), and a safe live-host read-only demonstration confirmed the complete mixed-result table and global `PARTIAL` output. The simulated check did **not** execute an update or prove real-world mutation; mutating scenarios are covered by the CI test doubles. Further defects discovered later must receive regression coverage.

## U. Post-update maintenance and terminal behaviour

- [x] **F215** Run `apt-get -y autoremove` after successful APT package upgrades on the Proxmox host and APT-based LXCs, preserving the real failure result if autoremove fails.
- [x] **F216** Run `pct fstrim <VMID>` as explicit post-update maintenance for successfully updated LXCs. A trim failure is reported as a warning and does not trigger destructive rollback of an otherwise successful update.
- [x] **F217** Preserve native terminal colours, formatting and carriage-return progress while preventing producer `CSI 3 J` sequences from deleting Forge's existing terminal scrollback.
- [x] **F218** Retain Forge-created Proxmox host configuration backups for 14 days after validating each new archive.
- [x] **F219** Allow host-local additional paths to be appended to the fixed Proxmox host configuration backup set through `HOST_BACKUP_EXTRA_PATHS`, without replacing the mandatory base paths.

## V. Future comparison candidates (not yet approved for implementation)

The proposals below were identified from Ultimate Updater and Proxmox VE Community Scripts comparisons on 2026-10-15. They are **unimplemented candidates**, not amendments to the initial scope or authorisation to implement them. Review each independently for value, safety, dependencies and maintenance cost. The established update-only scope remains unchanged: no standalone pending-update discovery or independent check/update selection workflows.

### Visibility, discovery and policy

- [ ] **F231 — Optional Proxmox tag selection.** Add explicit, deterministic tag-based groups for eligible update/check targets without changing existing VMID/name exclusions, implicitly selecting stopped LXCs or making ambiguous matching acceptable.

### Execution and target compatibility

- [ ] **F232 — Additional verified Linux package-manager adapters.** Evaluate APK, DNF/YUM and Pacman one target family at a time; implement only with verified preflight, error semantics, upgrade handling and regression tests. F054 currently detects APT only and must not be reinterpreted as broad support.
- [ ] **F233 — SSH transport for supported VMs.** Offer key-based SSH when QGA is unavailable or unsuitable, building on F003/F187. Validate target identity, host keys, privileges, operating system and lifecycle; do not use an unverified command path or silently bypass recovery requirements.
- [ ] **F235 — Explicit controlled reboot action.** Extend F094's reporting with a separately requested host/guest reboot where safe, preserving maintenance-window and lifecycle constraints. Never turn update completion into an automatic host reboot by default.
- [ ] **F236 — FreeBSD/pfSense guest update adapter.** Separately evaluate `pkg`-based updates for verified supported VM guests, including transport, OS/version detection, privilege boundaries, backup guarantees and exact failure reporting; do not reuse Linux/APT assumptions or imply that an independent external FreeBSD server is already supported.

### Operational management and expansion

- [ ] **F237 — Per-job notification policies.** Extend F153/F154 using the existing Proxmox mail routing and authoritative result model: configurable messages for scheduled runs, errors, and optional security/update digests when those data are available; no duplicate SMTP configuration or independent result aggregator.
- [x] **F238 — Safe Forge self-update.** `forge update self-update [BRANCH]` updates the agreed Forge checkout from the configured remote (default branch `main`; an explicitly named branch can be selected only when its tip contains the current checked-out commit). The helper verifies the checkout root, an approved `ragnarlotus/proxmox-forge` remote URL (including the existing `github-proxmox-forge` SSH alias), a clean tracked/untracked worktree, valid branch names and a strictly fast-forward history before mutation. It fetches the requested branch, retains local ignored `forge.conf`, rejects unexpected/divergent/older commits, verifies the final revision and runs under Forge's existing global lock. `CHECK_FORGE_UPDATES_BEFORE_UPDATE=false` by default; when explicitly enabled in local `forge.conf`, **manual interactive** host/LXC/`update all` runs check for newer `main` and ask to update, skip or cancel *before* any update stage. Accepting updates Forge and re-executes the original command under the same inherited lock, avoiding updates of Forge while a system update is active; the next CLI loads its new code/configuration. No prompt or Forge update happens in scheduled or noninteractive runs. Network/check failure is reported and an ordinary manual update may proceed with the current Forge version. Isolated real-Git tests cover tracked changes, ignored config, clean FF, explicit branch, divergence, unapproved source, and terminal cancellation/acceptance. Live Proxmox acceptance remains to be verified.
- [ ] **F239 — Optional authenticated Web UI.** Consider target inventory, manual execution, retained job logs/status and configuration over the same CLI/job engine, only after F131 and a stable status model. Do not expose a general shell or create an independent update/restore implementation; require Proxmox-appropriate authentication and authorisation.
- [ ] **F240 — Cluster-aware orchestration.** Evaluate multi-node inventory and owner-node execution with remote identity checks, per-node recovery scope and conflict prevention. Do not apply single-node assumptions across Proxmox cluster boundaries.
- [ ] **F241 — External Linux host support.** Evaluate explicitly configured SSH targets outside Proxmox; verify target-specific privileges, updater and recovery/backup policy instead of pretending external hosts have LXC `vzdump` rollback.

### Distinctive reliability capabilities

- [ ] **F242 — Independent recoverability verification.** Optionally validate that a retained backup is actually restorable using isolated, non-production tests and recorded evidence. This is beyond F082's successful archive-creation check; never overwrite or restore a live production guest merely to test its backup.
- [ ] **F243 — Staged/canary updates.** Allow an explicitly selected trial target or group before continuing compatible targets, gated by real functional health results; preserve per-target backups, failure isolation and the original error state.
- [ ] **F244 — Declared service dependency ordering.** Consider explicit cross-target dependencies for sequential maintenance, with cycle/conflict detection and health-based gating. Never auto-start excluded/stopped guests or silently expand the selected update scope.

> **Roadmap cleanup (2026-10-16; documented 2026-10-18):** F227, F230 and F245 were rejected, not implemented or postponed. Their original proposals and rejection reasons are retained in the historical decision register below. Historical IDs are not reused; all remaining candidates are unapproved.

> **Deduplication:** the original proposal to connect outcomes to their recovery backup is covered by F083/F141/F220–F225 and extended under the now-implemented F228; actionable failure diagnostics already exist under F224/F159, so neither received another feature ID. Previously listed F003, F069, F121, F131, F146 and F187 remain unchanged. F068 remains explicitly discarded.

## W. Prioritisation and scope notes (2026-10-18)

These notes document current intent only; they do not mark capabilities implemented or approve previously unapproved candidates.

- **F234 — Implemented:** configurable opt-in resource floors for all LXC update paths, with guarded restoration and a deliberate default of no resource adjustments. See section F.
- **F238 — Implemented:** `forge update self-update [BRANCH]` and default-off `CHECK_FORGE_UPDATES_BEFORE_UPDATE`. The pre-update prompt is limited to interactive manual runs, and the original command is restarted under the retained lock after successful self-update.
- **F231 — Under consideration:** Proxmox tags may be read automatically but must never silently change target selection; selecting a tag-based scope or policy must be explicitly authorised. No concrete selection policy has been approved.
- **F232 — Low current priority:** additional package managers are interesting, but existing running LXC workloads use APT.
- **F243 — Low current priority:** staged/canary gates require meaningful functional verification; existing serial failure isolation is not a canary policy.
- **F244 — Important, deferred:** do not infer an update dependency order automatically or equate boot/shutdown ordering with the correct update order. The desired use of Proxmox startup-order data needs further clarification; **no new F244 design was agreed**.
- **VMs, external targets, clusters and Web UI:** expand only after the primary single-host Proxmox/LXC backend is dependable; a Web UI must reuse that backend.

## X. Rejected proposals — historical decision register

**Rejected is not the same as postponed or implemented.** These entries preserve the idea and the reason it was rejected so that a future contributor can challenge the rationale with new evidence. They are outside the active backlog; IDs remain reserved. The original historical wording is retained or summarised without reinstating incompatible scope.

- ~~**F229 — Verified security versus ordinary update counts.**~~ **REJECTED (2026-10-18).** Classify actual APT upgrades by reliably attributable security versus ordinary origins (unknown when unverifiable). **Reason:** Forge already applies eligible APT updates regardless of this classification; the extra split does not change selection, execution, recovery or update outcome, and the user does not need the additional reporting. F221's count of actually upgraded packages remains.
- ~~**F227 — Standalone read-only update check.**~~ **REJECTED (2026-10-16).** Proposed `forge check` to discover pending host/LXC/application updates without installing them. **Reason:** explicitly conflicts with Forge's update-only purpose; displaying available updates is not part of the supported workflow.
- ~~**F230 — Independent check/update selection policies.**~~ **REJECTED (2026-10-16).** Proposed separate read-only-check and mutating-update target selection. **Reason:** depended on F227, which was rejected; a second selection model has no purpose without a standalone check workflow.
- ~~**F245 — Reproducible run context audit.**~~ **REJECTED (2026-10-16).** Proposed recording executing Forge Git commit/version and an effective-configuration/policy fingerprint or provenance alongside run history. **Reason:** insufficient incremental operational value compared with existing per-run logs, configuration validation and results, relative to its maintenance complexity.
- ~~**F013 — Refresh repository metadata before checking.**~~ **REJECTED (roadmap scope cleanup, 2026-10-14).** A standalone check/preflight refresh is outside scope; APT already refreshes metadata during actual updates.
- ~~**F014 — Detect pending updates without installing.**~~ **REJECTED (roadmap scope cleanup, 2026-10-14).** Standalone availability discovery is outside Forge's update-only scope.
- ~~**F015 — Count pending updates per target.**~~ **REJECTED (roadmap scope cleanup, 2026-10-14).** Requires the rejected standalone discovery; F221 reports *actually installed* upgrades instead.
- ~~**F016 — List affected packages before updating.**~~ **REJECTED (roadmap scope cleanup, 2026-10-14).** Pre-execution package preview is outside the agreed scope.
- ~~**F017 — Display installed → candidate package versions before updating.**~~ **REJECTED (roadmap scope cleanup, 2026-10-14).** Pre-execution candidate-version preview is outside the agreed scope; this does not prohibit diagnostics of held packages (F022).
- ~~**F018 — Distinguish security updates in pre-update discovery.**~~ **REJECTED (roadmap scope cleanup, 2026-10-14).** Depended on the eliminated standalone check workflow; a distinct post-update security classification was later proposed as F229 and separately rejected.
- ~~**F023 — Completely read-only preview/check mode.**~~ **REJECTED (roadmap scope cleanup, 2026-10-14).** Incompatible with the update-only product scope, as later reiterated for F227.
- ~~**F024 — Generate an exact update plan before execution.**~~ **REJECTED (roadmap scope cleanup, 2026-10-14).** A pre-execution update-plan preview is outside scope; deterministic scope resolution and safety preflights remain mandatory.

**Already retained elsewhere:** F068 is explicitly marked rejected in section G. The large early brainstorming inventory was pruned on 2026-10-11 because it mixed speculative, duplicated and unrelated platform features; those unscreened ideas were not individually approved/rejected product decisions. Several were subsequently reintroduced as distinct F229–F244 candidates. This register records actual scope/rejection decisions, rather than treating every historical brainstorming omission as a rejected requirement.

---

# Product capability model

Forge is organised conceptually around five major capabilities:

- [x] **DISCOVER** — determine which update targets exist. Current implementation covers the local Proxmox host and LXCs.
- [x] **PROTECT** — run preflight checks and establish a recovery point/state before mutation.
- [x] **EXECUTE** — perform the update exactly once using the correct mechanism.
- [x] **VERIFY** — determine the technical and functional result after the change.
- [x] **REPORT** — report exactly what happened, including every relevant failure.

Two cross-cutting foundations support all five:

- [x] **CONFIGURATION** — defines Forge behaviour explicitly.
- [x] **RESULT MODEL** — preserves reality across layers so a failure cannot silently become success.