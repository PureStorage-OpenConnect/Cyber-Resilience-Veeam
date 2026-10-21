# Changelog

All notable changes to the Everpure NAS backup-from-snapshot scripts for Veeam are recorded
here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the
scripts follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html). The version is
declared as `ModuleVersion` in `EverpureVeeamNas.psd1` and printed at the start of every run.

## [Unreleased]

## [1.0.0] - 2026-10-21

Initial release.

### Added

- One PowerShell 7 code base for FlashArray File and FlashBlade shares, SMB and NFS, that runs
  unchanged on a Windows backup server and on the Veeam Software Appliance. No Pure SDK module,
  REST only against the arrays.
- `Invoke-EverpureVeeamNasSnapshot.ps1` with three phases. `pre` creates one tagged and
  timestamped snapshot per array source, points every share of the job at its snapshot path
  with failover to direct backup off, enforces the storage snapshot processing mode and sweeps
  older snapshots carrying the tag. `post` destroys the snapshots of the run. `verify` checks
  secrets, Veeam access, share resolution, array access and source mapping without changing
  anything.
- Fail-safe sentinel path: when the pre phase fails after the shares were resolved, every share
  is pointed at a non-existent path so the backup job fails visibly instead of reading stale or
  live data.
- Veeam adapter with two backends. PowerShell cmdlets on a Windows backup server and the REST
  API on the appliance. The REST backend refuses Veeam 13.0 and 13.1 builds by default because
  their REST API maps the storage snapshot processing mode to the wrong internal mode; the
  `AcknowledgeRestDefect` setting overrides that once Veeam ships the fix.
- One JSON-with-comments configuration file per Veeam job (`config.sample.jsonc` documents every
  key), with snapshot lifetime and sweep age as durations such as `7d` or `6h30m`.
- `Protect-EverpureVeeamSecret.ps1` stores array API tokens and the Veeam password in protected
  files (DPAPI at LocalMachine scope plus ACL on Windows, file permissions on the appliance) and
  verifies them against the target.
- `New-EverpureVeeamJobScripts.ps1` generates the per-job configuration and the argument-free
  pre and post wrapper scripts the appliance sandbox requires.
- TLS policies per endpoint: `skip`, `system` and `thumbprint:<SHA-1 or SHA-256>` pinning.
- `-WhatIf` dry run for every phase, exit codes 0 to 6 and 10 for operators and job logs, one
  transcript per run with age-based pruning.
- Self-contained test suite (`tests/Invoke-Tests.ps1`): syntax check, unit and integration
  tests against a scripted HTTP responder and a stub Veeam module, PSScriptAnalyzer when
  installed. Needs no array and no Veeam server.
- Semantic versioning: `EverpureVeeamNas.psd1` declares the version, `Get-EvpVersion` returns
  it and the run header prints it.
