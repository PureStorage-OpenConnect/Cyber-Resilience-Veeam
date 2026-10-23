# Changelog

All notable changes to the Everpure NAS backup-from-snapshot scripts for Veeam are recorded
here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the
scripts follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html). The version is
declared as `ModuleVersion` in `EverpureVeeamNas.psd1` and printed at the start of every run.

## [Unreleased]

### Added

- **Shares from the job.** With `Veeam.JobId` set, the shares are read from the Veeam job at run
  time; the job configuration needs no `Shares` list. Objects that are not SMB shares or NFS
  exports are reported and skipped. `Shares` entries now override `Array` or `Source` for single
  shares of the job.
- **Shares mapped to arrays automatically.** A share without an `Array` belongs to the array that
  owns its host address as a file interface (FlashArray service `file`, FlashBlade service
  `data`); host names are resolved through DNS. The FlashBlade file server of that interface also
  settles an export name that exists on two servers. An unreachable array is a warning while
  every share still maps to another array.
- **Global arrays file.** `arrays.jsonc` beside the job configurations (or `ArraysFile`) lists
  every array once for all jobs; `arrays.sample.jsonc` documents it, and the generator creates it
  empty the first time.
- **State of the last run.** `<profile>.state.json` (default `<install>\state`, `State.Directory`
  to change it) records each job's shares, arrays and sources. A run asks the arrays of the last
  run first. Tagged snapshots on the source of a share that has left the job are cleaned up by
  the sweep and the post phase until none is left.
- **File-to-tape jobs.** The job guard, the share discovery and the generator's job lookup work
  for file-to-tape jobs as well as file backup jobs.
- **Fleets.** An `arrays.jsonc` entry with `"Type": "Fleet"` reaches every member of an Everpure
  fleet of the same product through one endpoint and one token (`context_names`). Every answer
  must name the member it was meant for; anything else is refused. `-Fleet` on the secrets
  helper adds such an entry and lists the members.
- **ActiveCluster for File.** When a realm VIP is listed on both arrays of a pair, the share
  maps to the array that reports itself `online` for it, also against the array of the last run.
- **Failures stay with the shares they concern.** A share that cannot be mapped, whose array is
  unreachable, whose source cannot be snapshotted or that cannot be repointed gets the fail-safe
  path on its own; the other shares back up from their snapshots. New exit code 11 for such a
  partial run. `Behaviour.FailSafeScope: "Job"` keeps the 1.0.0 all-or-nothing behaviour.
- **Live fallback, opt-in.** `Behaviour.OnFailure: "LiveFallback"` gives a share that cannot be
  backed up from a snapshot Veeam's failover to direct backup, so the live share is backed up
  with a warning instead of failing. `"FailSafe"` stays the default; `"None"` is the 1.0.0
  `FailSafePath: false`, which keeps working.
