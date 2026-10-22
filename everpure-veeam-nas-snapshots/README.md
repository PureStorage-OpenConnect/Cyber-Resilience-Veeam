# Everpure NAS backup from snapshot for Veeam Backup & Replication 13.1

One PowerShell 7 code base that lets a Veeam file backup job read FlashArray File and
FlashBlade shares (SMB and NFS) from storage snapshots instead of the live share. It runs
unchanged on a Windows backup server and on the Veeam Software Appliance, needs no array SDK
module, and keeps every setting in one configuration file per job.

> **Disclaimer.** These are community example scripts. They are provided as is and are not
> supported by Everpure or by the author. Read them, test them in a lab, and adapt them to your
> environment before relying on them. See the [LICENSE](../LICENSE) and [NOTICE](../NOTICE).

## How it works

A Veeam file backup job runs the **pre** phase before it starts and the **post** phase after
it finishes.

```
pre   0. job guard: a session of the bound job (Veeam.JobId) must be running, else stop
      1. open Veeam, resolve every share of the job in the inventory (a miss stops here)
      2. log in to every array, map each share to its managed directory / file system
      3. create ONE snapshot per source, tagged and timestamped
      4. point every share at <share>/.snapshot/<name>, failover off, mode StorageSnapshot
      5. sweep snapshots with the tag older than Snapshot.KeepFor (all earlier ones by default)
      on failure after step 1: point every share at a non-existent sentinel path (fail-safe)
post  job guard, then destroy the snapshots with the tag older than Snapshot.KeepFor (optional)
verify check secrets, Veeam, the bound job and its shares, arrays and sources; change nothing
```

**Why the fail-safe.** Veeam only warns when a pre-job script fails and runs the job anyway.
Without the sentinel a failed run would leave the shares pointing at the previous snapshot or
at the live share, and the job would report success on stale data. A path that cannot be read
turns that into a visible failure. Veeam reports `Cannot find a storage snapshot at the specified
path, and failover to direct backup from the file share is disabled`.

**Why `EnsureProcessingMode` is on by default.** The snapshot path only matters when the share
is in the mode the console calls "Backup from a storage snapshot at the following path". The
scripts set that mode on every repoint so the setup is correct even when a share was added in
Direct mode.

**Retention (`Snapshot.KeepFor`) and the optional post phase.** One setting decides how long
snapshots stay. With the default `none` the post phase destroys the run's snapshots when the job
ends, and the pre phase sweeps whatever an earlier run left behind. With a duration such as `7d`
both phases destroy only snapshots older than that, so a week of backups stays browsable under
`.snapshot` on the share, at the cost of the space those snapshots hold on the array. FlashArray
snapshots additionally carry an expiry of `KeepFor` plus seven days as a backstop for the day the
scripts never run again; FlashBlade has no per-snapshot expiry, so only the two phases clean up
there. The post phase is optional. Without it a snapshot stays until the next pre phase, which
costs one run's worth of changes in array space and keeps the share pointed at a snapshot that
exists between runs.

**Job guard (`Veeam.JobId`).** Veeam gives a job script no hint which job started it. A cloned
job inherits the script command lines and would repoint this job's shares and destroy its
snapshots. With `Veeam.JobId` set, which the generator fills in, the pre and post phases first
check that a session of exactly that job is active. That is always the case when Veeam itself
runs the script, and never when a clone or another job does, so the phase stops before
changing anything. The verify phase also compares the job's shares with the `Shares` list and
reports any share the job would back up live. A `-WhatIf` dry run only warns. For a manual run
outside a job session add `-NoJobGuard`. The guard cannot tell a clone apart from the original
while both run at the same time.

### Retries and cancelled jobs

Veeam runs the pre-job script once per job run, not again for an automatic retry, and runs the
post-job script only after the last retry. A share that failed in the first attempt is therefore
retried against the snapshot the first attempt created, and the post phase cleans up once at the
end (verified on 13.1.1.18).

A job that an operator stops is different. Veeam does not run the post-job script for a stopped
session (its log says "Error running post-job. File not found: pwsh.exe", which is misleading). <!-- style-check: ignore -->
The snapshots of that run stay on the arrays and the shares stay pointed at them until the next
pre phase, which creates fresh snapshots and sweeps anything older than `Snapshot.KeepFor`. To
clean up immediately, run the post phase by hand under the same account the job uses.

```powershell
pwsh -File .\Invoke-EverpureVeeamNasSnapshot.ps1 -Phase post -ConfigFile .\jobs\<job>.jsonc -NoJobGuard
```

