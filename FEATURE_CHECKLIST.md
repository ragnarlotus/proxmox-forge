# Forge — Feature Checklist

Practical capability checklist for Forge's Proxmox host and LXC updater, plus a small set of relevant future improvements (including possible VM support).

Speculative features, duplicate entries, incompatible policies and unrelated platform/tooling proposals have been removed. Existing feature IDs are intentionally preserved for historical traceability, so gaps are expected. Unchecked items are candidates, not commitments.

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
- [x] **Initial invocation model** — no scheduler, background job, daemon or Web UI. Every initial-scope run starts from an explicit user invocation.

---

## A. Discovery and inventory

- [x] **F001** Detect the local Proxmox host automatically.
- [x] **F002** Discover all LXC containers.
- [ ] **F003** Discover all virtual machines.
- [x] **F006** Detect target state: running, stopped, template, etc.
- [x] **F007** Detect target OS, distribution and version.
- [x] **F010** Inventory available application/special updater mechanisms.

## B. Update discovery

- [ ] **F013** Refresh package repository metadata before checking.
- [ ] **F014** Detect available updates without installing them.
- [ ] **F015** Report the number of available updates per target.
- [ ] **F016** Report the exact list of affected packages.
- [ ] **F017** Report installed version → candidate version.
- [ ] **F018** Distinguish security updates.
- [ ] **F022** Detect held packages.
- [ ] **F023** Provide a completely read-only preview/check mode.
- [ ] **F024** Generate an exact update plan before execution.

## C. Selection and policies

- [ ] **F026** `EXCLUDE` selection by ID/name.
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

## G. Preflight

- [x] **F064** Check free filesystem space. `MIN_ROOT_FREE_MB` (default 1024 MiB) enforces free space on `/` for host/LXC updates. Bulk runs check all selected running LXCs before host/guest changes, and individual target requirements check before mutation.
- [x] **F066** Check available memory. Configurable `MIN_MEM_AVAILABLE_MB` (128 MiB by default) enforces a minimum `MemAvailable` for the Proxmox host and running LXCs; bulk operations check selected LXC memory before any host/guest mutation and individual target requirements recheck immediately before updates. Missing/invalid readings block mutation. The real inspection shell payload and preflight paths are covered by automated regression tests.
- [ ] **F068** Check real LVM-thin `Data%` / `Meta%` usage.
- [ ] **F069** Check storage required for snapshots/backups.
- [x] **F071** Detect package-manager locks/conflicting processes.
- [x] **F075** A failed mandatory preflight blocks the update.

> Root space (F064) and available memory (F066) are enforced preflight requirements. F068/F069 remain deferred as previously agreed.

## H. Snapshot, backup and rollback

- [x] **F077** Optional pre-update backup.
- [x] **F078** Require snapshot/backup according to policy.
- [x] **F079** Select backup storage. Current implementation derives it from the authoritative Proxmox backup configuration instead of maintaining a second Forge storage policy.
- [x] **F080** Support applicable backup modes: snapshot/suspend/stop. Current LXC backup execution inherits supported options from the applicable Proxmox backup job.
- [x] **F082** Verify snapshot/backup actually completed successfully.
- [x] **F083** Record the exact recovery artifact identifier.
- [x] **F086** Configurable automatic rollback after failure.
- [x] **F087** Retention/cleanup policy for snapshots created by Forge. Prunes only older `Update_*` LXC snapshots to the `keep-last` limit of the applicable Proxmox backup job, preserving manually named snapshots and retaining the new snapshot after success or rollback.
- [x] **F088** Never remove the recovery artifact before the final result is known.

