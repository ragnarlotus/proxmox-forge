# Bulk update workflow

## Bulk-update failure model

`forge update all` performs the host stage first, followed by the independent
LXC stage. `forge lxc update all` runs only the LXC stage:

```text
freeze effective running-LXC VMID scope
        │
        ▼
check root space, memory and recovery compatibility for selected LXCs
   │
   ├─ conflict → abort before host or guest mutation
   │
   ▼
update host (if enabled)
   │
   ├─ failure → preserve host ERROR and its actual exit code
   │             continue with the preflight-approved LXCs
   ▼
update LXCs serially
   │
   ├─ target failure → recover if possible, record failure, continue
   │
   └─ remaining targets continue
        │
        ▼
aggregate final result
```

Host backup/requirements/OS failures never turn into success and do not cancel
otherwise eligible LXC updates. A failed host still makes the combined command
exit nonzero (preserving its original failure code); the authoritative result
table shows host `ERROR` and each guest's actual `OK` or `ERROR`, with an
overall `PARTIAL` when at least one guest succeeds. Global selection, resource,
and recovery preflight failures still block **all** mutation. The selected running LXCs are checked for root free space and available memory before any host/guest mutation; the centralized read-only recovery conflict checker then runs once for the complete scope. Individual LXC requirements repeat both resource checks immediately before mutation. Forge now uses only same-run `vzdump` archives for LXC recovery, regardless of snapshot support. With automatic recovery enabled, old persistent LXC snapshots must be removed manually before an update because forced restore would destroy them. Stopped LXCs are excluded from bulk scope.

## Final result summary

Forge prints a human-readable summary after individual host or LXC updates and after bulk runs. Bulk summaries include host status, selected/succeeded/failed LXC counts, and individual failed VMIDs with their exit codes. If the host update fails, the summary reports its failure separately from the LXC results and retains a nonzero command exit status. Disabled scopes are distinguished from failed updates.

The readable summary is additional terminal output; existing structured `update=...` and `update_all=...` records, log records, failure aggregation and exit codes retain their previous semantics.

## Validation status

The current critical path has been manually exercised on a live Proxmox system, including:

- complete host-and-LXC bulk-update execution (previous CLI name: `update-all`);
- deliberate LXC systemd health failure detection and recovery;
- real-time carriage-return progress handling;
- sanitized persistent logging;
- terminal scrollback preservation across Community Scripts screen clears;
- host APT `autoremove` after simulation and boot-kernel validation;
- LXC APT `autoremove` simulation;
- real LXC `pct fstrim` execution;
- end-to-end explicit update of an initially stopped LXC, including temporary startup, recovery backup, OS/application update, health check, `fstrim`, and restoration to `stopped` state.

The repository now runs an automated unit and integration regression suite from `tests/` via GitHub Actions on pull requests. Live-host checks complement these tests; see [`FEATURE_CHECKLIST.md`](../../FEATURE_CHECKLIST.md) for completed and outstanding acceptance work.

## Final-results inventory (F220)

Bulk runs snapshot all local LXC identities, states and selection classifications via the read-only `lib/results/inventory.sh` helper, including stopped, excluded, templates and disabled scopes. The **actual update scope** still comes exclusively from `lxc/list-targets.sh`; disagreements block mutation before updates. Once finished (including blocked preflight or failed host update), the coordinator emits one `result_target` machine-readable line per applicable host/LXC, sorted by numeric VMID. Each record stores ID, name, selected/attempted, `OK`, `ERROR`, `SKIPPED` or `NOT_RUN`, a stable reason and the original exit code on attempted failures. Skip precedence is template, stopped, excluded, disabled. A host failure no longer blocks eligible guests: they retain their own attempted `OK`/`ERROR` result. Preflight failure before updates still marks them `NOT_RUN reason=preflight_blocked`.

These **intermediate structured records feed F225**; they are not a second F157 notification or a finished results table. F147 human summaries and original exit codes are unchanged.

## Actual APT upgrade counts (F221)