## Platforms and backends

| | Windows backup server | Veeam Software Appliance |
| --- | --- | --- |
| Veeam access | `Veeam.Backup.PowerShell` cmdlets (`Backend: auto` picks it) | REST API on port 9419 |
| Status | **Working.** Tested as LOCAL SYSTEM on 13.1.1.18 | **Blocked by Veeam.** 13.1.1.x maps the REST processing mode to the wrong internal mode, so the job silently reads the live share (Veeam case #08278019, [forum thread](https://forums.veeam.com/viewtopic.php?f=30&t=104809)). The REST backend refuses those builds; set `Veeam.AcknowledgeRestDefect` only to test. |
| Veeam identity | Implicit (job runs as the Veeam service, LOCAL SYSTEM). Optional `Veeam.User` + `Veeam.PasswordFile` if the implicit connection is refused | Local Veeam user flagged as service account, MFA off, `Veeam.User` + `Veeam.PasswordFile` required |
| Veeam address | `localhost` | FQDN or LAN address (loopback is firewalled for job scripts) |
| Secrets | DPAPI LocalMachine + ACL restricted to SYSTEM and Administrators | Plain file, mode 0640, group `veeam-grp-data` |
| Job script setting | Command line with arguments, or a generated wrapper | Generated wrapper only (no arguments, no environment) |
| Logs | `<install>\log\<job>-<timestamp>-<phase>.log` | `/var/lib/veeam/scripts/sandbox/everpure-veeam-nas/log/` |

Arrays are always reached through Purity REST 2.x with an API token. FlashArray and FlashBlade
are detected automatically.

## Files

| File | Purpose |
| --- | --- |
| `Invoke-EverpureVeeamNasSnapshot.ps1` | Entry point: `-Phase pre\|post\|verify -ConfigFile <file> [-WhatIf] [-NoJobGuard]` |
| `EverpureVeeamNas.psd1`, `EverpureVeeamNas.psm1` + `lib/` | Module: manifest with the version, then configuration, secrets, logging, HTTP, Veeam adapter (PowerShell and REST backends), Purity client (FlashArray and FlashBlade), orchestration |
| `config.sample.jsonc` | Annotated configuration; copy one per job |
| `New-EverpureVeeamJobScripts.ps1` | Writes `jobs/<job>.jsonc` and the `<job>-pre.ps1` / `<job>-post.ps1` wrappers |
| `Protect-EverpureVeeamSecret.ps1` | Stores an API token or the Veeam password in a protected file and verifies it |
| `tests/` | Test suite, runs anywhere: `pwsh -NoProfile -File tests/Invoke-Tests.ps1` |
| `CHANGELOG.md` | What changed in each release |

## Installation (Windows backup server)

1. Install PowerShell 7 if needed. Copy this folder to the backup server, for example
   `C:\01_SCRIPTS\everpure-veeam-nas`.
2. Create the job files with `.\New-EverpureVeeamJobScripts.ps1 -Job <job>`. On the backup
   server it looks the job up and writes its ID to `Veeam.JobId`; elsewhere pass `-JobId`. Edit
   `jobs\<job>.jsonc` so it lists every array and every share exactly as the Veeam inventory
   shows it (`\\server\share` or `server:/export`). A sub-folder or single-file job object
   still belongs to its share; list the share.
3. Store each array's API token and verify it from an **elevated** PowerShell (Run as
   administrator) with
   `.\Protect-EverpureVeeamSecret.ps1 -Path .\jobs\secrets\<array>.token -Endpoint <array> -Verify`.
   The helper restricts the file ACL to SYSTEM and Administrators as soon as it is written. In a
   non-elevated session UAC filters your Administrators membership, so the read-back for
   `-Verify` (and later `-VerifyOnly`) fails with access denied even though you are an
   administrator. The token needs the `storage_admin` role (create and destroy snapshots, read
   exports).
4. Run `pwsh -NoProfile -File .\Invoke-EverpureVeeamNasSnapshot.ps1 -Phase verify -ConfigFile .\jobs\<job>.jsonc`
   and fix whatever it reports. Repeat under the Veeam service account to prove it can read the
   secrets with `psexec -s pwsh -NoProfile -File ... -Phase verify ...`.
5. Dry run with `-Phase pre -ConfigFile ... -WhatIf`, which prints every snapshot it would create
   and every share it would repoint.
