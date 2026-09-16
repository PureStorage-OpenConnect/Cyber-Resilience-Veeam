# FlashArray File backup from snapshot, for Veeam NAS backup

Pre- and post-job scripts that let a Veeam **unstructured data (NAS) backup** job read from a
FlashArray File snapshot instead of the live share. Works for **SMB shares and NFS exports**.

Copy this whole folder to the Veeam Backup & Replication server — the scripts, the module and the
configuration file are meant to sit together, and the scripts resolve the module relative to
themselves.

## Contents

| File | Purpose |
| --- | --- |
| [fa-file-veeam-snapshot-pre-backup.ps1](fa-file-veeam-snapshot-pre-backup.ps1) | Snapshots a FlashArray File Managed Directory and points the Veeam file share at the snapshot. |
| [fa-file-veeam-snapshot-post-backup.ps1](fa-file-veeam-snapshot-post-backup.ps1) | Destroys the snapshots created above. |
| [fa-veeam-credential-setup.ps1](fa-veeam-credential-setup.ps1) | One-time helper that encrypts the FlashArray API token, or a Veeam password, to disk. |
| [PureVeeamFA.psm1](PureVeeamFA.psm1) | Shared helpers used by all three scripts. |
| [fa-veeam-config.sample.json](fa-veeam-config.sample.json) | Configuration template. Copy it, name it after the job. |
| [tests/](tests/) | Tests. No FlashArray and no Veeam server needed. |

---

## How it works

Backing up a share or export from a snapshot gives the job a consistent point in time and works
around locked or open files. The pre-backup script creates a Managed Directory snapshot and
repoints the Veeam inventory entry at it; the post-backup script cleans the snapshot up.

Both scripts work for **SMB shares and NFS exports**. The correct Veeam cmdlet is selected from
the type of the inventory object rather than hard-coded, and the share is looked up with
`Get-VBRUnstructuredServer`, which replaced the obsolete `Get-VBRNASServer` in Veeam Backup &
Replication 12.1.

### Prerequisites

* Veeam Backup & Replication 12.1 or later (12.0 still works via a fallback, with a warning).
* The file share added to the Veeam inventory with processing mode **Storage snapshot**.
* **PowerShell 7 (`pwsh.exe`)** on the Veeam Backup & Replication server. The
  `Veeam.Backup.PowerShell` module ships only for PowerShell 7, so the scripts declare
  `#Requires -Version 7.0` / `-PSEdition Core` and refuse to run under Windows PowerShell 5.1
  rather than failing later with a missing-cmdlet error. Invoke them with `pwsh.exe`, not
  `powershell.exe`.
* The Everpure PowerShell SDK:
  ```powershell
  Install-Module -Name PureStoragePowerShellSDK2 -Scope AllUsers
  ```
* A FlashArray API token for a dedicated account with the least privilege that still permits
  creating and destroying Managed Directory snapshots. Create one in the GUI under
  **Settings > Users and Policies > Users**, or with `pureadmin create --api-token <user>`.

### 1. Store the API token

Copy this folder to the Veeam server — for example to `C:\01_SCRIPTS\fa-nas-snapshots` — then run
once per array:

```powershell
cd C:\01_SCRIPTS\fa-nas-snapshots
.\fa-veeam-credential-setup.ps1 -Path C:\01_SCRIPTS\fa-nas-snapshots\fa01.apitoken `
    -Endpoint fa01.lab.local -Verify
```

This prompts for the token, encrypts it with Windows DPAPI, restricts the file ACL to
`NT AUTHORITY\SYSTEM` and `BUILTIN\Administrators`, then decrypts it and connects to the array to
prove it works. The token is never echoed and never written to a transcript.

Then confirm the **Veeam Backup Service account** can read it. Veeam runs pre/post job scripts as
that account, which is usually `LOCAL SYSTEM` and is not the account you just used:

```powershell
psexec -s -i pwsh.exe -File C:\01_SCRIPTS\fa-nas-snapshots\fa-veeam-credential-setup.ps1 `
    -Path C:\01_SCRIPTS\fa-nas-snapshots\fa01.apitoken -Endpoint fa01.lab.local -VerifyOnly
```