> Guest rollback capabilities do not apply to the Proxmox host itself.
>
> By default, `BACKUP_WHEN_SNAPSHOT_NOT_POSIBLE=true` uses persistent `Update_*` snapshots and `pct rollback` where supported. Snapshot-incompatible LXCs may instead use their same-run `vzdump` backup, but only if the centralized preflight confirms an applicable backup job, backup creation is enabled, and no existing persistent snapshots would be destroyed. The advanced restore helper rechecks snapshots before any `pct restore --force`. Forge applies the job's `keep-last` value to its own `Update_*` snapshots; Proxmox backup pruning does not manage persistent snapshots. Setting `BACKUP_WHEN_SNAPSHOT_NOT_POSIBLE=false` disables the backup-only fallback and blocks snapshot-incompatible targets. Bulk preflight covers only selected running LXCs, excluding stopped containers.

## I. Guest lifecycle

- [x] **F089** Detect original guest state.
- [x] **F090** Temporarily start an explicitly selected stopped LXC for its update; automatic bulk-update scope never starts stopped guests.
- [x] **F091** Wait for readiness after temporary startup — only when an explicitly selected LXC was initially stopped and Forge starts it, retry a minimal `pct exec` readiness probe for up to 30 seconds before requirements/update stages; LXCs that were already running skip this phase.
- [x] **F092** Update the guest.
- [x] **F093** Restore an explicitly selected originally-stopped LXC to stopped state after the update attempt, including after eligible failure/recovery paths.
- [ ] **F094** Detect reboot-required state.

## J. Health and recovery

- [x] **F099** Run health checks after updating.
- [x] **F100** Check relevant systemd services.
- [ ] **F101** Configurable functional health checks.
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
- [ ] **F121** Scheduling through systemd timers.
- [x] **F127** Serial updates.
- [x] **F129** Global lock for incompatible simultaneous runs. Forge currently uses a stricter single-run policy: every `forge` invocation acquires one global non-blocking lock, so a second Forge execution is rejected until the first exits. The standalone PVE restore utility participates in the same lock.
- [ ] **F131** Jobs survive SSH/session disconnection.

> Forge serializes the whole CLI using one global lock. All `lib/**/*.sh` components are internal, except `lib/backup/host/restore.sh`, which acquires the same lock for disaster recovery.

## N. Logging, history and reporting

- [ ] **F141** General log per run.
- [x] **F142** Independent log per target.
- [x] **F144** Precise timestamps.
- [x] **F145** Persist exit codes.
- [ ] **F146** Record duration per step/target/run.
- [x] **F147** Human-readable final summary. The CLI prints a readable final outcome for individual host/LXC updates and bulk runs, including success/failure counts, failed LXC IDs and exit codes, host failures before guest updates, and disabled scopes; existing structured result lines, recovery behaviour and exit codes are unchanged.
- [x] **F150** Configurable log/history retention. Current `LOG_KEEP` retention applies to timestamped per-LXC logs.
- [x] **F151** Distinguish warnings from errors.
- [x] **F152** Audit what was attempted and its result.

## O. Notifications

- [ ] **F153** Email notifications.
- [ ] **F154** Notify only on errors.
- [ ] **F157** Final success/failure/partial notification.
- [ ] **F159** Summary with failed targets and causes.

## Q. Configuration