F221 adds `apt_upgraded=<number|->` to the existing `result_target` record. The count comes from comparing installed dpkg versions at the start and **final persisted state** after any recovery, not from `apt-get` output, available-upgrade lists or download counts. Only strictly newer versions of packages installed in both snapshots count; new packages, removals, downgrades and unchanged/held packages do not. Non-mutating, skipped, blocked and unmeasurable targets use `-`, while a verified zero is `0`. Measurements also include APT changes made by supported application/custom-script stages when those are enabled.

Standalone host/LXC updates own their measurements. Bulk updates receive the per-target count through a private temporary file, add it to the **same** F220 record and delete the handoff directory on exit; stage output and original update exit codes are not captured or modified. Rollback may undo updates, so its final guest state is always authoritative. The rich table that consumes this field remains F225.

## Verified application versions (F222)

F222 adds `app_before` and `app_after` to the **same** `result_target` records already carrying F220/F221 facts. To qualify, a guest must have a readable `/usr/bin/update` launcher referencing an identifiable Community Scripts (or legacy tteck) CT script; the launcher is inspected but **never executed** for identification. Installed versions are read using supported package/binary probes or a verified Community Scripts release marker where available; a successful application update may also supply an explicitly confirmed version transition. Current supported adapters: `plex` and `audiobookshelf` via installed dpkg package version; `caddy` via its binary; `pihole` via its Core version; `vaultwarden` via its binary; `docmost` and `immich` via their installed application package metadata. `-/-` means absent, unsupported or inconclusive. No cached upstream release tag is treated as proof of the installed version.

Installed versions are checked read-only before mutation and from the final running guest state after any recovery/rollback, before returning an explicitly started stopped LXC to its previous state. F225 displays a **single version** when equal or `previous → current` when unequal. Bulk transfer reuses the private handoff directory introduced by F221; F223 official project repositories and F225 presentation are implemented.

**F222 verification note (2026-10-13):** Installed Community Scripts launchers on LXC 101 and 102 use generated `export SCRIPT_SLUG`, `export UPDATE_SCRIPT_NAME`, and `export COMMUNITY_SCRIPTS_URL` declarations, plus an indirect CT path. F222 recognizes that exact format without sourcing the launcher; legacy direct CT URLs remain supported. The initial detection issue was corrected and verified on the host in October 2026.

## Official application repositories (F223)

The result collector adds `app_repository=<full URL|->` to the **existing** `result_target` record for identified Community Scripts apps. This is the application's verified **source-code repository**, not the Community Scripts installation repository, homepage, release notes, or a URL inferred from successful updates. It is available even when the version cannot be determined or remains unchanged. Host, skipped/unattempted, unknown app and non-verifiable public-source cases use `-`. F225 renders the URL as a plain console link in the **Changelog** column.

Verified repository mappings (2026-10-13): Pi-hole → `https://github.com/pi-hole/pi-hole`; Caddy → `https://github.com/caddyserver/caddy`; Vaultwarden → `https://github.com/dani-garcia/vaultwarden`; Immich → `https://github.com/immich-app/immich`; Docmost → `https://github.com/docmost/docmost`; Audiobookshelf → `https://github.com/advplyr/audiobookshelf`; Whisparr → `https://github.com/Whisparr/Whisparr`. Plex deliberately uses `-` because an official public source repository is not verified; the Plex website and installer do not meet F223's definition. The allowlist is local and does not make outbound requests.

Single-guest and bulk results share this field. The existing F221/F222 private application handoff is extended to include the source URL as a third tab-separated item, without capturing, parsing or changing updater output. Unknown or malformed repository input must not invalidate otherwise verified application versions or change update exit codes.

## Actionable final-result details (F224)

The same F220 `result_target` records now include `failed_stage=<stage|->`, `recovery=<success|failed:N|disabled|unavailable|->`, and `result_detail=<percent-encoded UTF-8>`. This text supplies F225's **Result** column. Percent-encoding keeps multiword failure messages and console-untrusted characters inside a single parseable record; the table renderer must URL-decode the field rather than displaying its encoded representation. The authoritative `status`, `reason`, `exit_code`, package counts, version and source-repository fields remain unchanged.

