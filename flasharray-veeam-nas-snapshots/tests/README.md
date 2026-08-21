# Tests

Tests for the `fa-*` FlashArray File scripts. They need **no FlashArray, no Veeam Backup &
Replication server and no third-party modules** — the FlashArray and Veeam cmdlets are stubbed, so
these are safe to run on a workstation.

```powershell
pwsh -NoProfile -File .\tests\Invoke-Tests.ps1
```

Exit code is `0` when everything passes, `1` otherwise, so this works as a CI step.

| File | What it covers |
| --- | --- |
| [Invoke-Tests.ps1](Invoke-Tests.ps1) | Runner: syntax parse of every file, both suites below, then PSScriptAnalyzer if installed |
| [Test-PureVeeamFA.ps1](Test-PureVeeamFA.ps1) | Unit tests for `PureVeeamFA.psm1` — settings precedence, config loading, duration parsing, token resolution, snapshot sweeping, SMB/NFS dispatch |
| [Test-FaFileScripts.ps1](Test-FaFileScripts.ps1) | End-to-end: runs the real scripts in a child process against stub modules, asserting on exit codes and the exact cmdlets called |
| [TestHelper.ps1](TestHelper.ps1) | Assertion helpers, deliberately dependency-free rather than Pester-based |

## How the end-to-end tests work

`Test-FaFileScripts.ps1` writes stub `PureStoragePowerShellSDK2` and `Veeam.Backup.PowerShell`
modules to a temporary directory, prepends it to `PSModulePath`, then runs the real scripts in a
child PowerShell process. Every stubbed cmdlet appends its arguments to a JSON-lines file, so the
tests assert on **which** cmdlet was called with **what** — which is how the SMB/NFS dispatch is
verified without a Veeam server.

Three details are load-bearing if you extend these:

* The stubs log with `[System.IO.File]::AppendAllText`, not `Add-Content`. `Add-Content` honours
  `-WhatIf`, which would silently suppress the log during the `-WhatIf` cases and make those tests
  pass for the wrong reason.
* Veeam inventory objects are faked with `Add-Type`, because the dispatch keys on the concrete
  .NET type name (`VBRNASSMBServer` vs `VBRNASNFSServer`). A `PSCustomObject` will not do.
* `-WhatIf` behaviour cannot be proved by these mocks alone. `$WhatIfPreference` crosses the module
  boundary on PowerShell 7.6 but not on 7.4, so a mocked run can suppress a call that the same
  script would really make on 7.4. That is why the scripts pass `-WhatIf:$WhatIfPreference`
  explicitly and a separate test asserts it from the script AST.

Similarly, `Test-PureVeeamFA.ps1` exercises settings resolution through a real
`$PSBoundParameters` rather than a `Hashtable` stand-in. The two types differ:
`PSBoundParametersDictionary` implements `IDictionary.Contains` explicitly, so only `ContainsKey`
is callable on it. A `Hashtable` exposes both and hides that difference.

## Platform coverage

The DPAPI token file and ACL hardening are Windows-only. Those tests report `SKIP` elsewhere, so a
run on macOS or Linux still covers everything else. Run the suite on the Veeam server at least once
to exercise the DPAPI round-trip.

Not covered here, because it is a property of Veeam rather than of these scripts: a failing pre-job
script does not stop an unstructured-data job. Veeam logs a warning and carries on to build the task
list, so the exit code these tests assert on is not what protects the job — the unreadable snapshot
path is. See **Failure handling** in the [main README](../README.md).
