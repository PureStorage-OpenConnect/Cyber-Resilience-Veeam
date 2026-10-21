# Unified Everpure NAS backup-from-snapshot scripts for Veeam: plan

Status: Windows backup server released, appliance blocked by Veeam (see section 4). Supersedes
the earlier FlashArray-only scripts, removed from the repository on 2026-10-21 and kept in the
git history.

## 1. Requirements

Stated:

| # | Requirement |
| --- | --- |
| R1 | Runs on Windows VBR and on the Veeam Software Appliance (VSA) unchanged |
| R2 | Handles SMB shares and NFS exports |
| R3 | Handles FlashArray File (managed directories) and FlashBlade (file systems), auto-detected |
| R4 | All behaviour comes from a configuration file; the script itself is never edited |
| R5 | Stored credentials protected at rest, host-bound where the platform allows |
| R6 | Proper logging and exit codes |

Implied by the Veeam and Pure behaviour we have verified, and added here:

| # | Requirement | Why |
| --- | --- | --- |
| R7 | **Fail-safe on pre-script failure.** Point the share at a non-existent path and keep `directBackupFailoverEnabled=false`. | Veeam only warns when a pre-job script fails and runs the job anyway. Without this a failed run silently backs up stale or live data. Already in the FA scripts; must survive the rewrite. |
| R8 | **One job, many shares, many arrays.** A job runs its pre-script once, not once per share. The config describes every share of the job; one snapshot per source serves all shares on it. | The lab job `nas-snapshot-dev` already has an NFS export and an SMB share on the same server. |
| R9 | **FlashBlade has no per-snapshot lifetime.** Cleanup must not depend on `keep_for`; an age-based orphan sweep is mandatory on FB and recommended on FA. | FB `POST file-system-snapshots` takes only `suffix`; retention lives in policies. |
| R10 | **No arguments, no environment, no "beside the script" on the VSA.** Configuration is located by a fixed absolute path or by the script's own file name. | Veeam copies the script to `sandbox/<guid>-<name>.ps1`, calls it with `& '<copy>' -ErrorAction Stop`, and starts it with `env -i`. |
| R11 | **Veeam addressed by FQDN or LAN IP, never `localhost`; `HOME` set before the first HTTPS call on Linux.** | Loopback is firewalled for the executor uid; .NET needs `HOME` to complete a TLS handshake. Both confirmed in real job runs. |
| R12 | **Idempotent and re-runnable.** Pre twice in a row, post without pre, job retries, two jobs sharing a source. | Veeam retries jobs and runs post-scripts after the last retry. |
| R13 | **Preflight / verify mode** that checks credentials, share resolution and array reachability without changing anything, plus `-WhatIf`. | The failure modes are mostly configuration; they should be found at setup time, not at 02:00. |
| R14 | **Explicit TLS policy** for both Veeam and the arrays: skip, trust system store, or pin a thumbprint. | Both ship self-signed certificates by default. |
| R15 | **Least privilege documented and tested:** array role, Veeam role, MFA-exempt service account. | R5 is only meaningful with a scoped identity behind the secret. |
| R16 | **Bounded runtime.** Everything finishes well inside Veeam's 15-minute script timeout with retries and per-call timeouts. | A hung call becomes a job stalled for 15 minutes with a log that stops mid-sentence. |
| R17 | **Tests that need no array and no Veeam**, run on Windows and Linux in CI. | Two platforms, two array types, two protocols: 8 combinations nobody will test by hand every release. |

## 2. Decisions already made, and why

* **PowerShell 7, REST only.** `pwsh` 7.6 exists on both platforms and inside the VSA sandbox;
  Veeam cmdlets do not exist in the sandbox, and the Pure SDK modules would add an install step
  and version drift. `Invoke-RestMethod` covers everything.
* **Veeam via `PUT /api/v1/inventory/unstructuredDataServers/{id}`**, which carries
  `advancedSettings.storageSnapshotPath`, `processingMode` and `directBackupFailoverEnabled` for
  `SMBShare` and `NFSShare`. Authentication is the password grant with a local Veeam user flagged
  as a service account (MFA off).
