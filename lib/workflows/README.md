# Bulk update workflow

## Bulk-update failure model

`forge update all` deliberately has asymmetric host and guest semantics. `forge lxc update all` follows the LXC stage only:

```text
freeze effective running-LXC VMID scope
        │
        ▼
check recovery compatibility of every selected LXC
   │
   ├─ conflict → abort before host or guest mutation
   │
   ▼
update host
   │
   ├─ failure → abort global run before any LXC starts
   │
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

This means `continue after guest failure` never means `convert failure into success`. The selected running LXCs are checked for root free space and available memory before any host/guest mutation; the centralized read-only recovery conflict checker then runs once for the complete scope. Individual LXC requirements repeat both resource checks immediately before mutation. The default `BACKUP_WHEN_SNAPSHOT_NOT_POSIBLE=true` permits backup-only recovery for snapshot-incompatible LXCs only when preflight safety requirements pass; setting it to `false` blocks those LXCs. Stopped LXCs are excluded from bulk scope.

## Final result summary

Forge prints a human-readable summary after individual host or LXC updates and after bulk runs. Bulk summaries include host status, selected/succeeded/failed LXC counts, and individual failed VMIDs with their exit codes. If the host update fails, the summary states that LXC updates did not start. Disabled scopes are distinguished from failed updates.

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

There is not yet a repeatable automated unit/integration/end-to-end test suite. That remains tracked in [`FEATURE_CHECKLIST.md`](../../FEATURE_CHECKLIST.md).

## Final-results inventory (F220)

Bulk runs snapshot all local LXC identities, states and selection classifications via the read-only `lib/results/inventory.sh` helper, including stopped, excluded, templates and disabled scopes. The **actual update scope** still comes exclusively from `lxc/list-targets.sh`; disagreements block mutation before updates. Once finished (including blocked preflight or failed host update), the coordinator emits one `result_target` machine-readable line per applicable host/LXC, sorted by numeric VMID. Each record stores ID, name, selected/attempted, `OK`, `ERROR`, `SKIPPED` or `NOT_RUN`, a stable reason and the original exit code on attempted failures. Skip precedence is template, stopped, excluded, disabled. A host failure marks still-eligible guests `NOT_RUN reason=host_update_failed`; preflight failure marks them `NOT_RUN reason=preflight_blocked`.

These **intermediate structured records feed F225**; they are not a second F157 notification or a finished results table. F147 human summaries and original exit codes are unchanged.

## Actual APT upgrade counts (F221)

F221 adds `apt_upgraded=<number|->` to the existing `result_target` record. The count comes from comparing installed dpkg versions at the start and **final persisted state** after any recovery, not from `apt-get` output, available-upgrade lists or download counts. Only strictly newer versions of packages installed in both snapshots count; new packages, removals, downgrades and unchanged/held packages do not. Non-mutating, skipped, blocked and unmeasurable targets use `-`, while a verified zero is `0`. Measurements also include APT changes made by supported application/custom-script stages when those are enabled.

Standalone host/LXC updates own their measurements. Bulk updates receive the per-target count through a private temporary file, add it to the **same** F220 record and delete the handoff directory on exit; stage output and original update exit codes are not captured or modified. Rollback may undo updates, so its final guest state is always authoritative. The rich table that consumes this field remains F225.

## Verified application versions (F222)

F222 adds `app_before` and `app_after` to the **same** `result_target` records already carrying F220/F221 facts. To qualify, a guest must have a readable `/usr/bin/update` launcher referencing an identifiable Community Scripts (or legacy tteck) CT script; the launcher is inspected but **never executed** for identification. Only a supported, read-only application-specific version probe may then provide the installed version. Current supported adapters: `plex` and `audiobookshelf` via installed dpkg package version; `caddy` via its binary; `pihole` via its Core version; `vaultwarden` via its binary; `docmost` and `immich` via their installed application package metadata. `-/-` means absent, unsupported or inconclusive. No cached upstream release tag is treated as proof of the installed version.

A snapshot is taken before mutation and again from the final running guest state after recovery/rollback, before returning an explicitly started stopped LXC to its previous state. On F225 the paired fields will display as a **single version** when equal or `previous → current` when unequal. Bulk transfer reuses the private handoff directory introduced by F221, rather than inventing a notification-specific result model. F223 official project-repository links and F225 presentation remain pending.

**F222 verification note (2026-10-13):** Installed Community Scripts launchers on LXC 101 and 102 use generated `export SCRIPT_SLUG`, `export UPDATE_SCRIPT_NAME`, and `export COMMUNITY_SCRIPTS_URL` declarations, plus an indirect CT path. F222 recognizes that exact format without sourcing the launcher; legacy direct CT URLs remain supported. The first host check failed identification; repeat the real read-only probe after deploying the fix before marking F222 complete.

## Official application repositories (F223)

The result collector adds `app_repository=<full URL|->` to the **existing** `result_target` record for identified Community Scripts apps. This is the application's verified **source-code repository**, not the Community Scripts installation repository, homepage, release notes, or a URL inferred from successful updates. It is available even when the version cannot be determined or remains unchanged. Host, skipped/unattempted, unknown app and non-verifiable public-source cases use `-`. F225 will render the URL as a plain console link in the **Changelog** column.

Verified repository mappings (2026-10-13): Pi-hole → `https://github.com/pi-hole/pi-hole`; Caddy → `https://github.com/caddyserver/caddy`; Vaultwarden → `https://github.com/dani-garcia/vaultwarden`; Immich → `https://github.com/immich-app/immich`; Docmost → `https://github.com/docmost/docmost`; Audiobookshelf → `https://github.com/advplyr/audiobookshelf`; Whisparr → `https://github.com/Whisparr/Whisparr`. Plex deliberately uses `-` because an official public source repository is not verified; the Plex website and installer do not meet F223's definition. The allowlist is local and does not make outbound requests.