`OK`, `SKIPPED: <reason>`, and `NOT RUN: <blocker>` remain distinguishable. Failure details start with the **actual failed stage and original exit code** and include an explicit `ERROR:`/`E:`/`fatal:`-style diagnostic from **that stage's sanitized log span** only, if such a line exists. If the command emits no explicit diagnostic, the stage/exit code alone is shown; no root cause is inferred from held-package inspection, subsequent recovery or unrelated output. Post-failure recovery status is separately recorded and appended, without converting failed updates to OK. An actual recovery failure remains secondary to the original failure; failure restoring a temporarily started stopped guest is surfaced as a warning. Nonfatal failures of held-package checks, fstrim and reboot checks are shown with a WARNING prefix, leaving authoritative success status untouched.

Nested host/LXC coordinators write their escaped result text/stage/recovery in the existing disposable bulk handoff directory, rather than printing a duplicate result record or changing live log capture. Missing handoff metadata falls back to confirmed status/reason/code. Per-guest preflight blockers identify a known failing VMID and check category when available; no updates start after these checks fail. F225's console table, totals and colours are implemented.

## Global result (F157; F226 accepted)

The **same** read-only `lib/results/table.py` renderer that prints F225's rows and totals now derives a single F157 global result from those parsed `result_target` records. The console emits one `result_global status=SUCCESS|FAILED|PARTIAL targets=N selected=N attempted=N succeeded=N failed=N skipped=N not_run=N` record after the table totals, followed by an `Overall result:` label. F157 adds no independent notification renderer, collector, Proxmox command or target-counting path.

- **SUCCESS:** no selected target failed or remained eligible-but-unattempted. Intentionally stopped, excluded, template and disabled scopes are `SKIPPED`, not failures. An empty inventory or all-skipped run is `SUCCESS (no targets selected)`; it does **not** imply a package was updated.
- **FAILED:** one or more `ERROR` or `NOT_RUN` outcomes and **zero** `OK` target outcomes. This includes all failed guests, host failure before guests, and blocked preflights.
- **PARTIAL:** at least one `OK` and at least one `ERROR` or `NOT_RUN`. A successful host with every selected guest failing is PARTIAL, not SUCCESS.

Recovery success never changes the failed target to OK; informational warnings on an OK result do not become failures. F147's existing basic technical summary and CLI exit codes remain unchanged: a mixed batch still exits nonzero even though its F157 **per-target** global status is PARTIAL. The machine-readable `result_global` is reused by F159 and the optional email notification integration without adding another aggregation model; F157 itself sends no email. If optional table presentation fails, it warns without masking the authoritative existing structured target records or update exit code.

F226 verifies global consistency against all expected individual rows and simulated operations, including empty, skipped, preflight-blocked, mixed, recovery and failure outcomes, as an acceptance prerequisite for F225/F157.

## Rich console results (F225; F226 accepted)

The `lib/results/table.py` read-only renderer consumes the exact `result_target` records already produced by F220–F224. After the current structured output and F147 summary, each supported completed run now emits **one** `Forge final results` table with `VMID | Name | APT | Software version | Changelog | Result` plus totals of actual records and selections. This is a presentation of the existing authoritative rows, not a second aggregation or notification. A measured 0 differs from unmeasurable `—`; known unchanged application versions appear once, real changes as `before → after`, official source repositories use full links, and unknown metadata displays as `—`.

The display uses a padded six-column grid at every terminal width (minimum 60 columns). On narrower terminals it adjusts column widths and wraps cell content, referencing long source URLs with numeric links in a short `Changelog links:` legend directly below the grid; full URLs remain copyable/clickable and diagnostics are not truncated. Wide terminals retain the original direct-link layout. Literal newline/control/ANSI sequences from source diagnostics cannot change terminal state. Colours are enabled only on interactive terminals by default (honour `NO_COLOR`); redirected logs remain plain. The existing results record is emitted first. If Python/table presentation fails, a warning is emitted but the **original mutating command's exit code and recovery behaviour remain authoritative**. Single host/LXC workflows render after their own record; a bulk run collects the printed records during its existing final trap and renders once after all rows, including preflight/host blockers and empty inventories. No updater is invoked merely to produce a table.