- `Protect-EverpureVeeamSecret.ps1 -Array <name> -Endpoint <address>` adds the array to
  `arrays.jsonc` (keeping the file's comments), then stores and verifies its token. `-Array
  <name>` alone (or `-Array *`) takes the token file, endpoint and TLS policy from
  `arrays.jsonc`, so nothing is typed twice. `-Path` and `-Endpoint` still work.

### Changed

- With `Veeam.JobId` and the PowerShell backend, the job is the share list. A job share missing
  from `Shares`, which 1.0.0 backed up live (verify reported it), is now protected. A `Shares`
  entry for a share that is not in the job is ignored with a warning instead of being repointed.
  Configurations without `Veeam.JobId`, and the REST backend, work as before.
- `-NoJobGuard` keeps reading the job for its shares; it only skips the session check.
- `New-EverpureVeeamJobScripts.ps1` stops and writes nothing when the job name matches no job or
  several, and checks a given `-JobId` against the server when the Veeam module is available.
  `-NoJobId` writes a configuration without a job binding on purpose.
- The post phase continues on the arrays it can reach when one is unreachable (exit code 4), and
  leaves that array's sources for the next run.
- A pre phase in which only some shares fail no longer puts every share on the fail-safe path
  (see FailSafeScope above). A share missing from the Veeam inventory is reported and the others
  go on.
- Fixed: a `-WhatIf` dry run of the pre phase saw no shares, because `ForEach-Object <Member>`
  honours `-WhatIf` and returned nothing.
- Fixed (also in 1.0.0): the job guard refused the scripts of an active full run, because Veeam
  names that session `<job> (Full)` and the session lookup matched the job name exactly. It now
  matches the name as a prefix and decides by job ID.
- The array API token also needs to read network interfaces (the `storage_admin` role does).

## [1.0.0] - 2026-10-22 <!-- style-check: ignore -->

Initial release.

### Added

- One PowerShell 7 code base for FlashArray File and FlashBlade shares, SMB and NFS, that runs
  unchanged on a Windows backup server and on the Veeam Software Appliance. No array SDK module,
  REST only against the arrays.
- `Invoke-EverpureVeeamNasSnapshot.ps1` with three phases. `pre` creates one tagged and
  timestamped snapshot per array source, points every share of the job at its snapshot path
  with failover to direct backup off, enforces the storage snapshot processing mode and sweeps
  snapshots carrying the tag that are older than `Snapshot.KeepFor`. `post` (optional, highly
  recommended) points every share at a non-existent path, so a next run whose pre phase fails
  early fails visibly too, and destroys the same set of snapshots. `verify` checks
  secrets, Veeam access, share resolution, array access and source mapping without changing
  anything.
- **Job guard.** With `Veeam.JobId` set (the generator fills it in), the pre and post phases run
  only inside a session of that job, so a cloned job that inherited the script settings cannot
  repoint the shares or destroy the snapshots; the verify phase compares the job's shares with
  the configuration. `-NoJobGuard` for manual runs.
- **Fail-safe sentinel path.** When the pre phase fails after the shares were resolved, every share
  is pointed at a non-existent path so the backup job fails visibly instead of reading stale or
  live data.
- Veeam adapter with two backends. PowerShell cmdlets on a Windows backup server and the REST
  API on the appliance. The REST backend refuses Veeam 13.0 and 13.1 builds by default because
  their REST API maps the storage snapshot processing mode to the wrong internal mode; the
  `AcknowledgeRestDefect` setting overrides that once Veeam ships the fix.
- One JSON-with-comments configuration file per Veeam job (`config.sample.jsonc` documents every
  key). A single `Snapshot.KeepFor` retention (`none`, or a duration such as `7d` or `6h30m`)
  drives the post phase, the pre-phase sweep and the FlashArray expiry backstop. The snapshot
  tag defaults to `veeam-<configuration file name>`, so jobs on one array source never sweep
  each other's snapshots.
- `Protect-EverpureVeeamSecret.ps1` stores array API tokens and the Veeam password in protected
  files (DPAPI at LocalMachine scope plus ACL on Windows, file permissions on the appliance) and
  verifies them against the target.
- `New-EverpureVeeamJobScripts.ps1` generates the per-job configuration and the argument-free
  pre and post wrapper scripts the appliance sandbox requires.
- TLS policies per endpoint, `skip`, `system` and `thumbprint:<SHA-1 or SHA-256>` pinning. The
  secret helper prints the array's certificate hash to pin, and the verify phase warns about
  every endpoint left on `skip`.
- `-WhatIf` dry run for every phase, exit codes 0 to 6 and 10 for operators and job logs, one
  transcript per run with age-based pruning.
- Self-contained test suite (`tests/Invoke-Tests.ps1`) with syntax check, unit and integration
  tests against a scripted HTTP responder and a stub Veeam module, PSScriptAnalyzer when
  installed. Needs no array and no Veeam server.
- **Semantic versioning.** `EverpureVeeamNas.psd1` declares the version, `Get-EvpVersion` returns
  it and the run header prints it.