* **Arrays via Purity REST 2.x.** Same login on both (`POST /api/2.x/login` with `api-token`
  header, `x-auth-token` back); `GET arrays` returns `os` = `Purity//FA` or `Purity//FB` for
  detection. FA: `POST directory-snapshots?source_names=` with `client_name`, `suffix`,
  `keep_for`; FB: `POST file-system-snapshots?source_names=` with `suffix`. Destroy via
  `PATCH destroyed=true` on both.
* **Secrets.** Windows: DPAPI LocalMachine blob plus a hardened ACL, as today. Linux: a file
  readable only by the executor (mode 0640, group `veeam-grp-data`, proven readable from the
  sandbox). Nothing host-unique is visible inside the sandbox (`/etc/machine-id`, SSH host keys
  and the Veeam database are all outside the bind list), so a "host-bound" key on Linux would be
  a key file next to the secret, which protects nothing. **Reading credentials back from the
  Veeam database is not possible:** neither the REST credentials endpoints nor the supported
  cmdlets return passwords. The honest statement for both platforms is that file permissions
  are the boundary; DPAPI only prevents copying the blob to another host.

## 3. Decisions from the 2026-10-16 review

| Topic | Decision |
| --- | --- |
| Veeam versions | Develop and test against 13.1 (lab: Windows VBR 13.1.1.8, VSA 13.1.1.18). 12.x compatibility is not a goal; re-verify later if it happens to work. |
| Lab arrays | FlashArray `fa01.example.com`, FlashBlade `fb01.example.com`. Shared lab login for now; dedicated `storage_admin` users and tokens before the integration tests of phase 3. A FlashBlade test file system (NFS + SMB) still has to be created. |
| Config discovery | Generated per-job wrapper scripts (see below). |
| Linux secrets | Plain file with strict permissions. No AES-key-file variant. |
| Veeam role | Start with Backup Operator; fall back to Backup Administrator if the PUT requires it. |
| Share-to-source mapping | Automatic wherever possible (FA `directory-exports`, FB file-system name), explicit `Source` only as an override. |
| Post-script scope | Pattern plus age, as the FA scripts do today. |
| Old FA folder | Stays as legacy. All development on branch `feature/unified-nas-snapshots`, not pushed until finished. |

**Per-job wrappers, explained.** Veeam's job dialog on the appliance accepts a file, not a
command line, and the sandbox passes neither arguments nor environment variables. The main
script therefore cannot be told which job it is serving. A wrapper is a two-line `.ps1` per
job and phase that hard-codes exactly that and is what gets selected in the job dialog:

```powershell
# /var/lib/veeam/scripts/everpure-veeam-nas/jobs/lab-files-pre.ps1   (generated, do not edit)
& '/var/lib/veeam/scripts/everpure-veeam-nas/Invoke-EverpureVeeamNasSnapshot.ps1' -Phase pre -ConfigFile '/var/lib/veeam/scripts/everpure-veeam-nas/jobs/lab-files.jsonc'
exit $LASTEXITCODE
```

`New-EverpureVeeamJobScripts.ps1 -Job lab-files` writes the config skeleton and both wrappers
with the right absolute paths for the platform it runs on. On Windows the same wrappers work,
or the main script can be given its arguments directly in the job dialog.

Still open: Q9 (does uploading to `/var/lib/veeam/scripts` need Security Officer approval on a
hardened appliance) and Q10 (FlashBlade SMB `.snapshot` visibility defaults).

## 4. Tests before implementation

Lab tests that remove the remaining unknowns. Each has a pass criterion; items marked done were
closed by the probe runs on 2026-10-16.