> **Why LocalMachine DPAPI scope, and what it costs you.** A `CurrentUser`-scope blob could not be
> decrypted by the Veeam service account, so the token is protected at `LocalMachine` scope
> instead. That means **any account on this server that can read the file can decrypt it** — the
> file ACL, not the encryption, is the security boundary. Keep the file on a local disk, keep the
> hardened ACL, and treat read access as equivalent to knowing the token.

### 2. Create a Veeam user for the pre-backup script

Veeam executes pre/post job scripts **as the account assigned to the Veeam Backup Service**, which
defaults to `Local System` — so the script presents as the *machine* account (`DOMAIN\HOST$`). The
`Connect-VBRServer` reference is explicit about what that means:

> Only local and domain user accounts can be used for authentication. User accounts with SAML
> authentication are not supported.

A machine account is therefore not a valid authentication principal: you cannot grant it a Veeam
role, and the console offers no way to try. On v13 this surfaces as
`Failed to connect to identity service`.

So give the pre-backup script its own identity. Create a dedicated Veeam user — on a workgroup
server that is a **local** user, named `HOSTNAME\username` — grant it a Veeam role under **Users
and Roles**, then store its password the same way as the API token:

```powershell
.\fa-veeam-credential-setup.ps1 -Path C:\01_SCRIPTS\fa-nas-snapshots\vbr.pwd `
    -SecretType VeeamPassword -VBRUser 'CXC-VEEAM-VBR\veeam-automation' -Verify
```

`-Verify` opens a real Veeam session with that credential and reads the inventory back, so a wrong
password or a missing role fails here rather than inside a backup job.

Add both to the configuration:

```json
"VBRUser": "CXC-VEEAM-VBR\\veeam-automation",
"VBRPasswordFile": "C:\\01_SCRIPTS\\fa-nas-snapshots\\vbr.pwd"
```

Only the pre-backup script needs this — the post-backup script talks solely to the array.

Leaving both unset falls back to the inherited identity, which works only where the Veeam Backup
Service already runs as a user account holding a Veeam role. Reconfiguring the service that way is
the alternative to this section, but it changes the security context of *every* job on the server,
so scoping the credential to the script is usually the smaller change.

#### A note on the backup server's certificate

`ForceAcceptTlsCertificate` **defaults to `true`**, so nothing needs configuring here for a stock
installation. That default is deliberate, and worth understanding before changing it.

A stock Veeam installation presents a self-signed certificate, and `Connect-VBRServer` *asks*
whether to accept one it cannot validate. At a console you answer the prompt. Under the Veeam Backup
Service there is nobody to answer, so the cmdlet blocks until Veeam kills the script at its
15-minute timeout — the job stalls and the log stops after `Connecting to ...`. The same script run
by hand connects fine, because your own profile has already accepted the thumbprint. Defaulting to
accept avoids a failure mode that looks nothing like its cause.

If you do run a proper certificate on the backup server and want it validated, turn the default off:

```json
"ForceAcceptTlsCertificate": false
```

The script then checks the certificate itself *before* connecting, and reports the result in its
preflight:

```
Veeam connection preflight:
  Running as     : NT AUTHORITY\SYSTEM
  Target         : localhost:443
  Port reachable : True
  Certificate    : NOT trusted (RemoteCertificateChainErrors)
  Interactive    : False
  Authenticating : explicit credential 'CXC-VEEAM-VBR\veeam-automation'
