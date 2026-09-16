# Copyright 2026 Everpure, Inc.
# SPDX-License-Identifier: Apache-2.0

<#
.SYNOPSIS
	End-to-end tests for the fa-file pre/post backup scripts. No FlashArray or Veeam server
	required.

.DESCRIPTION
	Runs the real scripts in a child PowerShell process against stub PureStoragePowerShellSDK2 and
	Veeam.Backup.PowerShell modules injected via PSModulePath. The stubs record every call to a
	JSON-lines file, so the tests can assert on which cmdlet was invoked with which arguments.

	This is what proves the SMB/NFS dispatch, the exit codes, the -WhatIf behaviour and the
	fail-safe path, none of which the unit tests exercise end to end.

.EXAMPLE
	.\Test-FaFileScripts.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'TestHelper.ps1')
Reset-TestCounters

$projectRoot = Split-Path -Parent $PSScriptRoot
$psHost = Get-PowerShellHostPath

$root = Join-Path ([System.IO.Path]::GetTempPath()) ('faveeam-e2e-' + [System.Guid]::NewGuid().ToString('N'))
$modules = Join-Path $root 'Modules'
$work = Join-Path $root 'work'
$callLog = Join-Path $root 'calls.jsonl'
New-Item -ItemType Directory -Path $work -Force | Out-Null