- [x] **F170** One coherent configuration model/schema.
- [x] **F171** Explicit defaults.
- [x] **F172** Global configuration.
- [x] **F176** Validate the complete configuration before execution.
- [x] **F177** Defined policy for unknown/invalid configuration values.
- [x] **F179** Preserve custom configuration across upgrades.
- [ ] **F180** Print the effective configuration.
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
- [x] **F207** Tests proving each mutating operation executes only once. Eight automated cases exercise the real LXC update orchestrator with isolated helper fakes (single backup/snapshot/OS/application/custom-script/health/fstrim stage, one recovery attempt, failure short-circuit, backup-only fallback and no mutation when stages are disabled) and the real Proxmox host APT updater with a fake `apt-get` (each package stage once, no retry after failure). GitHub Actions verifies these paths without modifying host or guest systems.
- [x] **F209** Configuration tests. Twelve automated cases exercise the real defaults/local-override loader and validator (valid configuration, precedence, invalid syntax, duplicate/unknown/missing keys, booleans, paths and retention). GitHub Actions runs them and checks Bash syntax on pushes to `main` and pull requests, without contacting Proxmox.
- [x] **F211** Result aggregation tests. Thirteen automated cases exercise the real host/LXC bulk-update coordinator with isolated helper fakes: all-success, single/multiple/all guest failures, continued processing after a guest fails, authoritative host failure exit code, host-then-guest partial failure, preflight blocking before mutation, empty/disabled scopes, mode-specific host exclusion, snapshot-incompatible fallback plan propagation and invalid target records. GitHub Actions verifies exit statuses, counts, ordering and final result reporting without accessing Proxmox.
- [x] **F213** Integration tests with mocks/fakes. Eleven automated integration cases exercise the real LXC recovery preflight and configuration loading against fake `pvesh`, `pct` and `hostname` commands: snapshot-supported vs. snapshot-incompatible guests, same-run `vzdump` fallback, existing snapshots, combined conflicts, policy opt-out, disabled backup, missing/ambiguous jobs, invalid retention, API failures and invalid rootfs. Unexpected/mutating Proxmox calls are rejected by the test doubles. These tests run in GitHub Actions alongside F209 without connecting to Proxmox.
- [x] **F214** End-to-end tests on real Proxmox for critical paths. Manually verified on live LXC 110: snapshot creation and preservation, `vzdump` backup, automatic `pct rollback` after a controlled custom-script failure (exit 42), removal of a post-snapshot filesystem marker, restoration of the original stopped state, and `keep-last=3` snapshot pruning. On October 12, 2026, live LXC 111 additionally verified snapshot-incompatible backup-only recovery: a same-run `vzdump` backup, controlled custom-script failure (exit 42), automatic `pct restore --force`, preserved external `mp0` bind-mount configuration, successful guest restart and health check, functional SnowShare web UI after restoration, and preservation of the original failure exit code.

> Live Proxmox validations include a combined host/LXC update, guest failure recovery, terminal output handling, APT maintenance, `pct fstrim` and an explicit update of an initially stopped LXC. On October 11, 2026, LXC 110 tests additionally verified persistent snapshots, rollback after a controlled failure, restored filesystem content, original lifecycle state and retention. F214 represents these manual end-to-end tests; repeatable automated tests remain pending.

## U. Post-update maintenance and terminal behaviour

- [x] **F215** Run `apt-get -y autoremove` after successful APT package upgrades on the Proxmox host and APT-based LXCs, preserving the real failure result if autoremove fails.
- [x] **F216** Run `pct fstrim <VMID>` as explicit post-update maintenance for successfully updated LXCs. A trim failure is reported as a warning and does not trigger destructive rollback of an otherwise successful update.
- [x] **F217** Preserve native terminal colours, formatting and carriage-return progress while preventing producer `CSI 3 J` sequences from deleting Forge's existing terminal scrollback.
- [x] **F218** Retain Forge-created Proxmox host configuration backups for 14 days after validating each new archive.
- [x] **F219** Allow host-local additional paths to be appended to the fixed Proxmox host configuration backup set through `HOST_BACKUP_EXTRA_PATHS`, without replacing the mandatory base paths.

---

# Product capability model

Forge is organised conceptually around six major capabilities:

- [x] **DISCOVER** — determine which update targets exist. Current implementation covers the local Proxmox host and LXCs.
- [ ] **PLAN** — determine exactly what will be done and under which policy.
- [x] **PROTECT** — run preflight checks and establish a recovery point/state before mutation.
- [x] **EXECUTE** — perform the update exactly once using the correct mechanism.
- [x] **VERIFY** — determine the technical and functional result after the change.
- [x] **REPORT** — report exactly what happened, including every relevant failure.

Two cross-cutting foundations support all six:

- [x] **CONFIGURATION** — defines Forge behaviour explicitly.
- [x] **RESULT MODEL** — preserves reality across layers so a failure cannot silently become success.