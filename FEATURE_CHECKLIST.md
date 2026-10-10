# Forge — Feature Checklist

Tracking document for the capabilities identified during the initial requirements survey.

This is a catalogue, not a commitment to implement every item. Items stay here even when they are outside the initial scope so they can be evaluated later.

Implemented means the capability exists in the current `main` branch at the scope described. Partial plumbing, collected-but-unused data, or behaviour that only happens incidentally is not marked as implemented.

## Status

- [ ] Not implemented
- [x] Implemented

## Initial scope constraints

These are agreed behavioural requirements for the initial implementation. They do not remove broader capabilities from the catalogue below.

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
- [ ] **F004** Discover Proxmox cluster nodes.
- [ ] **F005** Manage external hosts over SSH.
- [x] **F006** Detect target state: running, stopped, template, etc.
- [x] **F007** Detect target OS, distribution and version.
- [ ] **F008** Detect available transport: local, `pct`, QGA, SSH.
- [ ] **F009** Inventory installed packages.
- [x] **F010** Inventory available application/special updater mechanisms.
- [ ] **F011** Support target tags/groups.
- [ ] **F012** Optional persistent inventory in addition to dynamic discovery.

## B. Update discovery

- [ ] **F013** Refresh package repository metadata before checking.
- [ ] **F014** Detect available updates without installing them.
- [ ] **F015** Report the number of available updates per target.
- [ ] **F016** Report the exact list of affected packages.
- [ ] **F017** Report installed version → candidate version.
- [ ] **F018** Distinguish security updates.
- [ ] **F019** Distinguish bugfix/enhancement updates where supported.
- [ ] **F020** Show package changelog/advisory information where available.
- [ ] **F021** Associate CVE/advisory information where reliable data exists.
- [ ] **F022** Detect held packages.
- [ ] **F023** Provide a completely read-only preview/check mode.
- [ ] **F024** Generate an exact update plan before execution.

## C. Selection and policies

- [ ] **F025** `ONLY` selection by ID/name.
- [ ] **F026** `EXCLUDE` selection by ID/name.
- [ ] **F027** Include/exclude using tags.
- [ ] **F028** Filter by target type: host/LXC/VM/external.
- [x] **F029** Filter automatic LXC scope by running state. `UPDATE_RUNNING_LXC` controls inclusion of currently running LXCs; stopped LXCs are never selected automatically.
- [x] **F030** Skip templates automatically.
- [ ] **F031** Separate filters for CHECK and UPDATE.
- [ ] **F032** Select individual packages.
- [ ] **F033** Exclude individual packages.
- [ ] **F034** Security-only policy.
- [ ] **F035** Policies by target/group/tag.
- [ ] **F036** Per-target policy overrides.

## D. Execution modes

- [x] **F037** Interactive/manual execution mode.
- [ ] **F038** Persistently configurable automatic/non-interactive mode.
- [ ] **F039** Native terminal behaviour and real prompts in interactive mode.
- [x] **F040** No prompts in automatic mode.
- [x] **F041** Execute each mutating operation exactly once.
- [x] **F042** Deterministic output capture in automatic mode.
- [ ] **F043** Global execution mode configuration.
- [ ] **F044** Temporary execution-mode override from CLI.
- [ ] **F045** Allow execution behaviour to vary by operation class where required.

## E. Operating systems and package managers

- [x] **F046** Debian/Ubuntu updates through APT.
- [ ] **F047** Fedora/RHEL/Rocky/Alma updates through DNF/YUM.
- [ ] **F048** Arch updates through Pacman.
- [ ] **F049** Alpine updates through APK.
- [ ] **F050** Devuan support.
- [ ] **F051** Mint/Kali/Neon and other Debian derivatives.
- [ ] **F052** FreeBSD updates through `pkg`.
- [ ] **F053** Extensible/future Windows Update support.
- [x] **F054** Automatically detect the supported update strategy.
- [ ] **F055** Configurable package-manager-specific arguments.

> The current LXC update scope is APT-only. F054 currently means detecting APT as supported and rejecting any unsupported package manager; it does not imply that DNF/YUM, Pacman or APK adapters exist.

## F. Application updates and custom scripts