6. In the job's Advanced > Scripts settings, set the pre-job script to
   `pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "C:\01_SCRIPTS\everpure-veeam-nas\Invoke-EverpureVeeamNasSnapshot.ps1" -Phase pre -ConfigFile "C:\01_SCRIPTS\everpure-veeam-nas\jobs\<job>.jsonc"`
   and the same with `-Phase post` as the post-job script. Run the job and check the share
   task log; a failing sentinel test (point a share at a wrong path by hand) proves the mode.

## Installation (Veeam Software Appliance)

Only once Veeam ships the REST fix. Then generate the job files on a workstation, upload the
folder to `/var/lib/veeam/scripts` through the console's Files node, store the tokens with
`Protect-EverpureVeeamSecret.ps1` over SSH (mode 0640, group `veeam-grp-data`), set
`Veeam.Server` to the appliance FQDN and `Veeam.User`/`Veeam.PasswordFile`, and select
`jobs/<job>-pre.ps1` and `jobs/<job>-post.ps1` in the job dialog. Root is not needed for the
verification there. The account that writes the file owns it and mode 0640 lets the owner read
it back. Only the `chgrp veeam-grp-data` step needs root or membership in that group; the helper
warns when it could not set the group, and without it the sandbox account cannot read the file.

## Snapshot naming

| | FlashArray File | FlashBlade |
| --- | --- | --- |
| API call | `client_name=<Tag>`, `suffix=<timestamp>` | `suffix=<Tag>-<timestamp>` |
| Array object | `<dir>.Veeam-Backup.20261020T081500Z` | `<fs>.Veeam-Backup-20261020T081500Z` |
| Share path | `.snapshot/Veeam-Backup.20261020T081500Z` | `.snapshot/<fs>.Veeam-Backup-20261020T081500Z` |

The timestamp is UTC. FlashBlade rejects dots in a suffix, hence the hyphen. The post phase
and the sweep recognise snapshots by the tag and timestamp pattern only, so two jobs that share
a source should use different tags. FlashBlade has no per-snapshot expiry; its leftovers are
removed by the sweep. There is no migration from the legacy `Veeam.Backup<timestamp>` names of
the earlier FlashArray-only scripts; clean those up manually.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | success |
| 1 | configuration or usage error, nothing touched |
| 2 | Veeam authentication or connectivity |
| 3 | share resolution or update |
| 4 | array authentication or connectivity |
| 5 | snapshot create or destroy |
| 6 | partial success (backup set up, sweep had failures) |
| 10 | failure, fail-safe path applied |

Veeam treats every non-zero code as a warning and runs the job; the codes are for operators and
for the job log, the sentinel path is what protects the backup.

## Security notes

* Tokens and passwords never appear in the configuration, in a command line or in a log. They
  are unwrapped only at the call site.
* DPAPI at LocalMachine scope means any account that can read the file can decrypt it. The ACL
  is the boundary; the helper restricts it to SYSTEM and Administrators. That is also why
  `Protect-EverpureVeeamSecret.ps1` must run elevated on Windows. A non-elevated session carries
  a UAC-filtered token in which the Administrators group is deny-only, so it can write the file
  but cannot read it back for `-Verify` or `-VerifyOnly`.
* On the appliance nothing host-unique is visible inside the script sandbox, so a key file
  beside the secret would protect nothing. File permissions are the boundary there too.
* **TLS.** `skip` accepts any certificate (the default, both products ship self-signed ones),
  `system` uses the trust store, `thumbprint:<SHA-1 or SHA-256>` pins one certificate.

## Versioning

The scripts follow [Semantic Versioning](https://semver.org) (MAJOR.MINOR.PATCH). MAJOR
changes need action on the backup server, such as a configuration key that was renamed or a
different command line in the Veeam job. MINOR adds behaviour while existing configurations
keep working. PATCH fixes bugs. The version is declared once, as `ModuleVersion` in
`EverpureVeeamNas.psd1`; every run prints it as the first line of the plan ("Script version")
so a transcript always shows which release produced it, and `Get-EvpVersion` returns it to a
session that imported the module. [CHANGELOG.md](CHANGELOG.md) lists every release.

## Tests

`pwsh -NoProfile -File tests/Invoke-Tests.ps1` runs a syntax check, the unit suite, the
integration suite (HTTP replaced by a scripted responder shaped like the lab arrays and the
Veeam REST API, Veeam cmdlets replaced by a stub module) and PSScriptAnalyzer when installed.
No array and no Veeam server are needed. The DPAPI round trip only runs on Windows.