| ID | Test | Pass criterion | Status |
| --- | --- | --- | --- |
| T0 | `pwsh` + REST from inside the VSA sandbox | 401 from `serverInfo` via FQDN with `HOME` set | done |
| T1 | REST `GET`/`PUT unstructuredDataServers` as the service account, SMB and NFS | path change visible in the console; `PUT` accepted with the `GET` body plus modified `advancedSettings`; minimal role recorded | done as Backup Administrator (see findings); role minimisation open |
| T2 | Same from a Windows VBR as `LOCAL SYSTEM` (`psexec -s pwsh`) | 401 unauthenticated, 200 authenticated, cert handling understood | done 2026-10-20 on `vbr01` (see findings); PowerShell cmdlets verified as SYSTEM, REST 401 confirmed |
| T3 | Pure REST from the sandbox against FA and FB | login, `arrays.os`, create snapshot with suffix, list, destroy | done on FA and FB (see findings for the FB suffix and filter rules) |
| T4 | Secret file 0640 `veeam-grp-data` readable from the sandbox | file read | done (sidecar) |
| T5 | Snapshot path visible to the proxy | `\\srv\share\.snapshot\<name>` and `srv:/export/.snapshot/<name>` listable on FA and FB, SMB and NFS | done via job runs: all five shares succeed from real snapshots when the mode is set through PowerShell; FB NFS confirmed in the control run |
| T6 | Failing pre-script on VSA; sentinel path fails the share | job continues with a warning, as on Windows 13.1; sentinel share fails | sentinel part done (PowerShell-set mode); pre-script exit code part open |
| T7 | Share-to-source lookup | FA `directory-exports` and FB `file-systems` resolve the lab shares | done: FA via `directory-exports` + policy type, FB via file-system name (`nfs.export_name` and `smb.share_name` empty means "same as file system") |
| T8 | REST API version matrix | which `x-api-version` each target accepts for these endpoints | open, depends on Q1 |
| T9 | Two jobs on one source at the same second | no name collision or defined conflict handling | open |
| T10 | Post-script after a cancelled job and after retries | runs once, destroys the right snapshots, RC 0 | **done 2026-10-21** on the Windows dev job: retries pass (one pre, one post after the last retry, 5 destroyed, RC 0); a job stopped by the operator never runs the post-script (see findings) |
| T11 | Stdout capture and size on Windows job logs | output visible; nothing truncated at the sizes we emit | open |
| T12 | Real HTTPS transport with every TLS policy (skip, SHA-1/SHA-256 pin, system) on both platforms | local TLS server test green on macOS and Windows | done 2026-10-20 (`tests/Test-EvpHttp.ps1`); found that PowerShell TLS callbacks fail off-runspace on Windows, fixed with .NET validators |
| T13 | `verify` phase on the Windows dev job as SYSTEM | six shares resolved through the PowerShell backend, both arrays reached | done 2026-10-20: passes end to end with DPAPI-stored tokens |
| T14 | Real pre/job/post chain on the Windows dev job | all six shares back up from snapshots; post destroys exactly the run's snapshots | **done 2026-10-20 16:25**: pre exit 0 (5 snapshots, 6 repoints), job Success on 6 shares, post destroyed 5, exit 0 |

**Findings from T10 (2026-10-21, Windows dev job, Veeam 13.1.1.18):**

* **Retries.** Scheduled run with a sentinel share that cannot succeed (StorageSnapshot mode,
  non-existent path, failover off) and retry set to 1 attempt after 1 minute. First session:
  pre-job script ran once, five snapshots, six Pure shares Success, sentinel Failed; Veeam logged
  "Session result is Failed. Checking if it is last retry" and did **not** run the post-job
  script. Retry session (job mode `Retry`, only the failed share): **no pre-job script**, then the
  post-job script ran once, destroyed exactly the five snapshots, exit 0. So a share that fails
  in the first attempt is retried against the snapshot the first attempt created, which still
  exists at that point. Pass criterion met. Veeam only retries scheduled runs; a job started by
  hand gets no automatic retry, and the post-job script then runs after that single session.
* **Cancelled job.** Job stopped with `Stop-VBRJob` during data transfer: Veeam logs "Running
  post-job script" and immediately after "Error running post-job. File not found: pwsh.exe" with
  a `TerminatedException ... ThrowIfStopped` stack. The message is misleading; the post-job script
  is simply not started for a session the operator stopped. The five snapshots of that run stayed
  on the arrays and the shares stayed pointed at them. Running the post phase by hand afterwards
  (as SYSTEM) destroyed exactly those five, exit 0; without that, the next pre-job sweep (2 days)
  or the FlashArray `keep_for` (7 days) removes them. Documented in the README.
