# Forge — Feature Checklist

Tracking document for the capabilities identified during the initial requirements survey.

This is a catalogue, not a commitment to implement every item. Items stay here even when they are outside the initial scope so they can be evaluated later.

## Status

- [ ] Not implemented
- [x] Implemented

---

## A. Discovery and inventory

- [ ] **F001** Detect the local Proxmox host automatically.
- [ ] **F002** Discover all LXC containers.
- [ ] **F003** Discover all virtual machines.
- [ ] **F004** Discover Proxmox cluster nodes.
- [ ] **F005** Manage external hosts over SSH.
- [ ] **F006** Detect target state: running, stopped, template, etc.
- [ ] **F007** Detect target OS, distribution and version.
- [ ] **F008** Detect available transport: local, `pct`, QGA, SSH.
- [ ] **F009** Inventory installed packages.
- [ ] **F010** Inventory available application/special updater mechanisms.
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
- [ ] **F029** Filter targets by running/stopped state.
- [ ] **F030** Skip templates automatically.
- [ ] **F031** Separate filters for CHECK and UPDATE.
- [ ] **F032** Select individual packages.
- [ ] **F033** Exclude individual packages.
- [ ] **F034** Security-only policy.
- [ ] **F035** Policies by target/group/tag.
- [ ] **F036** Per-target policy overrides.

## D. Execution modes

- [ ] **F037** Interactive/manual execution mode.
- [ ] **F038** Persistently configurable automatic/non-interactive mode.
- [ ] **F039** Native terminal behaviour and real prompts in interactive mode.
- [ ] **F040** No prompts in automatic mode.
- [ ] **F041** Execute each mutating operation exactly once.
- [ ] **F042** Deterministic output capture in automatic mode.
- [ ] **F043** Global execution mode configuration.
- [ ] **F044** Temporary execution-mode override from CLI.
- [ ] **F045** Allow execution behaviour to vary by operation class where required.

## E. Operating systems and package managers

- [ ] **F046** Debian/Ubuntu updates through APT.
- [ ] **F047** Fedora/RHEL/Rocky/Alma updates through DNF/YUM.
- [ ] **F048** Arch updates through Pacman.
- [ ] **F049** Alpine updates through APK.
- [ ] **F050** Devuan support.
- [ ] **F051** Mint/Kali/Neon and other Debian derivatives.
- [ ] **F052** FreeBSD updates through `pkg`.
- [ ] **F053** Extensible/future Windows Update support.
- [ ] **F054** Automatically detect the appropriate update strategy.
- [ ] **F055** Configurable package-manager-specific arguments.

## F. Application updates and custom scripts

- [ ] **F056** Update applications installed through Proxmox Community Scripts.
- [ ] **F057** Detect `/usr/bin/update` or another known application updater.
- [ ] **F058** Application-specific updater adapters/plugins.
- [ ] **F059** Per-target custom scripts.
- [ ] **F060** Global custom scripts.
- [ ] **F061** Pre-update hooks.
- [ ] **F062** Post-update hooks.
- [ ] **F063** Every plugin/script returns an authoritative result.

## G. Preflight

- [ ] **F064** Check free filesystem space.
- [ ] **F065** Estimate/check space required for the update.
- [ ] **F066** Check available memory.
- [ ] **F067** Check CPU/resources when an application updater requires them.
- [ ] **F068** Check real LVM-thin `Data%` / `Meta%` usage.
- [ ] **F069** Check storage required for snapshots/backups.
- [ ] **F070** Verify repositories are valid and reachable.
- [ ] **F071** Detect package-manager locks/conflicting processes.
- [ ] **F072** Verify required network connectivity.
- [ ] **F073** Verify QGA/SSH/`pct` transport before mutation.
- [ ] **F074** Custom preflight hook support.
- [ ] **F075** A failed mandatory preflight blocks the update.

## H. Snapshot, backup and rollback

- [ ] **F076** Optional pre-update snapshot.
- [ ] **F077** Optional pre-update backup.
- [ ] **F078** Require snapshot/backup according to policy.
- [ ] **F079** Select backup storage.
- [ ] **F080** Support applicable backup modes: snapshot/suspend/stop.
- [ ] **F081** Fallback from snapshot to backup when snapshot is not viable.
- [ ] **F082** Verify snapshot/backup actually completed successfully.
- [ ] **F083** Record the exact recovery artifact identifier.
- [ ] **F084** Verify age/freshness of an existing backup.
- [ ] **F085** Manual rollback.
- [ ] **F086** Configurable automatic rollback after failure.
- [ ] **F087** Retention/cleanup policy for snapshots created by Forge.
- [ ] **F088** Never remove the recovery artifact before the final result is known.

## I. Guest lifecycle

- [ ] **F089** Detect original guest state.
- [ ] **F090** Temporarily start a stopped guest when required.
- [ ] **F091** Wait for real readiness instead of using a blind fixed sleep.
- [ ] **F092** Update the guest.
- [ ] **F093** Restore the original guest state afterwards.
- [ ] **F094** Detect reboot-required state.
- [ ] **F095** Configurable reboot behaviour.
- [ ] **F096** Restart services instead of rebooting when sufficient.
- [ ] **F097** Wait for readiness after reboot.