**Acceptance:** The F226 regression matrix covers host/guest success and failure, recovery, terminal width and colours, invalid records, explicitly stopped guests, bulk scope and F157 global consistency. A read-only synthetic mixed-results check was also confirmed on the Proxmox host (2026-10-13).

## Failure and blocked-target digest (F159)

The existing F225/F157 renderer prints a compact `Failed and blocked targets (N)` section **only when** one or more authoritative `result_target` rows have `status=ERROR` or `status=NOT_RUN`. Each entry retains the actual host/VMID and name, shows whether the target failed or never ran, and repeats that row's already percent-decoded/sanitized F224 `result_detail`. It therefore carries the known failed stage and original exit code, explicit diagnostic when captured, and recovery result, or the known preflight/host blocking reason. Where no explicit cause was recorded, no new cause is invented.

`SKIPPED` targets, including stopped guests, templates, exclusions and disabled scopes, are **not failures**; warning-only `OK` results also do not appear in the digest. Display wraps long/multiline diagnostics, removes untrusted control sequences and honours existing terminal-colour settings. The same frozen target records are used for the main table, F157 status, this digest and the existing F153/F154 notification integration; the digest is presentation, not a new results store, and emails are only sent when independently enabled by policy. The technical exit code, F147 summary, update selection, recovery policy and operation counts remain unchanged. Regression coverage includes real coordinator fixtures with mocked external operations, individual host/LXC results, multiple errors and preflight blocking.

## Email notifications (F153/F154)

Forge has two boolean options, configured in the versioned `forge.conf.default` and optionally overridden in local `forge.conf`:

- `EMAIL_NOTIFICATIONS=false` (**F153**): never send a message by default; opt in explicitly to enable.
- `NOTIFY_ONLY_ERRORS=true` (**F154**): when sending is enabled, send only for global `FAILED` or `PARTIAL` (including preflight-blocked `NOT_RUN`). Set `false` to also receive `SUCCESS` reports, including zero-selected/all-skipped.

The existing F225/F157/F159 records are printed exactly as before. Once the finalized console rendering succeeds, a separate `lib/notifications/send.py` helper reads those **same** immutable `result_target` records and reuses F225's parser, F157 status computation, and F159/plain-text presentation to build an email. It does not re-run or inspect any guest or infer a failure from the CLI exit code. For bulk runs, the nested host/guest workflows suppress their individual render and notification; there is at most **one email per completed Forge invocation**. Standalone host and LXC runs behave the same way.

Messages go to the Proxmox host's **local `root` mailbox** using `sendmail -t -oi`. Proxmox VE's documented system-mail forwarding processes them as `system-mail` events according to the **already configured notification matchers and targets**, including `mail-to-root` with `root@pam`'s email address. Forge does **not** configure an SMTP server, sender, recipients, Proxmox matcher or additional templates. To deliver mail, the host's mail forwarding setup must actually work. Proxmox treats `system-mail` as severity `unknown`, so F154's own policy decides which Forge runs generate email independently of Proxmox's matcher severity rules.

The subject contains the global F157 status; the body includes the **same plain final-results table, totals and F159 failure/blocked-target digest**. Untrusted diagnostics are sanitised for display and cannot inject mail headers. The sendmail helper is called only after successful final rendering and successful boolean configuration validation. SMTP/forwarding delivery failures are nonfatal to the update: the terminal displays a warning, the authoritative records and original update exit code are preserved, and Forge never retries an update merely to send a message. A successful return from sendmail means local acceptance, **not verified delivery to the user's inbox**.

Tests use a fake `sendmail` to cover defaults, policy combinations, host/LXC/bulk results, preflight blocking, failures and controlled sender failure; no test sends real mail.