- [x] **F056** Update applications installed through Proxmox Community Scripts.
- [x] **F057** Detect `/usr/bin/update` or another known application updater.
- [ ] **F058** Application-specific updater adapters/plugins.
- [x] **F059** Per-target custom scripts.
- [ ] **F060** Global custom scripts.
- [ ] **F061** Pre-update hooks.
- [ ] **F062** Post-update hooks.
- [x] **F063** Every plugin/script returns an authoritative result.

## G. Preflight

- [ ] **F064** Check free filesystem space.
- [ ] **F065** Estimate/check space required for the update.
- [ ] **F066** Check available memory.
- [ ] **F067** Check CPU/resources when an application updater requires them.
- [ ] **F068** Check real LVM-thin `Data%` / `Meta%` usage.
- [ ] **F069** Check storage required for snapshots/backups.
- [ ] **F070** Verify repositories are valid and reachable.
- [x] **F071** Detect package-manager locks/conflicting processes.
- [ ] **F072** Verify required network connectivity.
- [ ] **F073** Verify QGA/SSH/`pct` transport before mutation.
- [ ] **F074** Custom preflight hook support.
- [x] **F075** A failed mandatory preflight blocks the update.

> Forge currently collects root free-space and available-memory values during LXC inspection, but they are not yet policy-enforced preflight checks; therefore F064/F066 remain unchecked.

## H. Snapshot, backup and rollback

- [ ] **F076** Optional pre-update snapshot.
- [x] **F077** Optional pre-update backup.
- [x] **F078** Require snapshot/backup according to policy.
- [x] **F079** Select backup storage. Current implementation derives it from the authoritative Proxmox backup configuration instead of maintaining a second Forge storage policy.
- [x] **F080** Support applicable backup modes: snapshot/suspend/stop. Current LXC backup execution inherits supported options from the applicable Proxmox backup job.
- [ ] **F081** Fallback from snapshot to backup when snapshot is not viable.
- [x] **F082** Verify snapshot/backup actually completed successfully.
- [x] **F083** Record the exact recovery artifact identifier.
- [ ] **F084** Verify age/freshness of an existing backup.
- [ ] **F085** Manual rollback.
- [x] **F086** Configurable automatic rollback after failure.
- [ ] **F087** Retention/cleanup policy for snapshots created by Forge.
- [x] **F088** Never remove the recovery artifact before the final result is known.

> Guest rollback capabilities do not apply to the Proxmox host itself.
>
> Forge does not currently create `Update_*` snapshots. LXC recovery uses `vzdump` and Proxmox remains authoritative for the applicable job's storage, mode and retention/prune options.

## I. Guest lifecycle

- [x] **F089** Detect original guest state.
- [x] **F090** Temporarily start an explicitly selected stopped LXC for its update; automatic bulk-update scope never starts stopped guests.
- [x] **F091** Wait for readiness after temporary startup — only when an explicitly selected LXC was initially stopped and Forge starts it, retry a minimal `pct exec` readiness probe for up to 30 seconds before requirements/update stages; LXCs that were already running skip this phase.
- [x] **F092** Update the guest.
- [x] **F093** Restore an explicitly selected originally-stopped LXC to stopped state after the update attempt, including after eligible failure/recovery paths.
- [ ] **F094** Detect reboot-required state.
- [ ] **F095** Configurable reboot behaviour.
- [ ] **F096** Restart services instead of rebooting when sufficient.
- [ ] **F097** Wait for readiness after reboot.

## J. Health and recovery

- [ ] **F098** Capture a health baseline before mutation.
- [x] **F099** Run health checks after updating.
- [x] **F100** Check relevant systemd services.
- [ ] **F101** Configurable functional health checks.
- [ ] **F102** Compare pre-update and post-update health.
- [ ] **F103** Structured health states such as healthy/degraded/unverified/failed.
- [ ] **F104** Bounded retries when a service needs time to become ready.
- [ ] **F105** Configurable recovery action.
- [x] **F106** Roll back when a mandatory health check does not recover.
- [ ] **F107** Verify health again after rollback.

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
- [ ] **F117** Explicit timeouts.
- [ ] **F118** Retries only for operations that are safe to repeat.
- [x] **F119** Structured result per step, target and run.

## L. Scheduling and orchestration