```

An untrusted certificate in a non-interactive session is then a hard stop: the script fails in
seconds naming the setting, rather than hanging on a prompt. Interactively it warns and carries on,
since the prompt is answerable there.

### 3. Create a configuration file

Copy [fa-veeam-config.sample.json](fa-veeam-config.sample.json) and edit it. Use **one file per
file share / job** and pass it with `-ConfigFile`. Name it after the job — the file name becomes
the profile name in the transcript file names, so `mucfa75-nas.json` produces
`log\mucfa75-nas-<timestamp>-pre.log`.

The sample is grouped: everything that must be set is at the top, everything with a working
default below it. `//` and `/* */` **comments are supported** — `ConvertFrom-Json` accepts them,
verified on PowerShell 7.4 and 7.6. A `#` comment is *not*; it fails to parse. Strict JSON allows
neither, so editors validating against the JSON schema will complain; the repository's
[.vscode/settings.json](../.vscode/settings.json) turns that off by treating `*.json` here as JSONC.

SMB share:

```json
{
  "Endpoint": "fa01.lab.local",
  "ApiTokenFile": "C:\\01_SCRIPTS\\fa-nas-snapshots\\fa01.apitoken",
  "SnapDirectory": "user-shares01::user-shares01:lab-files",
  "FileSharePath": "\\\\172.16.16.15\\lab-files",
  "SnapLifetime": "7d"
}
```

NFS export — only `FileSharePath` changes:

```json
{
  "Endpoint": "fa01.lab.local",
  "ApiTokenFile": "C:\\01_SCRIPTS\\fa-nas-snapshots\\fa01.apitoken",
  "SnapDirectory": "user-shares01::user-shares01:lab-nfs",
  "FileSharePath": "172.16.16.15:/lab-nfs",
  "SnapLifetime": "7d"
}
```

`FileSharePath` must match the share name **exactly** as it appears in the Veeam inventory. If it
matches nothing, or matches more than one source, the script fails with an explicit message
rather than a cmdlet binding error.

### 4. Wire the scripts into the job

In the Veeam job's **Storage > Advanced > Scripts** tab, set both fields to:

```
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File C:\01_SCRIPTS\fa-nas-snapshots\fa-file-veeam-snapshot-pre-backup.ps1 -ConfigFile C:\01_SCRIPTS\fa-nas-snapshots\lab-files.json
```

```
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File C:\01_SCRIPTS\fa-nas-snapshots\fa-file-veeam-snapshot-post-backup.ps1 -ConfigFile C:\01_SCRIPTS\fa-nas-snapshots\lab-files.json
```

Dry-run first — this connects and reports what it would do, but changes nothing:

```powershell
.\fa-file-veeam-snapshot-pre-backup.ps1 -ConfigFile C:\01_SCRIPTS\fa-nas-snapshots\lab-files.json -WhatIf
```

### Snapshot naming

The pre-backup script creates `<ClientName>.<SuffixPrefix><timestamp>`, by default
`Veeam.Backup20260817093153`, so the full FlashArray snapshot name is
`user-shares01::user-shares01:lab-files.Veeam.Backup20260817093153`. Veeam is then pointed at:

| Protocol | Storage snapshot path |
| --- | --- |
| SMB | `\\172.16.16.15\lab-files\.snapshot\Veeam.Backup20260817093153` |
| NFS | `172.16.16.15:/lab-nfs/.snapshot/Veeam.Backup20260817093153` |

The post-backup script's `SnapshotMatchPattern` (default `Veeam\.Backup\d{14}`) must keep matching
whatever the pre-backup script produces, so change `SnapClientName` or `SnapSuffixPrefix` in both.

### Configuration reference

Precedence is **explicit parameter → configuration file → environment variable → default**.
Run `Get-Help .\fa-file-veeam-snapshot-pre-backup.ps1 -Full` for the complete list.

