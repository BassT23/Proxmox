# Ultimate Updater 5.2

Status: Unreleased development and Beta candidate documentation. This is not
a stable release announcement.

Ultimate Updater 5.2 continues the 5.1 stability and safety work while
extending the Web UI, integration API, Windows handling, remote operation, and
notification paths.

## Highlights

### Web UI and target selection

- Modern and Classic themes are available as browser-local preferences.
- Node actions remain separate from global Check-all and Update-all actions.
- Target selection provides independent, labelled Default, Only, and Exclude
  states for checks and updates, with immediate feedback and safe rollback on
  persistence errors.
- Jobs, live output, final output, status summaries, API management, and build
  identity are presented through the current Web UI without changing the
  underlying job and status model.

### Authentication and API

- Proxmox PAM authentication supports TOTP, recovery keys, and configured
  YubiKey OTP, with WebAuthn support through short-lived server-side
  challenges.
- The versioned read-only integration API provides authenticated metadata,
  status, package details, power-state reads, and scoped action capabilities.
- API preflight validates target identity and lifecycle safety before a guest
  can be started or updated.
- Trusted reverse-proxy authentication uses explicit origin and allowlist
  validation.

### Systems and remote operation

- Windows VM checks and opt-in updates use the Windows Update Agent through
  the supported QEMU Guest Agent and SSH transport paths, with update history,
  capability checks, bounded execution, and reboot-required reporting.
- VM SSH is preferred where configured, with QEMU Guest Agent fallback and
  target-bound context for local, remote, and global checks.
- External systems support provider-neutral Apprise notifications and retain
  their existing SSH, helper, privilege, and backup safety requirements.
- Scheduled successful checks can emit an optional success heartbeat through
  protected configuration.

### Notifications and update results

- HTML status mail preserves an Outlook-compatible layout alongside the
  existing plaintext path.
- Notification delivery remains bounded and deduplicated across email and
  Apprise providers.
- Update results distinguish success, no-op, skipped, unsupported, failed,
  and completed-with-warnings outcomes. Remote results retain their target
  identity through handback and reconciliation.
- Status and summary rendering is scoped to the current run and does not
  resurrect stale or non-inventory results.

## Safety and reliability

- APT checks refresh package metadata before structured counts and fail closed
  when a safe privileged refresh is unavailable or unsuccessful.
- Host and guest updates require a current, target-bound package baseline
  before package mutation.
- Snapshot, backup, lifecycle, capability, identity, generation, operations-ID,
  freshness, and invalidation gates remain fail-closed.
- Source self-updates support explicit master, beta, and develop selection,
  preserve build identity, and protect externally managed or trusted staged
  sources from unsafe replacement.
- Update-log cleanup waits for active capture and processes a separate copy so
  complete logs are preserved during ANSI cleanup.

## Notable fixes

- Issue #383: refreshed APT metadata is required before structured update
  counts, including safe privilege handling for External targets.
- Issue #384: a blocked full update now explains the recent verified-backup
  requirement without exposing untrusted diagnostics.
- Issue #386: global checks retain the validated SSH context for remote VMs
  without QEMU Guest Agent access.
- Issue #387: update-log cleanup no longer truncates output while the active
  terminal capture is still draining.
- Issue #388: host updates establish a valid read-only baseline before
  `pveupdate` or APT mutation.
- Issue #389: remote VM results remain correlated as VMs through worker
  handback and summary rendering.
- Issue #390: Proxmox authentication failures receive safe operation and
  failure-class diagnostics in the service journal without exposing secrets.
- Issue #391: CSI and OSC terminal sequences are removed from notification
  content while CLI output and persistent logs retain their normal behavior.
- Issue #392: LXC internet preflight preserves the actual ping result through
  SIGHUP-safe `pct exec` cleanup.

## Known limitations

- 5.2 is still an unreleased development/Beta candidate and is not a stable
  production baseline.
- Windows support remains subject to the documented transport, servicing, and
  validation boundaries; unsupported or unverifiable paths fail closed.
- External update safety still requires the configured recent verified-backup
  condition. Automatic provider-specific backup orchestration is not part of
  this release.
- The integration API remains explicitly under development and its endpoint
  names or semantics may change before a stable release.