- [x] **F120** Immediate manual execution.
- [ ] **F121** Scheduling through systemd timers.
- [ ] **F122** Daily/weekly/custom schedules.
- [ ] **F123** Schedule by target/group.
- [ ] **F124** Maintenance windows.
- [ ] **F125** Stagger/jitter to avoid updating everything simultaneously.
- [ ] **F126** Canary/pilot group before production rollout.
- [x] **F127** Serial updates.
- [ ] **F128** Configurable limited parallelism.
- [x] **F129** Global lock for incompatible simultaneous runs. Forge currently uses a stricter single-run policy: every `forge` invocation acquires one global non-blocking lock, so a second Forge execution is rejected until the first exits. The standalone PVE restore utility participates in the same lock.
- [ ] **F130** Per-target locking.
- [ ] **F131** Jobs survive SSH/session disconnection.
- [ ] **F132** History of scheduled runs.

> The current concurrency policy deliberately serializes the whole Forge CLI rather than individual targets. All `lib/**/*.sh` components are internal and require the runtime context inherited from `forge`; the only independent exception is `lib/backup/host/restore.sh`, which acquires the same global lock and creates that context itself for disaster recovery. Per-target locks are therefore not required by the current execution model.

## M. Content lifecycle and version safety

- [ ] **F133** Version pinning.
- [ ] **F134** Custom repositories/mirrors.
- [ ] **F135** Repository snapshots.
- [ ] **F136** Dev → Test → Production promotion.
- [ ] **F137** Update only to previously approved versions.
- [ ] **F138** Target a specific advisory/CVE.
- [ ] **F139** Globally exclude a problematic package/version.
- [ ] **F140** Ring-based rollout.

## N. Logging, history and reporting

- [ ] **F141** General log per run.
- [x] **F142** Independent log per target.
- [ ] **F143** Independent log per step.
- [x] **F144** Precise timestamps.
- [x] **F145** Persist exit codes.
- [ ] **F146** Record duration per step/target/run.
- [ ] **F147** Human-readable final summary.
- [ ] **F148** Structured JSON result.
- [ ] **F149** Queryable execution history.
- [x] **F150** Configurable log/history retention. Current `LOG_KEEP` retention applies to timestamped per-LXC logs.
- [x] **F151** Distinguish warnings from errors.
- [x] **F152** Audit what was attempted and its result.

## O. Notifications

- [ ] **F153** Email notifications.
- [ ] **F154** Notify only on errors.
- [ ] **F155** Notify only about security updates.
- [ ] **F156** Notify when updates are available without installing them.
- [ ] **F157** Final success/failure/partial notification.
- [ ] **F158** Future webhook/notification extensions.
- [ ] **F159** Summary with failed targets and causes.

## P. Security and access

- [ ] **F160** Dedicated SSH identity for Forge.
- [ ] **F161** SSH `BatchMode` for automation.
- [ ] **F162** SSH timeouts.
- [ ] **F163** Configurable known-host verification without silent insecure defaults.
- [ ] **F164** Minimum privileges where practical.
- [ ] **F165** Separate credentials from non-secret configuration.
- [ ] **F166** Verify downloaded scripts/artifacts.
- [ ] **F167** Avoid executing unvalidated downloaded remote code where possible.
- [ ] **F168** Audit privileged actions.
- [ ] **F169** RBAC only if Forge ever becomes multi-user.

## Q. Configuration

- [x] **F170** One coherent configuration model/schema.
- [x] **F171** Explicit defaults.
- [x] **F172** Global configuration.
- [ ] **F173** Overrides by group/tag.
- [ ] **F174** Per-target overrides.
- [ ] **F175** Temporary CLI overrides.
- [x] **F176** Validate the complete configuration before execution.
- [x] **F177** Defined policy for unknown/invalid configuration values.
- [ ] **F178** Configuration migration between versions.
- [x] **F179** Preserve custom configuration across upgrades.
- [ ] **F180** Print the effective configuration.
- [x] **F181** Validate configuration without updating anything.
- [ ] **F182** Keep behaviour in configuration rather than scattered hard-coded exceptions.

> Configuration is now layered like a defaults/local model: versioned `forge.conf.default` is always loaded first and optional Git-ignored `forge.conf` is loaded afterwards as host-local overrides. Duplicate keys inside one file and unknown keys are errors.

## R. Extensibility and architecture