| Key | Environment variable | Default | Notes |
| --- | --- | --- | --- |
| `Endpoint` | `PUREFA_ENDPOINT` | *required* | FlashArray management IP or FQDN |
| `ApiTokenFile` | `PUREFA_API_TOKEN_FILE` | — | Encrypted token from the setup helper |
| `SnapDirectory` | `PUREFA_SNAP_DIRECTORY` | *required* | Managed Directory name on the array |
| `FileSharePath` | `VEEAM_FILE_SHARE_PATH` | *required* | Pre-backup only; name in the Veeam inventory |
| `SnapClientName` | — | `Veeam` | Snapshot name before the dot |
| `SnapSuffixPrefix` | — | `Backup` | Snapshot suffix before the timestamp |
| `SnapLifetime` | — | `7d` | Duration, or `none`; see below |
| `SnapshotRootDirName` | — | `.snapshot` | Snapshot root on the share |
| `SnapshotMatchPattern` | — | `Veeam\.Backup\d{14}` | Post-backup, and pre-backup `SweepOrphans` |
| `SweepOrphans` | — | `false` | Pre-backup only; see below |
| `NoFailSafePath` | — | `false` | Pre-backup only; see below |
| `FailIfNoSnapshots` | — | `false` | Post-backup only; see below |
| `IgnoreCertificateError` | — | `true` | FlashArray TLS validation |
| `SetProcessingModeStorageSnapshot` | — | `false` | Also force the share's processing mode |
| `VBRServer` | — | `localhost` | Pre-backup only |
| `VBRUser` | `VEEAM_VBR_USER` | — | Pre-backup only; see above |
| `VBRPasswordFile` | `VEEAM_VBR_PASSWORD_FILE` | — | Pre-backup only; see above |
| `ForceAcceptTlsCertificate` | — | `true` | Pre-backup only; set `false` to validate the Veeam certificate |
| `LogDirectory` | `FA_VEEAM_LOG_DIR` | `.\log` | Transcript directory |
| `LogRetentionDays` | `FA_VEEAM_LOG_RETENTION_DAYS` | `30` | `0` disables pruning |
| — | `FA_VEEAM_CONFIG` | `.\fa-veeam-config.json` | Default configuration file location |
| — | `PUREFA_API_TOKEN` | — | Plaintext token; convenient for testing, warns when used |

### Snapshot lifetime

`SnapLifetime` is a duration: `7d`, `48h`, `1d12h`, `6h30m`, `90m`, or `none` for no expiry.
FlashArray accepts **5m to 365d**, and anything outside that is rejected before the array is
contacted. A bare number is rejected too, since its unit would be ambiguous.

The lifetime is a **safety net, not the cleanup mechanism**. The post-backup script destroys the
snapshot after each job; the lifetime is what stops snapshots accumulating unnoticed when that
script does not run — a cancelled job, a restarted Veeam service, a mistyped script path. Setting
`none` is supported but means nothing reclaims the space if cleanup ever stops running.

### Failure handling

Two behaviours are worth understanding together, because they are the reason the defaults are what
they are.

**A failing pre-job script does not stop the job.** Verified on 13.1: when the pre-backup script
timed out, the session log recorded a *warning* and carried straight on to building the task list.

```
ESucceeded  Job started at 21.08.2026 13:23:08
  EWarning  Pre-job script timed out
ESucceeded  Building tasks list
   EFailed  Processing 192.168.202.95:/... Error: Cannot find a storage snapshot at the
            specified path, and failover to direct backup from the file share is disabled
```

The job failed at the *second* step, not the first. The exit code bought nothing; the dead path did
the work. Everything below follows from that.

**Between runs, the share points at a destroyed snapshot.** That is deliberate — it is what made the
run above fail instead of quietly backing up the previous snapshot and reporting success.

**The scripts always set `EnableDirectBackupFailover = $false`.** Note the second half of that error
message. With failover enabled, a missing snapshot path does not fail the job: Veeam falls back to
reading the *live* share, so the job succeeds while doing something other than what it was
configured to do. Backup from storage snapshot is the point of these scripts, so the failover is
turned off and a missing snapshot stays a failure.

**If the pre-backup script fails, it points the share at a non-existent path on the way out** (a
`__veeam-pre-backup-failed-<timestamp>__` sentinel) for the same reason. This closes the remaining
gap: if the previous snapshot still exists — the post-backup script did not run, or a job ran twice
— the path from the last run is still valid, and without the sentinel the job would read stale data
and report success. `-NoFailSafePath` disables it, which is only safe if you are watching for
pre-script warnings in the session log yourself.