## J. Health and recovery

- [ ] **F098** Capture a health baseline before mutation.
- [ ] **F099** Run health checks after updating.
- [ ] **F100** Check relevant systemd services.
- [ ] **F101** Configurable functional health checks.
- [ ] **F102** Compare pre-update and post-update health.
- [ ] **F103** Structured health states such as healthy/degraded/unverified/failed.
- [ ] **F104** Bounded retries when a service needs time to become ready.
- [ ] **F105** Configurable recovery action.
- [ ] **F106** Roll back when a mandatory health check does not recover.
- [ ] **F107** Verify health again after rollback.

## K. Correct error semantics

- [ ] **F108** Preserve the real exit code of every operation.
- [ ] **F109** Preserve stdout.
- [ ] **F110** Preserve stderr.
- [ ] **F111** Never repeat a mutating operation just to capture its error.
- [ ] **F112** A failed required step makes the target fail.
- [ ] **F113** A failed target remains failed even when later targets continue.
- [ ] **F114** `continue_on_error` means continue processing, never convert failure into success.
- [ ] **F115** Correctly aggregate the final run result.
- [ ] **F116** Distinguish primary failure from cleanup failure.
- [ ] **F117** Explicit timeouts.
- [ ] **F118** Retries only for operations that are safe to repeat.
- [ ] **F119** Structured result per step, target and run.

## L. Scheduling and orchestration

- [ ] **F120** Immediate manual execution.
- [ ] **F121** Scheduling through systemd timers.
- [ ] **F122** Daily/weekly/custom schedules.
- [ ] **F123** Schedule by target/group.
- [ ] **F124** Maintenance windows.
- [ ] **F125** Stagger/jitter to avoid updating everything simultaneously.
- [ ] **F126** Canary/pilot group before production rollout.
- [ ] **F127** Serial updates.
- [ ] **F128** Configurable limited parallelism.
- [ ] **F129** Global lock for incompatible simultaneous runs.
- [ ] **F130** Per-target locking.
- [ ] **F131** Jobs survive SSH/session disconnection.
- [ ] **F132** History of scheduled runs.

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
- [ ] **F142** Independent log per target.
- [ ] **F143** Independent log per step.
- [ ] **F144** Precise timestamps.
- [ ] **F145** Persist exit codes.
- [ ] **F146** Record duration per step/target/run.
- [ ] **F147** Human-readable final summary.
- [ ] **F148** Structured JSON result.
- [ ] **F149** Queryable execution history.
- [ ] **F150** Configurable log/history retention.
- [ ] **F151** Distinguish warnings from errors.
- [ ] **F152** Audit what was attempted and its result.

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

- [ ] **F170** One coherent configuration model/schema.
- [ ] **F171** Explicit defaults.
- [ ] **F172** Global configuration.
- [ ] **F173** Overrides by group/tag.
- [ ] **F174** Per-target overrides.
- [ ] **F175** Temporary CLI overrides.
- [ ] **F176** Validate the complete configuration before execution.
- [ ] **F177** Defined policy for unknown/invalid configuration values.
- [ ] **F178** Configuration migration between versions.
- [ ] **F179** Preserve custom configuration across upgrades.
- [ ] **F180** Print the effective configuration.
- [ ] **F181** Validate configuration without updating anything.
- [ ] **F182** Keep behaviour in configuration rather than scattered hard-coded exceptions.

## R. Extensibility and architecture

- [ ] **F183** Core/orchestrator independent from transports.
- [ ] **F184** Local transport.
- [ ] **F185** `pct` transport.
- [ ] **F186** SSH transport.
- [ ] **F187** QGA transport.
- [ ] **F188** Package-manager adapters.
- [ ] **F189** Application updater adapters.
- [ ] **F190** Hooks/plugins without modifying the core.
- [ ] **F191** Common result model independent of transport/updater.
- [ ] **F192** Capability detection instead of scattered hard-coded branches.
- [ ] **F193** Idempotency where applicable.
- [ ] **F194** Components testable in isolation.
- [ ] **F195** No dependency on a Web UI.
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

---

# Product capability model

Forge is organised conceptually around six major capabilities:

- [ ] **DISCOVER** — determine which systems exist and what needs updating.
- [ ] **PLAN** — determine exactly what will be done and under which policy.
- [ ] **PROTECT** — run preflight checks and establish a recovery point/state before mutation.
- [ ] **EXECUTE** — perform the update exactly once using the correct mechanism.
- [ ] **VERIFY** — determine the technical and functional result after the change.
- [ ] **REPORT** — report exactly what happened, including every relevant failure.

Two cross-cutting foundations support all six:

- [ ] **CONFIGURATION** — defines Forge behaviour explicitly.
- [ ] **RESULT MODEL** — preserves reality across layers so a failure cannot silently become success.