- [ ] **F183** Core/orchestrator independent from transports.
- [x] **F184** Local transport.
- [x] **F185** `pct` transport.
- [ ] **F186** SSH transport.
- [ ] **F187** QGA transport.
- [ ] **F188** Package-manager adapters.
- [ ] **F189** Application updater adapters.
- [x] **F190** Hooks/plugins without modifying the core. Current implementation is target-local `scripts.d/<VMID>/*.sh` execution.
- [ ] **F191** Common result model independent of transport/updater.
- [ ] **F192** Capability detection instead of scattered hard-coded branches.
- [ ] **F193** Idempotency where applicable.
- [x] **F194** Components testable in isolation.
- [x] **F195** No dependency on a Web UI.
- [ ] **F196** Any future UI consumes the same core/API/CLI instead of redefining execution.

## S. Forge self-management

- [ ] **F197** Report Forge version.
- [ ] **F198** Check for a newer Forge version.
- [ ] **F199** Controlled self-update.
- [ ] **F200** Stable/development channels if ever required.
- [ ] **F201** Validate a new Forge version before replacing the current version.
- [ ] **F202** Preserve configuration and data during Forge updates.
- [ ] **F203** Roll back Forge itself if its own update fails.

## T. Tests and quality

- [ ] **F204** Unit tests for adapters.
- [ ] **F205** Transport tests.
- [ ] **F206** Exit-code propagation tests.
- [ ] **F207** Tests proving each mutating operation executes only once.
- [ ] **F208** Package-manager parsing tests.
- [ ] **F209** Configuration tests.
- [ ] **F210** Configuration migration tests.
- [ ] **F211** Result aggregation tests.
- [ ] **F212** Golden-output regression tests where useful.
- [ ] **F213** Integration tests with mocks/fakes.
- [ ] **F214** End-to-end tests on real Proxmox for critical paths.

> The current critical path has been manually validated on a live Proxmox host, including a complete combined host/LXC update run (using the former `update-all` command), forced LXC health failure/recovery, output/CR sanitization, scrollback preservation, host `autoremove`, LXC `autoremove` dry-run, real `pct fstrim`, and an end-to-end explicit update of an initially stopped LXC that was temporarily started and returned to stopped state after success. These validations are not yet a repeatable automated test suite, so F204–F214 remain unchecked.

## U. Post-update maintenance and terminal behaviour

These capabilities were added after the original requirements survey and therefore start at F215.

- [x] **F215** Run `apt-get -y autoremove` after successful APT package upgrades on the Proxmox host and APT-based LXCs, preserving the real failure result if autoremove fails.
- [x] **F216** Run `pct fstrim <VMID>` as explicit post-update maintenance for successfully updated LXCs. A trim failure is reported as a warning and does not trigger destructive rollback of an otherwise successful update.
- [x] **F217** Preserve native terminal colours, formatting and carriage-return progress while preventing producer `CSI 3 J` sequences from deleting Forge's existing terminal scrollback.
- [x] **F218** Retain Forge-created Proxmox host configuration backups for 14 days after validating each new archive.
- [x] **F219** Allow host-local additional paths to be appended to the fixed Proxmox host configuration backup set through `HOST_BACKUP_EXTRA_PATHS`, without replacing the mandatory base paths.

---

# Migration / replacement requirement

- [ ] **Ultimate Updater replacement** — when Forge is ready to replace the currently installed updater, remove Ultimate Updater completely: its installed files, services/timers/jobs, configuration, generated state/log artifacts and any other components installed specifically for Ultimate Updater. The cleanup must first distinguish Ultimate Updater-owned files from user-owned custom scripts/configuration that need to be migrated or preserved by Forge.

---

# Product capability model

Forge is organised conceptually around six major capabilities:

- [x] **DISCOVER** — determine which systems exist and what needs updating. Current implementation covers the local Proxmox host and LXCs.
- [ ] **PLAN** — determine exactly what will be done and under which policy.
- [x] **PROTECT** — run preflight checks and establish a recovery point/state before mutation.
- [x] **EXECUTE** — perform the update exactly once using the correct mechanism.
- [x] **VERIFY** — determine the technical and functional result after the change.
- [x] **REPORT** — report exactly what happened, including every relevant failure.

Two cross-cutting foundations support all six:

- [x] **CONFIGURATION** — defines Forge behaviour explicitly.
- [x] **RESULT MODEL** — preserves reality across layers so a failure cannot silently become success.