try {
	# Copy the scripts under test into a scratch directory so their log/ folder is not created
	# inside the repository.
	foreach ($file in 'PureVeeamFA.psm1', 'fa-file-veeam-snapshot-pre-backup.ps1', 'fa-file-veeam-snapshot-post-backup.ps1') {
		Copy-Item (Join-Path $projectRoot $file) $work
	}

	# ---- Stub PureStoragePowerShellSDK2 -----------------------------------------------------
	# AppendAllText rather than Add-Content: Add-Content honours -WhatIf, which would silently
	# suppress the stub's own call log during the -WhatIf test cases.
	$sdkDir = Join-Path $modules 'PureStoragePowerShellSDK2'
	New-Item -ItemType Directory -Path $sdkDir -Force | Out-Null
	@"
`$script:CallLog = '$callLog'
function Write-Call(`$name, `$data) {
    [System.IO.File]::AppendAllText(`$script:CallLog, ((@{ Cmdlet = `$name; Data = `$data } | ConvertTo-Json -Compress -Depth 5) + [Environment]::NewLine))
}
function Connect-Pfa2Array {
    param([string]`$Endpoint, [string]`$ApiToken, `$Credential, [switch]`$IgnoreCertificateError, `$ErrorAction)
    Write-Call 'Connect-Pfa2Array' @{ Endpoint = `$Endpoint; HasToken = [bool]`$ApiToken
        TokenLooksRight = (`$ApiToken -eq 'T-0KEN-VALUE'); IgnoreCert = `$IgnoreCertificateError.IsPresent }
    if (`$env:FAKE_FA_FAIL_CONNECT) { throw 'simulated connect failure' }
    [pscustomobject]@{ Endpoint = `$Endpoint }
}
function New-Pfa2DirectorySnapshot {
    param(`$Array, [string]`$SourceNames, [long]`$KeepFor, [string]`$ClientName, [string]`$Suffix, `$ErrorAction)
    Write-Call 'New-Pfa2DirectorySnapshot' @{ SourceNames = `$SourceNames
        KeepForPassed = `$PSBoundParameters.ContainsKey('KeepFor'); KeepFor = `$KeepFor
        ClientName = `$ClientName; Suffix = `$Suffix }
    [pscustomobject]@{ Name = "`$SourceNames.`$ClientName.`$Suffix" }
}
function Get-Pfa2DirectorySnapshot {
    param(`$Array, [string]`$SourceNames, `$ErrorAction)
    Write-Call 'Get-Pfa2DirectorySnapshot' @{ SourceNames = `$SourceNames }
    if (`$env:FAKE_FA_NO_SNAPS) { return @() }
    @(
        [pscustomobject]@{ Name = "`$SourceNames.Veeam.Backup20260817093153"; Id = 'id-1'; Destroyed = `$false }
        [pscustomobject]@{ Name = "`$SourceNames.Veeam.Backup20260816093153"; Id = 'id-2'; Destroyed = `$true  }
        [pscustomobject]@{ Name = "`$SourceNames.someone-else-snap";          Id = 'id-3'; Destroyed = `$false }
    )
}
function Update-Pfa2DirectorySnapshot {
    param(`$Array, [string]`$Ids, [switch]`$Destroyed, `$ErrorAction)
    Write-Call 'Update-Pfa2DirectorySnapshot' @{ Ids = `$Ids; Destroyed = `$Destroyed.IsPresent }
}
function Get-Pfa2Array { param(`$Array, `$ErrorAction); [pscustomobject]@{ Name = 'fake-array'; Version = '6.8.0' } }
Export-ModuleMember -Function Connect-Pfa2Array, New-Pfa2DirectorySnapshot, Get-Pfa2DirectorySnapshot, Update-Pfa2DirectorySnapshot, Get-Pfa2Array
"@ | Set-Content (Join-Path $sdkDir 'PureStoragePowerShellSDK2.psm1')

	# ---- Stub Veeam.Backup.PowerShell -------------------------------------------------------
	$vbrDir = Join-Path $modules 'Veeam.Backup.PowerShell'
	New-Item -ItemType Directory -Path $vbrDir -Force | Out-Null
	@"
`$script:CallLog = '$callLog'
function Write-Call(`$name, `$data) {
    [System.IO.File]::AppendAllText(`$script:CallLog, ((@{ Cmdlet = `$name; Data = `$data } | ConvertTo-Json -Compress -Depth 5) + [Environment]::NewLine))
}
Add-Type -TypeDefinition @'
namespace Veeam.Backup.PowerShell.Infos {
    public class VBRNASSMBServer { public string Name { get; set; } }
    public class VBRNASNFSServer { public string Name { get; set; } }
}
'@
function Connect-VBRServer {
    param([string]`$Server, `$Credential, [switch]`$ForceAcceptTlsCertificate, `$ErrorAction)
    Write-Call 'Connect-VBRServer' @{ Server = `$Server
        HasCredential = [bool]`$Credential
        UserName = if (`$Credential) { `$Credential.UserName } else { '' }
        Password = if (`$Credential) { `$Credential.GetNetworkCredential().Password } else { '' }
        ForceTls = `$ForceAcceptTlsCertificate.IsPresent }
    if (`$env:FAKE_VBR_FAIL_CONNECT) { throw 'Failed to connect to Identity service' }
}
function Get-VBRServerSession { `$null }
function Disconnect-VBRServer { param(`$ErrorAction) }
function Get-VBRUnstructuredServer {
    param([string[]]`$Name, `$ErrorAction)
    Write-Call 'Get-VBRUnstructuredServer' @{ Name = `$Name }
    if (`$Name[0] -eq 'NOTHING') { return @() }
    if (`$Name[0] -like '*:/*') { return [Veeam.Backup.PowerShell.Infos.VBRNASNFSServer]@{ Name = `$Name[0] } }
    [Veeam.Backup.PowerShell.Infos.VBRNASSMBServer]@{ Name = `$Name[0] }
}
function Set-VBRNASSMBServer {
    param(`$Server, [string]`$StorageSnapshotPath, [switch]`$EnableDirectBackupFailover, [string]`$ProcessingMode, `$ErrorAction)
    Write-Call 'Set-VBRNASSMBServer' @{ Path = `$StorageSnapshotPath; Mode = `$ProcessingMode }
}
function Set-VBRNASNFSServer {
    param(`$Server, [string]`$StorageSnapshotPath, [switch]`$EnableDirectBackupFailover, [string]`$ProcessingMode, `$ErrorAction)
    Write-Call 'Set-VBRNASNFSServer' @{ Path = `$StorageSnapshotPath; Mode = `$ProcessingMode }
}
Export-ModuleMember -Function Connect-VBRServer, Disconnect-VBRServer, Get-VBRServerSession, Get-VBRUnstructuredServer, Set-VBRNASSMBServer, Set-VBRNASNFSServer
"@ | Set-Content (Join-Path $vbrDir 'Veeam.Backup.PowerShell.psm1')

	# ---- Token file. CliXml, because DPAPI is Windows-only and this must run anywhere. -------
	$tokenFile = Join-Path $work 'fa01.clixml'
	ConvertTo-SecureString 'T-0KEN-VALUE' -AsPlainText -Force | Export-Clixml -Path $tokenFile

	function Invoke-ScriptUnderTest {
		param(
			[Parameter(Mandatory)] [string] $ScriptName,
			[string[]] $ScriptArgs = @(),
			[hashtable] $ExtraEnvironment = @{}
		)
		if (Test-Path $callLog) { Remove-Item $callLog }
		$savedModulePath = $env:PSModulePath
		$env:PSModulePath = $modules + [System.IO.Path]::PathSeparator + $env:PSModulePath
		foreach ($key in $ExtraEnvironment.Keys) { Set-Item -Path "Env:$key" -Value $ExtraEnvironment[$key] }
		try {
			$output = & $psHost -NoProfile -File (Join-Path $work $ScriptName) @ScriptArgs 2>&1 | Out-String
			$code = $LASTEXITCODE
		} finally {
			$env:PSModulePath = $savedModulePath
			foreach ($key in $ExtraEnvironment.Keys) { Remove-Item -Path "Env:$key" -ErrorAction SilentlyContinue }
		}
		$calls = @()
		if (Test-Path $callLog) { $calls = @(Get-Content $callLog | ForEach-Object { $_ | ConvertFrom-Json }) }
		return [pscustomobject]@{ ExitCode = $code; Output = $output; Calls = $calls }
	}
	function Get-Call { param($Result, [string]$Name); $Result.Calls | Where-Object { $_.Cmdlet -eq $Name } | Select-Object -First 1 }
	function Get-Calls { param($Result, [string]$Name); @($Result.Calls | Where-Object { $_.Cmdlet -eq $Name }) }

	# ---- Configuration files ----------------------------------------------------------------
	@{ Endpoint = 'fa01.lab.local'; ApiTokenFile = $tokenFile
		SnapDirectory = 'user-shares01::user-shares01:lab-files'
		FileSharePath = '\\172.16.16.15\lab-files' } | ConvertTo-Json | Set-Content (Join-Path $work 'smb.json')
	@{ Endpoint = 'fa01.lab.local'; ApiTokenFile = $tokenFile
		SnapDirectory = 'user-shares01::user-shares01:lab-nfs'
		FileSharePath = '172.16.16.15:/lab-nfs' } | ConvertTo-Json | Set-Content (Join-Path $work 'nfs.json')
	@{ Endpoint = 'fa01.lab.local'; ApiTokenFile = $tokenFile
		SnapDirectory = 'user-shares01::user-shares01:lab-files'
		FileSharePath = 'NOTHING' } | ConvertTo-Json | Set-Content (Join-Path $work 'missingshare.json')
	@{ Endpoint = 'fa01.lab.local'; ApiTokenFile = $tokenFile
		SnapDirectory = 'user-shares01::user-shares01:lab-files'
		FileSharePath = '\\172.16.16.15\lab-files'
		ForceAcceptTlsCertificate = $false } | ConvertTo-Json | Set-Content (Join-Path $work 'stricttls.json')
	$smbConfig = Join-Path $work 'smb.json'
	$nfsConfig = Join-Path $work 'nfs.json'

	# =========================================================================================
	Write-TestSection 'pre-backup, SMB share, via configuration file'
	$r = Invoke-ScriptUnderTest 'fa-file-veeam-snapshot-pre-backup.ps1' @('-ConfigFile', $smbConfig)
	Assert-Equal 'exit code' $r.ExitCode 0
	Assert-Equal 'token unwrapped correctly'  (Get-Call $r 'Connect-Pfa2Array').Data.TokenLooksRight 'True'
	Assert-Equal 'IgnoreCert defaults to true' (Get-Call $r 'Connect-Pfa2Array').Data.IgnoreCert 'True'
	Assert-Equal 'snapshot ClientName'        (Get-Call $r 'New-Pfa2DirectorySnapshot').Data.ClientName 'Veeam'
	Assert-Equal 'default lifetime is 7d'     (Get-Call $r 'New-Pfa2DirectorySnapshot').Data.KeepFor 604800000
	Assert-Equal 'suffix shape' ([bool]((Get-Call $r 'New-Pfa2DirectorySnapshot').Data.Suffix -match '^Backup\d{14}$')) 'True'
	Assert-Equal 'SMB cmdlet used' ([bool](Get-Call $r 'Set-VBRNASSMBServer')) 'True'
	Assert-Equal 'SMB snapshot path' ([bool]((Get-Call $r 'Set-VBRNASSMBServer').Data.Path -match '^\\\\172\.16\.16\.15\\lab-files\\\.snapshot\\Veeam\.Backup\d{14}$')) 'True'
	Assert-Equal 'token absent from output' ([bool]($r.Output -match 'T-0KEN')) 'False'

	Write-TestSection 'pre-backup, NFS export'
	$r = Invoke-ScriptUnderTest 'fa-file-veeam-snapshot-pre-backup.ps1' @('-ConfigFile', $nfsConfig)
	Assert-Equal 'exit code' $r.ExitCode 0
	Assert-Equal 'NFS cmdlet used'      ([bool](Get-Call $r 'Set-VBRNASNFSServer')) 'True'
	Assert-Equal 'SMB cmdlet not used'  ([bool](Get-Call $r 'Set-VBRNASSMBServer')) 'False'
	Assert-Equal 'NFS snapshot path uses forward slashes' ([bool]((Get-Call $r 'Set-VBRNASNFSServer').Data.Path -match '^172\.16\.16\.15:/lab-nfs/\.snapshot/Veeam\.Backup\d{14}$')) 'True'

	Write-TestSection 'pre-backup, SnapLifetime handling'
	$r = Invoke-ScriptUnderTest 'fa-file-veeam-snapshot-pre-backup.ps1' @('-ConfigFile', $nfsConfig, '-SnapLifetime', '48h')
	Assert-Equal 'exit code' $r.ExitCode 0
	Assert-Equal '48h reaches the array as ms' (Get-Call $r 'New-Pfa2DirectorySnapshot').Data.KeepFor 172800000

	$r = Invoke-ScriptUnderTest 'fa-file-veeam-snapshot-pre-backup.ps1' @('-ConfigFile', $nfsConfig, '-SnapLifetime', '6h30m')
	Assert-Equal '6h30m reaches the array as ms' (Get-Call $r 'New-Pfa2DirectorySnapshot').Data.KeepFor 23400000

	$r = Invoke-ScriptUnderTest 'fa-file-veeam-snapshot-pre-backup.ps1' @('-ConfigFile', $nfsConfig, '-SnapLifetime', 'none')
	Assert-Equal 'exit code' $r.ExitCode 0
	Assert-Equal "'none' omits KeepFor entirely" (Get-Call $r 'New-Pfa2DirectorySnapshot').Data.KeepForPassed 'False'
	Assert-Equal 'no-expiry is reported' ([bool]($r.Output -match 'no expiry')) 'True'

	$r = Invoke-ScriptUnderTest 'fa-file-veeam-snapshot-pre-backup.ps1' @('-ConfigFile', $nfsConfig, '-SnapLifetime', '604800000')
	Assert-Equal 'bare number exits 1' $r.ExitCode 1
	Assert-Equal 'bare number explains itself' ([bool]($r.Output -match 'has no unit')) 'True'
	Assert-Equal 'nothing created on a bad lifetime' ([bool](Get-Call $r 'New-Pfa2DirectorySnapshot')) 'False'
	Assert-Equal 'lifetime is validated before the array is touched' ([bool](Get-Call $r 'Connect-Pfa2Array')) 'False'

	$r = Invoke-ScriptUnderTest 'fa-file-veeam-snapshot-pre-backup.ps1' @('-ConfigFile', $nfsConfig, '-SnapLifetime', '30s')
	Assert-Equal 'below-minimum lifetime exits 1' $r.ExitCode 1
	Assert-Equal 'range is explained' ([bool]($r.Output -match 'outside the range')) 'True'

	Write-TestSection 'pre-backup, -WhatIf'
	$r = Invoke-ScriptUnderTest 'fa-file-veeam-snapshot-pre-backup.ps1' @('-ConfigFile', $nfsConfig, '-WhatIf')
	Assert-Equal 'exit code' $r.ExitCode 0
	Assert-Equal 'no snapshot created'   ([bool](Get-Call $r 'New-Pfa2DirectorySnapshot')) 'False'
	Assert-Equal 'no Veeam change made'  ([bool](Get-Call $r 'Set-VBRNASNFSServer')) 'False'
	Assert-Equal 'share still looked up' ([bool](Get-Call $r 'Get-VBRUnstructuredServer')) 'True'

	Write-TestSection 'pre-backup, settings from parameters only'
	$r = Invoke-ScriptUnderTest 'fa-file-veeam-snapshot-pre-backup.ps1' @(
		'-Endpoint', 'fa02.lab.local', '-ApiTokenFile', $tokenFile,
		'-SnapDirectory', 'd::d:e', '-FileSharePath', '10.0.0.9:/exp',
		'-SnapClientName', 'VeeamX', '-SnapSuffixPrefix', 'Job', '-SnapLifetime', '90m',
		'-SetProcessingModeStorageSnapshot')
	Assert-Equal 'exit code' $r.ExitCode 0
	Assert-Equal 'endpoint from parameter' (Get-Call $r 'Connect-Pfa2Array').Data.Endpoint 'fa02.lab.local'
	Assert-Equal 'client name override'    (Get-Call $r 'New-Pfa2DirectorySnapshot').Data.ClientName 'VeeamX'
	Assert-Equal 'lifetime override'       (Get-Call $r 'New-Pfa2DirectorySnapshot').Data.KeepFor 5400000
	Assert-Equal 'processing mode set'     (Get-Call $r 'Set-VBRNASNFSServer').Data.Mode 'StorageSnapshot'
	Assert-Equal 'custom name in path' ([bool]((Get-Call $r 'Set-VBRNASNFSServer').Data.Path -match '/\.snapshot/VeeamX\.Job\d{14}$')) 'True'

	Write-TestSection 'pre-backup, settings from environment'
	$r = Invoke-ScriptUnderTest 'fa-file-veeam-snapshot-pre-backup.ps1' @() @{
		PUREFA_ENDPOINT = 'fa03.lab.local'; PUREFA_API_TOKEN_FILE = $tokenFile
		PUREFA_SNAP_DIRECTORY = 'd::d:e'; VEEAM_FILE_SHARE_PATH = '\\host\sh' }
	Assert-Equal 'exit code' $r.ExitCode 0
	Assert-Equal 'endpoint from environment' (Get-Call $r 'Connect-Pfa2Array').Data.Endpoint 'fa03.lab.local'

	Write-TestSection 'pre-backup, -SweepOrphans'
	$r = Invoke-ScriptUnderTest 'fa-file-veeam-snapshot-pre-backup.ps1' @('-ConfigFile', $smbConfig, '-SweepOrphans')
	Assert-Equal 'exit code' $r.ExitCode 0
	$destroys = Get-Calls $r 'Update-Pfa2DirectorySnapshot'
	Assert-Equal 'destroyed the one live orphan' $destroys.Count 1
	Assert-Equal 'destroyed the right snapshot'  $destroys[0].Data.Ids 'id-1'
	Assert-Equal 'left the non-matching snapshot alone' ([bool]($r.Output -match 'someone-else-snap')) 'False'
	Assert-Equal 'swept only after repointing Veeam' ([bool](Get-Call $r 'Set-VBRNASSMBServer')) 'True'

	$r = Invoke-ScriptUnderTest 'fa-file-veeam-snapshot-pre-backup.ps1' @('-ConfigFile', $smbConfig)
	Assert-Equal 'no sweep unless asked' ([bool](Get-Call $r 'Update-Pfa2DirectorySnapshot')) 'False'

	Write-TestSection 'pre-backup, failure paths and the fail-safe'
	$r = Invoke-ScriptUnderTest 'fa-file-veeam-snapshot-pre-backup.ps1' @('-ApiTokenFile', $tokenFile)
	Assert-Equal 'missing required setting exits 1' $r.ExitCode 1
	Assert-Equal 'names the missing setting' ([bool]($r.Output -match "Required setting 'Endpoint' was not supplied")) 'True'

	$r = Invoke-ScriptUnderTest 'fa-file-veeam-snapshot-pre-backup.ps1' @('-ConfigFile', (Join-Path $work 'missingshare.json'))
	Assert-Equal 'unknown share exits 1' $r.ExitCode 1
	Assert-Equal 'no orphan snapshot created' ([bool](Get-Call $r 'New-Pfa2DirectorySnapshot')) 'False'
	Assert-Equal 'explains the share name' ([bool]($r.Output -match 'No unstructured data source named')) 'True'

	# Connect-Pfa2Array fails after the share has been resolved, so the fail-safe should fire.
	$r = Invoke-ScriptUnderTest 'fa-file-veeam-snapshot-pre-backup.ps1' @('-ConfigFile', $smbConfig) @{ FAKE_FA_FAIL_CONNECT = '1' }
	Assert-Equal 'FlashArray failure exits 1' $r.ExitCode 1
	$failSafe = Get-Call $r 'Set-VBRNASSMBServer'
	Assert-Equal 'fail-safe repointed the share' ([bool]$failSafe) 'True'
	Assert-Equal 'fail-safe path is the sentinel' ([bool]($failSafe.Data.Path -match '__veeam-pre-backup-failed-\d{14}__$')) 'True'
	Assert-Equal 'fail-safe is announced' ([bool]($r.Output -match 'Fail-safe applied')) 'True'

	$r = Invoke-ScriptUnderTest 'fa-file-veeam-snapshot-pre-backup.ps1' @('-ConfigFile', $smbConfig, '-NoFailSafePath') @{ FAKE_FA_FAIL_CONNECT = '1' }
	Assert-Equal '-NoFailSafePath still exits 1' $r.ExitCode 1
	Assert-Equal '-NoFailSafePath leaves the path alone' ([bool](Get-Call $r 'Set-VBRNASSMBServer')) 'False'

	# Carrying on without a session leaves the next Veeam cmdlet to block until Veeam's own
	# 15-minute script timeout kills the job, so a failed connect has to be fatal here.
	Write-TestSection 'pre-backup, Veeam session cannot be established'
	$r = Invoke-ScriptUnderTest 'fa-file-veeam-snapshot-pre-backup.ps1' @('-ConfigFile', $smbConfig) @{ FAKE_VBR_FAIL_CONNECT = '1' }
	Assert-Equal 'fails fast instead of continuing' $r.ExitCode 1
	Assert-Equal 'surfaces the underlying Veeam error' ([bool]($r.Output -match 'Failed to connect to Identity service')) 'True'
	Assert-Equal 'names the account it ran as' ([bool]($r.Output -match 'running as')) 'True'
	Assert-Equal 'does not go on to query the inventory' ([bool](Get-Call $r 'Get-VBRUnstructuredServer')) 'False'
	Assert-Equal 'does not touch the array' ([bool](Get-Call $r 'Connect-Pfa2Array')) 'False'

	Write-TestSection 'pre-backup, explicit Veeam credential'
	$vbrPassword = Join-Path $work 'vbr.clixml'
	ConvertTo-SecureString 'vbr-secret' -AsPlainText -Force | Export-Clixml -Path $vbrPassword
	$r = Invoke-ScriptUnderTest 'fa-file-veeam-snapshot-pre-backup.ps1' @(
		'-ConfigFile', $smbConfig,
		'-VBRUser', 'CXC-VEEAM-VBR\veeam-automation', '-VBRPasswordFile', $vbrPassword,
		'-ForceAcceptTlsCertificate')
	Assert-Equal 'exit code' $r.ExitCode 0
	$connect = Get-Call $r 'Connect-VBRServer'
	Assert-Equal 'credential was passed'      $connect.Data.HasCredential 'True'
	Assert-Equal 'user name reached Veeam'    $connect.Data.UserName 'CXC-VEEAM-VBR\veeam-automation'
	Assert-Equal 'password was decrypted'     $connect.Data.Password 'vbr-secret'
	Assert-Equal 'TLS override was passed'    $connect.Data.ForceTls 'True'
	Assert-Equal 'preflight reports the target' ([bool]($r.Output -match 'Veeam connection preflight')) 'True'
	Assert-Equal 'preflight names the credential' ([bool]($r.Output -match "explicit credential 'CXC-VEEAM-VBR\\veeam-automation'")) 'True'
	Assert-Equal 'Veeam password absent from output' ([bool]($r.Output -match 'vbr-secret')) 'False'

	$r = Invoke-ScriptUnderTest 'fa-file-veeam-snapshot-pre-backup.ps1' @('-ConfigFile', $smbConfig)
	$connect = Get-Call $r 'Connect-VBRServer'
	Assert-Equal 'no credential when unconfigured' $connect.Data.HasCredential 'False'
	Assert-Equal 'preflight names the inherited identity' ([bool]($r.Output -match 'inherited identity')) 'True'

	# Accepting the certificate is the default: a stock Veeam server presents a self-signed one,
	# and the prompt Connect-VBRServer would otherwise raise is unanswerable under the service.
	Assert-Equal 'TLS certificate accepted by default' $connect.Data.ForceTls 'True'
	Assert-Equal 'preflight says so' ([bool]($r.Output -match 'accepted without validation')) 'True'

	$r = Invoke-ScriptUnderTest 'fa-file-veeam-snapshot-pre-backup.ps1' @('-ConfigFile', (Join-Path $work 'stricttls.json'))
	$connect = Get-Call $r 'Connect-VBRServer'
	Assert-Equal 'config false turns validation back on' $connect.Data.ForceTls 'False'

	$r = Invoke-ScriptUnderTest 'fa-file-veeam-snapshot-pre-backup.ps1' @(
		'-ConfigFile', $smbConfig, '-VBRPasswordFile', $vbrPassword)
	Assert-Equal 'password file without user name exits 1' $r.ExitCode 1
	Assert-Equal 'and says which setting is missing' ([bool]($r.Output -match 'no user name')) 'True'

	Write-TestSection 'pre-backup, stray positional argument is rejected'
	# A doubled script path in the Veeam job's script field is an easy typo to make. Without
	# PositionalBinding = $false the stray argument binds to -Endpoint and the run continues with a
	# filename as the FlashArray address.
	$r = Invoke-ScriptUnderTest 'fa-file-veeam-snapshot-pre-backup.ps1' @('.\fa-file-veeam-snapshot-pre-backup.ps1', '-ConfigFile', $smbConfig)
	Assert-Equal 'positional argument exits non-zero' ([bool]($r.ExitCode -ne 0)) 'True'
	Assert-Equal 'complains about the positional parameter' ([bool]($r.Output -match 'positional parameter cannot be found')) 'True'
	Assert-Equal 'no snapshot created' ([bool](Get-Call $r 'New-Pfa2DirectorySnapshot')) 'False'

	Write-TestSection 'pre-backup, configuration file path is logged'
	$r = Invoke-ScriptUnderTest 'fa-file-veeam-snapshot-pre-backup.ps1' @('-ConfigFile', $smbConfig)
	Assert-Equal 'config path appears in the transcript-visible summary' ([bool]($r.Output -match [regex]::Escape($smbConfig))) 'True'
	$r = Invoke-ScriptUnderTest 'fa-file-veeam-snapshot-pre-backup.ps1' @(
		'-Endpoint', 'fa02.lab.local', '-ApiTokenFile', $tokenFile,
		'-SnapDirectory', 'd::d:e', '-FileSharePath', '10.0.0.9:/exp')
	Assert-Equal 'absence of a config file is stated' ([bool]($r.Output -match 'parameters and environment only')) 'True'

	# =========================================================================================
	Write-TestSection 'post-backup'
	$r = Invoke-ScriptUnderTest 'fa-file-veeam-snapshot-post-backup.ps1' @('-ConfigFile', $smbConfig)
	Assert-Equal 'exit code' $r.ExitCode 0
	$destroys = Get-Calls $r 'Update-Pfa2DirectorySnapshot'
	Assert-Equal 'destroyed exactly the live match' $destroys.Count 1
	Assert-Equal 'destroyed the right snapshot'     $destroys[0].Data.Ids 'id-1'
	Assert-Equal 'Destroyed flag was set'          $destroys[0].Data.Destroyed 'True'
	Assert-Equal 'reported the already-destroyed one' ([bool]($r.Output -match 'was already destroyed')) 'True'
	Assert-Equal 'left the non-matching snapshot alone' ([bool]($r.Output -match 'someone-else-snap')) 'False'

	Write-TestSection 'post-backup, -WhatIf'
	$r = Invoke-ScriptUnderTest 'fa-file-veeam-snapshot-post-backup.ps1' @('-ConfigFile', $smbConfig, '-WhatIf')
	Assert-Equal 'exit code' $r.ExitCode 0
	Assert-Equal 'destroyed nothing' ([bool](Get-Call $r 'Update-Pfa2DirectorySnapshot')) 'False'

	Write-TestSection 'post-backup, nothing to clean up'
	$r = Invoke-ScriptUnderTest 'fa-file-veeam-snapshot-post-backup.ps1' @('-ConfigFile', $smbConfig) @{ FAKE_FA_NO_SNAPS = '1' }
	Assert-Equal 'exits 0 by default' $r.ExitCode 0
	Assert-Equal 'warns instead' ([bool]($r.Output -match 'Nothing to clean up')) 'True'

	$r = Invoke-ScriptUnderTest 'fa-file-veeam-snapshot-post-backup.ps1' @('-ConfigFile', $smbConfig, '-FailIfNoSnapshots') @{ FAKE_FA_NO_SNAPS = '1' }
	Assert-Equal 'exits 1 with -FailIfNoSnapshots' $r.ExitCode 1

	$r = Invoke-ScriptUnderTest 'fa-file-veeam-snapshot-post-backup.ps1' @('-ConfigFile', $smbConfig, '-SnapshotMatchPattern', 'NoSuchPattern')
	Assert-Equal 'a pattern matching nothing exits 0' $r.ExitCode 0
	Assert-Equal 'and destroys nothing' ([bool](Get-Call $r 'Update-Pfa2DirectorySnapshot')) 'False'

	Write-TestSection '-WhatIf is forwarded to every state-changing module call'
	# Asserted against the source rather than through the mocks, because the mocks cannot see this:
	# $WhatIfPreference crosses the module boundary on PowerShell 7.6 but not on 7.4, so a run
	# under the mocks can suppress the call while the same script on a 7.4 server does not.
	# Explicit -WhatIf:$WhatIfPreference is the only version-proof form.
	$stateChanging = @('Set-PureVeeamStorageSnapshotPath', 'Remove-PureFADirectorySnapshotMatch')
	foreach ($scriptName in @('fa-file-veeam-snapshot-pre-backup.ps1', 'fa-file-veeam-snapshot-post-backup.ps1')) {
		$ast = [System.Management.Automation.Language.Parser]::ParseFile(
			(Join-Path $projectRoot $scriptName), [ref]$null, [ref]$null)
		$calls = @($ast.FindAll({
					param($node)
					$node -is [System.Management.Automation.Language.CommandAst] -and
					$node.GetCommandName() -in $stateChanging
				}, $true))
		Assert-Equal "$scriptName calls the module" ([bool]($calls.Count -gt 0)) 'True'
		foreach ($call in $calls) {
			$forwarded = @($call.CommandElements | Where-Object {
					$_ -is [System.Management.Automation.Language.CommandParameterAst] -and
					$_.ParameterName -eq 'WhatIf'
				}).Count -gt 0
			Assert-Equal "$($call.GetCommandName()) at line $($call.Extent.StartLineNumber) forwards -WhatIf" ([bool]$forwarded) 'True'
		}
	}

	Write-TestSection 'transcripts'
	$logs = @(Get-ChildItem (Join-Path $work 'log') -Filter '*.log' -ErrorAction SilentlyContinue)
	Assert-Equal 'transcripts were written' ([bool]($logs.Count -gt 0)) 'True'

	# Named after the configuration file, so a directory listing groups a job's runs together.
	Assert-Equal 'pre-backup transcripts carry the profile and phase' `
		([bool](@($logs | Where-Object { $_.Name -match '^smb-\d{14}-pre\.log$' }).Count -gt 0)) 'True'
	Assert-Equal 'post-backup transcripts carry the profile and phase' `
		([bool](@($logs | Where-Object { $_.Name -match '^smb-\d{14}-post\.log$' }).Count -gt 0)) 'True'
	Assert-Equal 'the NFS profile is a separate group' `
		([bool](@($logs | Where-Object { $_.Name -match '^nfs-\d{14}-pre\.log$' }).Count -gt 0)) 'True'
	$leaks = @($logs | Select-String -Pattern 'T-0KEN' -SimpleMatch)
	Assert-Equal 'no API token in any transcript' $leaks.Count 0
} finally {
	Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}

$counters = Get-TestCounters
Write-Host ''
Write-Host '---------------------------------------'
Write-Host "fa-file script end-to-end tests -- passed: $($counters.Passed)  failed: $($counters.Failed)  skipped: $($counters.Skipped)"
if ($counters.Failed -gt 0) { exit 1 }
exit 0