Single-guest and bulk results share this field. The existing F221/F222 private application handoff is extended to include the source URL as a third tab-separated item, without capturing, parsing or changing updater output. Unknown or malformed repository input must not invalidate otherwise verified application versions or change update exit codes.

## Actionable final-result details (F224)

The same F220 `result_target` records now include `failed_stage=<stage|->`, `recovery=<success|failed:N|disabled|unavailable|->`, and `result_detail=<percent-encoded UTF-8>`. This text is F225's future **Result** column content. Percent-encoding keeps multiword failure messages and console-untrusted characters inside a single parseable record; the table renderer must URL-decode the field rather than displaying its encoded representation. The authoritative `status`, `reason`, `exit_code`, package counts, version and source-repository fields remain unchanged.

`OK`, `SKIPPED: <reason>`, and `NOT RUN: <blocker>` remain distinguishable. Failure details start with the **actual failed stage and original exit code** and include an explicit `ERROR:`/`E:`/`fatal:`-style diagnostic from **that stage's sanitized log span** only, if such a line exists. If the command emits no explicit diagnostic, the stage/exit code alone is shown; no root cause is inferred from held-package inspection, subsequent recovery or unrelated output. Post-failure recovery status is separately recorded and appended, without converting failed updates to OK. An actual recovery failure remains secondary to the original failure; failure restoring a temporarily started stopped guest is surfaced as a warning. Nonfatal failures of held-package checks, fstrim and reboot checks are shown with a WARNING prefix, leaving authoritative success status untouched.

Nested host/LXC coordinators write their escaped result text/stage/recovery in the existing disposable bulk handoff directory, rather than printing a duplicate result record or changing live log capture. Missing handoff metadata falls back to confirmed status/reason/code. Per-guest preflight blockers identify a known failing VMID and check category when available; no updates start after these checks fail. F225 console table, totals and colours are still pending.

## Rich console results (F225 implementation; F226 acceptance pending)

The `lib/results/table.py` read-only renderer consumes the exact `result_target` records already produced by F220–F224. After the current structured output and F147 summary, each supported completed run now emits **one** `Forge final results` table with `VMID | Name | APT | Application version | Changelog | Result` plus totals of actual records and selections. This is a presentation of the existing authoritative rows, not a second aggregation or notification. A measured 0 differs from unmeasurable `—`; known unchanged application versions appear once, real changes as `before → after`, official source repositories use full links, and unknown metadata displays as `—`.

The display uses a padded six-column grid on wide terminals and continuation lines on narrow terminals so source URLs and error messages are not truncated. Literal newline/control/ANSI sequences from source diagnostics cannot change terminal state. Colours are enabled only on interactive terminals by default (honour `NO_COLOR`); redirected logs remain plain. The existing results record is emitted first. If Python/table presentation fails, a warning is emitted but the **original mutating command's exit code and recovery behaviour remain authoritative**. Single host/LXC workflows render after their own record; a bulk run collects the printed records during its existing final trap and renders once after all rows, including preflight/host blockers and empty inventories. No updater is invoked merely to produce a table.

**Acceptance:** The F226 matrix, including global status consistency once F157 exists, is still open. The implementation tests exercise mocked host/guest success and failure, rollback, terminal width and colours, invalid records, explicit stopped guests and bulk scope. No production update was executed to test the renderer.