* `Stop-VBRJob` without `-RunAsync` blocked for about 2.5 minutes until the running tasks had
  drained; the pre-job script was not interrupted because it had already finished.

**Findings from T1 and T3 (2026-10-16, run inside the emulated sandbox on the VSA):**

* Veeam 13.1.1.18 answers `x-api-version: 1.3-rev2`; the token lives 900 s. `serverInfo`
  reports `platform: Linux`, which the script can use to pick platform defaults without
  guessing from the OS.
* **`PUT /inventory/unstructuredDataServers/{id}` is asynchronous.** It returns HTTP 200 with a
  `FileServerSave` session (`state: Working`), not the updated model. The script must poll
  `GET /api/v1/sessions/{id}` until `state: Stopped` and check `result.result == Success`, then
  re-read the share. Two PUTs on the same share in quick succession raced in the test and the
  second was applied first; one in-flight update per share, awaited, is a hard rule.
* The `GET` body round-trips into `PUT` unchanged, including `id`, `accessCredentialsId`,
  `processing.backupProxies` and `cacheRepositoryId`. Only `advancedSettings` needs editing.
* FA export-to-directory mapping works via `directory-exports`, but the **same export name can
  appear once per policy** (an SMB and an NFS policy on one directory, e.g. `shared`),
  and the same directory can carry several exports. The mapper must filter by protocol, derived
  from the Veeam share type, and treat a result of more than one directory as an error.
* The FA file VIP `192.0.2.11` serves both lab shares; `hr-smb` maps to `hr:smb`,
  `hr-nfs` to `hr:nfs`. Snapshot create with `client_name`, `suffix`, `keep_for` and
  destroy via `PATCH destroyed=true` both work; a destroyed snapshot shows the 24 h eradication
  timer.
* FlashBlade `fb01` logs in with the `api-token` header on `/api/login` and reports
  `Purity//FB`. Several existing file systems have `snapshot_directory_enabled: false`, so the
  verify phase must check that flag.
* **FlashBlade snapshot suffix rules:** 1 to 63 characters, alphanumeric and `-` only, must
  begin and end with a letter or digit. A dot or underscore is rejected (error code 19). The FA
  convention `Veeam.Backup<ts>` therefore cannot be reused verbatim; FB gets
  `Veeam-Backup-<ts>` and the snapshot directory is `.snapshot/<fs>.Veeam-Backup-<ts>`.
  One config knob renders per platform; the match pattern is derived, not typed by the user.
* **FlashBlade ignores unknown query parameters silently.** `GET file-system-snapshots?source_names=<fs>`
  (the FA spelling) returned every snapshot on the array, 915 of them, as did `owner_names`
  and `names_or_sources`. Correct scoping is `names_or_owner_names=<fs>` or
  `filter=source.name='<fs>'`. Because this is the query behind the post-script's destroy loop,
  the client must use `filter=` on both platforms **and** verify `source.name` on every item
  before touching it. FA honours `source_names` but the same defensive check applies.
* **T5 positive run (2026-10-16 17:06, VSA, Linux proxy):** with all five job shares pointed
  at real snapshots (`StorageSnapshot`, failover off), the job finished with Success on every
  share: FA SMB, FA NFS, FA SMB on a multi-protocol directory, FB NFS, FB SMB via the
  FlashBlade local-domain user. The appliance-side task and agent logs print only the logical
  share root (`RootLink`), never the mounted snapshot path, so the Veeam UI and these logs cannot
  show whether a snapshot was read; the mount happens on the proxy. Positive proof therefore
  needs the negative test (T6, sentinel path must fail) or a content check.