The consequence to be aware of: **starting the job without the pre-backup script will fail**, by
design. Run the pre-backup script first, or use `-WhatIf` to see what it would set.

**A Veeam session that cannot be established is fatal.** If `Connect-VBRServer` fails and there is
demonstrably no existing session, the script stops immediately rather than carrying on. Continuing
is worse: the next Veeam cmdlet typically blocks until Veeam's own **15-minute script timeout**
kills the run, leaving a job that hangs for a quarter of an hour and a log that stops mid-sentence.
The error names the account the script ran as, since a missing Veeam role is a common cause —
scripts run as the Veeam Backup Service account, often the machine account (`DOMAIN\HOST$`).

`-SweepOrphans` on the pre-backup script destroys older matching snapshots after Veeam has been
repointed. With the default lifecycle the post-backup script has already removed the previous
snapshot, so anything it finds is a leftover from a run whose cleanup never completed.

### Invocation notes

**Pass every setting by name.** The scripts declare `PositionalBinding = $false`, so a stray
positional argument is an immediate error rather than something that quietly binds to whichever
parameter happens to be next. A doubled script path in the Veeam job's script field would otherwise
land in `-Endpoint`.

**Use absolute paths for `-ConfigFile`.** Veeam launches job scripts with an unpredictable working
directory. A relative path that misses is retried next to the script, with a warning, but an
absolute path avoids the guesswork.

### Things worth knowing

* **A fixed, reusable snapshot name is not practical here.** A destroyed FlashArray snapshot keeps
  its name until it is eradicated, so reusing one name every run would require eradicating on
  every run — which is blocked on SafeMode-enabled arrays and leaves no recovery window. Hence the
  timestamped names and the per-run path update.
* **The post-backup script exits `0` when it finds nothing to destroy.** That is the normal
  outcome once a snapshot has aged out through its lifespan, and failing the Veeam job over it
  would be misleading. Pass `-FailIfNoSnapshots` to treat it as an error instead.
* **Snapshots are destroyed, not eradicated,** so they stay recoverable until the array's
  eradication delay expires. Since the pre-backup script also sets a lifespan, you can skip the
  post-backup script entirely and let snapshots expire.
* **After the post-backup script runs, the Veeam share configuration still points at the
  destroyed path** until the next successful pre-backup run. If a pre-backup run fails, the job
  will try to read a path that no longer exists — which is why the pre-backup script resolves the
  Veeam share *before* it creates a snapshot, and returns a non-zero exit code on any failure.
* **Transcripts** land in `log\<profile>-<timestamp>-<pre|post>.log` beside the script and are
  pruned after `LogRetentionDays`. They record progress but never the API token. The profile is
  the configuration file's base name, so a plain alphabetical sort groups a job's transcripts
  together and keeps each run's pre and post next to each other:

  ```
  mucfa75-nas-20260821134519-pre.log
  mucfa75-nas-20260821134740-post.log
  mucfa75-smb-20260821140002-pre.log
  mucfa75-smb-20260821140233-post.log
  ```

  Runs configured entirely from parameters and the environment have no profile name and use
  `default`. Pruning is per profile, so one job's retention never touches another's transcripts.

### Tests

The `fa-*` scripts have a test suite that needs no FlashArray and no Veeam server:

```powershell
pwsh -NoProfile -File .\tests\Invoke-Tests.ps1
```

See [tests/README.md](tests/README.md). The DPAPI parts are Windows-only and report `SKIP`
elsewhere, so run it once on the Veeam server too.

## License

Licensed under the Apache License, Version 2.0 -- see [LICENSE](../LICENSE) and
[NOTICE](../NOTICE) in the repository root. Copyright 2026 Everpure, Inc.

Each script also carries the AS IS disclaimer in its header. That is in addition to, not
instead of, the warranty disclaimer in sections 7 and 8 of the license.