* **T6 negative run (17:13) and root cause: a Veeam REST API defect, not a silent fallback.**
  Two shares pointed via REST at a non-existent sentinel path still backed up successfully.
  Comparing REST and PowerShell showed why: REST `processingMode: StorageSnapshot` is stored as
  an internal mode the engine treats as Direct and that PowerShell cannot decode ("The given
  key 'Storage' was not present in the dictionary"). PowerShell `-ProcessingMode
  StorageSnapshot` stores the internal mode `ThirdParty`, the real "backup from a storage
  snapshot at this path" mode. Once any share carries `ThirdParty`, REST fails: `GET` of that
  share and every list call return HTTP 500 "Enum value ThirdParty is not present in REST API
  mapping of E…ShareServerProcessingMode to ENasSnapshotMode", under every `x-api-version`
  from 1.2-rev1 to 1.3-rev2. Shares set through the console will hit the same read failure.
  Observed on VSA 13.1.1.18; the REST code is shared with Windows, so expect the same there
  (to verify on the 13.1.1.8 lab server). **Consequence: on 13.1.1.x the REST API can neither
  set nor read the storage-snapshot-path mode. The REST-only design is blocked until Veeam
  fixes the enum mapping. Needs a Veeam support case with this repro.**
* The Linux PowerShell module reaches the backup server over TCP 443 by FQDN (not the
  loopback-only 939x ports). A copy of `/opt/veeam/powershell` (725 MB) placed under
  `/var/lib/veeam/scripts` does import inside the sandbox, but `Connect-VBRServer` needs
  `/etc/veeam` (certificates, auth data), which is not mounted there. That path is dead and
  would be unsupported anyway. Veeam's statement that the module is unavailable to job scripts
  on the appliance stands.
* **Control run (17:28) confirmed the engine side:** with the storage-snapshot mode set
  through PowerShell, the sentinel share **failed** and the FlashBlade NFS share backed up from
  its real snapshot through the Linux proxy. T5 and T6 are therefore passed for the engine, the
  proxy and both arrays; the REST API is the only broken piece.
* **T2 (2026-10-20, Windows VBR `vbr01.example.com`, Server 2022, Veeam
  13.1.1.18, pwsh 7.6.3):** run as `NT AUTHORITY\SYSTEM` through `psexec64 -s`, the identity the
  Veeam services and therefore the job scripts use. `Veeam.Backup.PowerShell` 13.1.0.411 imports
  in about 2 s from the Console folder; `Connect-VBRServer` without credentials succeeds in
  about 12 s; `Get-VBRUnstructuredServer` lists the shares; `Set-VBRNASSMBServer` and
  `Set-VBRNASNFSServer` carry `-ProcessingMode`, `-StorageSnapshotPath` and
  `-EnableDirectBackupFailover`, the same surface as on the appliance. REST on
  `localhost:9419` answers 401 unauthenticated, so the REST backend would work on Windows too;
  the certificate is self-signed and .NET rejects it without `-SkipCertificateCheck` or a
  pinned thumbprint. `HOME` is empty under SYSTEM as well, `USERPROFILE` is the system
  profile. **Caveat from the legacy job logs of 2026-08-21:** the credential-less
  `Connect-VBRServer` under SYSTEM failed twice with "Failed to connect to Identity service"
  and the script then ran into Veeam's 15-minute timeout; with an explicit local user
  (`veeam-automation`, member of Administrators) every later run connected in about 9 s and
  the pre-job script finished with exit code 0. The Windows adapter therefore keeps the
  explicit-credential path from the earlier FlashArray scripts as an option and must fail fast, never
  hang, when the implicit connection is refused. Veeam also logs
  "[ScriptExecution] Failed to get working directory" for every script run; harmless, but the
  script must not rely on the working directory (R10 applies on Windows too).
* **Decision 2026-10-20: do not wait for the Veeam REST fix.** The Windows backend uses the
  PowerShell cmdlets now, because they honour the real mode (control run above), need no
  Veeam password when the implicit connection works, and are already ported and tested in the
  legacy module. The REST backend stays in the code for the appliance behind the same
  interface and is enabled by a verify-time probe (set and read back, or a build gate once
  Veeam names the fixed release). Backend selection is automatic: module importable means
  PowerShell, otherwise REST.
* **Decision pending the Veeam fix:** build the Veeam side behind one interface with two
  backends. `PowerShell` (cmdlets `Set-VBRNASSMBServer` / `Set-VBRNASNFSServer`) for the
  Windows backup server, where the module is available to job scripts. `REST` for the
  appliance, enabled once Veeam exposes the `ThirdParty` mode in the REST enum. Until then the
  appliance can run the array side (snapshot create/destroy, sweep) but not the repoint.
  Reported 2026-10-19 as Veeam case #08278019 (best effort, lab) and in the R&D forum:
  <https://forums.veeam.com/viewtopic.php?f=30&t=104809>.
* Lab shares verified on 2026-10-16: on FA, `192.0.2.10` is the realm VIP
  `realm-a::file-vip`; `finance-smb` maps to `fs01:finance-smb`,
  `finance-nfs` to `...:veeam-nfs`, and `shared` to `...:veeam-multi` through
  two exports (policies `smb-simple` and `nfs-simple`), which is the duplicate-name case the
  mapper must handle via policy type. On FB, `192.0.2.21` is data VIP `data01-01`;
  `projects-nfs` (NFS v3/v4.1) and `projects-smb` (SMB) exist; the snapshot
  directory was off on the SMB one and has been enabled. The Veeam job
  `nas-snapshot-dev` currently contains only the three FA shares; the FB shares are
  not in the Veeam inventory yet.

## 5. Architecture

```
everpure-veeam-nas-snapshots/
  Invoke-EverpureVeeamNasSnapshot.ps1     entry point: -Phase pre|post|verify, -ConfigFile, -WhatIf
  EverpureVeeamNas.psm1                   module, loaded by absolute path from the entry point
     Common      config loading (JSONC), schema check, settings precedence, platform defaults,
                 logging, exit codes, secret reading, duration parsing
     VeeamRest   Get-Token, Get-UnstructuredServers, Find-Share, Set-StorageSnapshotPath,
                 Set-FailSafePath; TLS policy; API version negotiation
     PureRest    Connect (login), Get-ArrayKind, New-Snapshot, Get-Snapshots, Remove-Snapshots,
                 Resolve-Source; FA and FB adapters behind one interface
     Orchestrate Invoke-PrePhase, Invoke-PostPhase, Invoke-Verify
  New-EverpureVeeamJobScripts.ps1         generates jobs/<job>.jsonc + <job>-pre.ps1 + <job>-post.ps1
  Protect-EverpureVeeamSecret.ps1         stores API tokens / Veeam password; -Verify connects
  config.sample.jsonc
  jobs/                                   per-job config and wrappers (gitignored except sample)
  secrets/                                gitignored
  tests/                                  mocked Invoke-RestMethod; runs on Windows and Linux
```

**Platform adapter** (the only place that knows which OS it is on):

| | Windows VBR | VSA |
| --- | --- | --- |
| Install location | any folder, e.g. `C:\01_SCRIPTS\everpure-veeam-nas` | `/var/lib/veeam/scripts/everpure-veeam-nas` (read-only at run time) |
| Log directory | `<install>\log` | `/var/lib/veeam/scripts/sandbox/everpure-veeam-nas/log` |
| Secret protection | DPAPI LocalMachine + ACL | file mode 0640, group `veeam-grp-data` |
| Veeam endpoint | `localhost` acceptable | FQDN or LAN IP required |
| Pre-call fix-ups | none | set `$env:HOME` if empty |
| Job script field | `pwsh.exe -File <wrapper>` or main script with arguments | wrapper only, no arguments |

**Pre phase, in order:**

1. Load config, validate, open log, print the resolved plan.
2. Veeam: get token, list unstructured data servers once, match every configured share by path
   and type. Any miss is fatal before anything is created.
3. Group shares by array and source. For each array: detect kind, login, create one snapshot per
   source (FA with `keep_for`, FB without). Record names.
4. Compute the path per share: SMB `\\server\share\.snapshot\<name>`, NFS
   `server:/export/.snapshot/<name>`; `<name>` is `<client>.<suffix>` on FA and `<fs>.<suffix>`
   on FB. `PUT` each share with `directBackupFailoverEnabled=false`, optionally forcing
   `processingMode=StorageSnapshot`.
5. Optional sweep: destroy snapshots matching the pattern and older than the configured age,
   excluding the ones just created. Default on for FB.
6. On any failure after step 2: set the sentinel path on every share that was resolved, then
   exit non-zero.

**Post phase:** per array and source, list snapshots matching the pattern, destroy them,
RC 0 unless `FailIfNoSnapshots`.

**Verify phase:** steps 1 and 2, array login and source resolution, TLS report, secret file
permission report, no changes. This is what the credential helper's `-Verify` and the first
install run use.

**Configuration schema (sketch):**

```jsonc
{
  "Veeam":   { "Server": "vsa01.example.com", "Port": 9419,
               "User": "veeam-automation", "PasswordFile": "secrets/vbr.pwd",
               "Tls": "skip | system | thumbprint:<hex>" },
  "Arrays":  [ { "Name": "fa01", "Endpoint": "fa01.lab.local", "ApiTokenFile": "secrets/fa01.token",
                 "Platform": "auto", "Tls": "skip" } ],
  "Shares":  [ { "VeeamPath": "\\\\192.0.2.11\\hr-smb", "Array": "fa01", "Source": "auto" },
               { "VeeamPath": "192.0.2.11:/hr-nfs",     "Array": "fa01", "Source": "auto" } ],
  "Snapshot":{ "ClientName": "Veeam", "SuffixPrefix": "Backup", "Lifetime": "7d",
               "MatchPattern": "Veeam\\.Backup\\d{14}", "SweepOlderThan": "2d" },
  "Behaviour": { "FailSafePath": true, "SetProcessingMode": false, "FailIfNoSnapshots": false },
  "Logging": { "RetentionDays": 30, "Level": "info" }
}
```

Relative paths resolve against the config file's directory, which works on both platforms.

**Exit codes**, identical on both platforms and listed in the README:

| RC | Meaning |
| --- | --- |
| 0 | success |
| 1 | configuration or usage error, nothing touched |
| 2 | Veeam authentication or connectivity |
| 3 | share resolution or update |
| 4 | array authentication or connectivity |
| 5 | snapshot create or destroy |
| 6 | partial success (some shares done, see log) |
| 10 | failure, fail-safe path applied |

Veeam itself treats any non-zero as a warning, so the codes exist for operators and for the
sentinel path, not for stopping the job.

**Logging:** one transcript per run in the platform log directory, pruned by retention; the same
lines on stdout, which Veeam stores in the job log on the VSA (`[ScriptExecution]` lines) and
on Windows. Secrets never appear; the token is unwrapped only at the call site.

## 5a. Snapshot naming

Both arrays enforce the same character rules on the user-supplied parts: 1 to 63 characters,
letters, digits and `-`, beginning and ending with a letter or digit, and at least one letter
or `-` (a purely numeric suffix is rejected on both). FlashArray additionally requires a
`client_name` (1 to 56 characters, same charset) and renders `<dir>.<client_name>.<suffix>`;
FlashBlade renders `<fs>.<suffix>`. The client-visible directory under `.snapshot` is therefore
`<client_name>.<suffix>` on FlashArray and `<fs>.<suffix>` on FlashBlade, and the two can never
be byte-identical. What can be identical is everything the user controls:

| | Setting | FlashArray | FlashBlade |
| --- | --- | --- | --- |
| Config | `Snapshot.Tag`, default `Veeam-Backup` (`^[A-Za-z0-9-]{1,40}$`) | | |
| Timestamp | UTC, ISO 8601 basic: `20261016T144044Z` | | |
| API call | | `client_name=<Tag>`, `suffix=<ts>` | `suffix=<Tag>-<ts>` |
| Array object | | `<dir>.Veeam-Backup.20261016T144044Z` | `<fs>.Veeam-Backup-20261016T144044Z` |
| Share path | | `.snapshot/Veeam-Backup.20261016T144044Z` | `.snapshot/<fs>.Veeam-Backup-20261016T144044Z` |
| Match | one derived regex for both | `(^|\.)<Tag>[.-]\d{8}T\d{6}Z$` | |

Tag and timestamp are identical on both platforms; only the separator differs, and that is
dictated by the array (`.` inserted by FlashArray between client name and suffix, `-` chosen by
us on FlashBlade because a dot is rejected there). The timestamp is UTC so names sort and
compare across arrays regardless of time zone and DST, and `T`/`Z` make it a valid suffix on
its own. Verified by create/destroy on both lab arrays on 2026-10-16. The match pattern is
derived from the tag and never typed by the user. There is no migration path from the legacy
FA scripts' `Veeam.Backup<ts>` names: the new scripts are a fresh setup, and leftover old
snapshots are cleaned up manually if needed.

## 6. Implementation plan

| Phase | Deliverable | Done when | Status |
| --- | --- | --- | --- |
| 0 | Lab tests T1 to T11, answers to the open questions | every row in section 4 has a result | T0 to T7, T10, T12 to T14 done; T8, T9, T11 open |
| 1 | Skeleton: config loader, platform adapter, logging, exit codes, secret helper; CI on Windows and Linux with PSScriptAnalyzer | `verify` phase runs on both platforms against mocked REST | **done 2026-10-20** (`everpure-veeam-nas-snapshots/`, 246 mocked tests green on macOS) |
| 2 | Veeam REST client | T1 and T2 pass with the real client; mocked tests for SMB/NFS, miss, duplicate, PUT round-trip | code done 2026-10-20 (PowerShell + REST backends, mocked); REST gated by build check pending Veeam fix |
| 3 | Pure REST client with FA and FB adapters | T3 passes on both arrays; naming and path tests mocked | code done 2026-10-20 (mocked); real-array run pending tokens on the Windows server |
| 4 | Orchestration: pre, post, fail-safe, sweep, multi-share | dev job backs up from snapshot on the VSA and on a Windows VBR; T6, T9, T10 pass | **Windows: done 2026-10-20** (T14), T10 done 2026-10-21; VSA waits for the Veeam REST fix; T9 open |
| 5 | Wrapper generator, credential helper `-Verify`, documentation, removal of the old folders | a reader can install from the README alone on either platform | generator, helper and README written 2026-10-20; old FlashArray folder removed 2026-10-21 (history only) |

Ported, not rewritten, from the earlier FlashArray scripts (git history): settings precedence, duration parsing, DPAPI
handling, transcript naming and pruning, the fail-safe rationale, and the test harness approach
(stubbed calls recorded to JSON lines, assertions on exactly which calls happened).

## 6a. Implementation notes (2026-10-20)

Deviations from the sketch in section 5, all deliberate:

* `Behaviour.EnsureProcessingMode` defaults to **true** (the sketch had `SetProcessingMode: false`).
  The snapshot path and the fail-safe only have an effect in the StorageSnapshot mode, and the
  lab job's shares were added in Direct mode; enforcing the mode on every repoint makes the
  setup self-correcting.
* `Snapshot.SweepOlderThan` defaults to **2d** on both platforms (sketch: default on for FB
  only). FlashBlade has no `keep_for`, FlashArray's is a backstop; a two-day cut-off is safe
  for two jobs sharing one source and keeps both arrays tidy.
* The post phase ignores already-destroyed snapshots and keeps snapshots younger than
  `Behaviour.PostKeepYoungerThan` (default none), which is the "pattern plus age" decision.
* HTTP goes through one `HttpClient`-based layer (`lib/Http.ps1`) instead of
  `Invoke-RestMethod`, so non-2xx bodies are data, the three TLS policies are uniform, and the
  tests replace the transport with a scripted responder. The hook is a global on purpose: the
  entry script re-imports the module with `-Force`.
* The REST backend refuses Veeam builds `13.0.*` and `13.1.*` unless
  `Veeam.AcknowledgeRestDefect` is true. Widen or remove the gate once Veeam names the fixed
  build.
* All FlashBlade preconditions (snapshot directory enabled) are checked before the first
  snapshot is created, so a failing last source does not leave snapshots behind on the others.

## 7. Out of scope for the first release

* Object storage (the `veeam-fb-multi-obj-account-setup.ps1` script) stays separate.
* NAS filer integration through Veeam's storage plug-in framework; Pure has no NAS plug-in.
* Journald or syslog output from the sandbox: no `/dev/log` or journal socket is bound.
