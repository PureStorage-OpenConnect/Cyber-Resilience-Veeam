# Copyright 2026 Everpure, Inc.
# SPDX-License-Identifier: Apache-2.0

<#
.SYNOPSIS
	Integration tests against the scripted HTTP responder and the stub Veeam module: Purity
	client for both platforms, Veeam adapter for both backends, the three phases, and the
	entry script end to end in a child process. No real array or Veeam server is touched.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestHelper.ps1')
. (Join-Path $PSScriptRoot 'Stubs.ps1')
Initialize-TestCounters
$projectRoot = Split-Path -Parent $PSScriptRoot
$tmp = Get-TestDirectory

# Stub Veeam module on the module path, inventory and call log through the environment.
$stubRoot = Install-VeeamStubModule -Root (Join-Path $tmp 'modules')
$env:PSModulePath = $stubRoot + [System.IO.Path]::PathSeparator + $env:PSModulePath
$env:EVP_TEST_INVENTORY = New-LabInventoryFile -Path (Join-Path $tmp 'inventory.json')
$env:EVP_TEST_CALLLOG = Join-Path $tmp 'veeam-calls.jsonl'
$env:EVP_TEST_CONNECT_FAIL = $null
$httpLog = Join-Path $tmp 'http-calls.jsonl'

Import-Module (Join-Path $projectRoot 'EverpureVeeamNas.psd1') -Force
$platform = Get-EvpPlatform

function Reset-Logs { Remove-Item $env:EVP_TEST_CALLLOG, $httpLog -ErrorAction SilentlyContinue }
function Get-HttpCalls { Read-CallLog -Path $httpLog }
function Get-VeeamCalls { Read-CallLog -Path $env:EVP_TEST_CALLLOG }
function Use-LabMock { param($State) Set-EvpHttpInvoker (New-EvpMockResponder -Routes (New-LabRoutes -State $State) -CallLog $httpLog) }
function Get-Token([string] $Value) { ConvertTo-SecureString -String $Value -AsPlainText -Force }
# ---------------------------------------------------------------------------------------------
function Invoke-Captured([scriptblock] $ScriptBlock) {
	<# Runs a phase, returning its exit code and everything it wrote to the host as text. #>
	$all = @(& $ScriptBlock 6>&1 3>&1)
	[pscustomobject]@{ Code = ($all | Where-Object { $_ -is [int] } | Select-Object -Last 1); Text = (($all | Where-Object { $_ -isnot [int] } | ForEach-Object { "$_" }) -join "`n") }
}

$faConfig = [ordered]@{ Name = 'fa'; Endpoint = 'fa'; ApiTokenFile = ''; Platform = 'auto'; Tls = 'skip' }
$fbConfig = [ordered]@{ Name = 'fb'; Endpoint = 'fb'; ApiTokenFile = ''; Platform = 'auto'; Tls = 'skip' }

# ---------------------------------------------------------------------------------------------
Write-TestSection 'Purity client: connect and detect'
$state = New-LabState; Use-LabMock $state; Reset-Logs
$fa = Connect-EvpArray -ArrayConfig $faConfig -ApiToken (Get-Token 'fa-token') 6>$null
Assert-Equal 'FA detected'         $fa.Platform 'FlashArray'
Assert-Equal 'FA highest 2.x'      $fa.ApiVersion '2.42'
Assert-Equal 'FA login path'       ((Get-HttpCalls | Where-Object Method -eq 'POST' | Select-Object -First 1).Uri) 'https://fa/api/2.42/login'
Assert-Equal 'FA session header'   $fa.Headers['x-auth-token'] 'fa-session'
Assert-Equal 'FA array name'       $fa.ArrayName 'fa01'
Assert-True  'api-token header never logged in URL' (-not ((Get-HttpCalls).Uri -join ' ' -match 'fa-token'))
$fb = Connect-EvpArray -ArrayConfig $fbConfig -ApiToken (Get-Token 'fb-token') 6>$null
Assert-Equal 'FB detected'         $fb.Platform 'FlashBlade'
Assert-Equal 'FB login path'       ((Get-HttpCalls | Where-Object { $_.Method -eq 'POST' -and $_.Uri -like 'https://fb/*' } | Select-Object -First 1).Uri) 'https://fb/api/login'
Assert-Equal 'FB version'          $fb.ApiVersion '2.17'
Assert-Throws 'bad token is reported' { Connect-EvpArray -ArrayConfig $faConfig -ApiToken (Get-Token 'wrong') 6>$null } 'Login to .fa. failed: HTTP 401'
$wrongPlatform = [ordered]@{ Name = 'fa'; Endpoint = 'fa'; ApiTokenFile = ''; Platform = 'FlashBlade'; Tls = 'skip' }
Assert-Throws 'declared platform must match the API' { Connect-EvpArray -ArrayConfig $wrongPlatform -ApiToken (Get-Token 'fa-token') 6>$null } 'looks like FlashArray'

Write-TestSection 'Purity client: source resolution'
$smbMulti = [ordered]@{ VeeamPath = '\\192.0.2.10\shared'; Protocol = 'SMB'; Server = '192.0.2.10'; ShareName = 'shared'; Array = 'fa'; Source = 'auto' }
$nfsMulti = [ordered]@{ VeeamPath = '192.0.2.10:/shared'; Protocol = 'NFS'; Server = '192.0.2.10'; ShareName = 'shared'; Array = 'fa'; Source = 'auto' }
Assert-Equal 'FA multi SMB -> directory' (Resolve-EvpArraySource -Session $fa -Share $smbMulti).Name 'fs01:shared'
Assert-Equal 'FA multi NFS -> same directory' (Resolve-EvpArraySource -Session $fa -Share $nfsMulti).Name 'fs01:shared'
$smbOnlyAsNfs = [ordered]@{ VeeamPath = '192.0.2.10:/finance-smb'; Protocol = 'NFS'; Server = 'x'; ShareName = 'finance-smb'; Array = 'fa'; Source = 'auto' }
Assert-Throws 'FA export exists but wrong protocol' { Resolve-EvpArraySource -Session $fa -Share $smbOnlyAsNfs } 'but not for NFS'
$unknown = [ordered]@{ VeeamPath = '\\x\nope'; Protocol = 'SMB'; Server = 'x'; ShareName = 'nope'; Array = 'fa'; Source = 'auto' }
Assert-Throws 'FA unknown export' { Resolve-EvpArraySource -Session $fa -Share $unknown } 'no directory export named'
$ambiguous = [ordered]@{ VeeamPath = '\\x\ambiguous'; Protocol = 'SMB'; Server = 'x'; ShareName = 'ambiguous'; Array = 'fa'; Source = 'auto' }
Assert-Throws 'FA ambiguous export' { Resolve-EvpArraySource -Session $fa -Share $ambiguous } 'maps to 2 directories'
$explicit = [ordered]@{ VeeamPath = '\\x\whatever'; Protocol = 'SMB'; Server = 'x'; ShareName = 'whatever'; Array = 'fa'; Source = 'fs:explicit' }
Assert-Equal 'FA explicit source' (Resolve-EvpArraySource -Session $fa -Share $explicit).Name 'fs:explicit'
$fbNfs = [ordered]@{ VeeamPath = '192.0.2.20:/projects-nfs'; Protocol = 'NFS'; Server = 'x'; ShareName = 'projects-nfs'; Array = 'fb'; Source = 'auto' }
$info = Resolve-EvpArraySource -Session $fb -Share $fbNfs
Assert-Equal 'FB by file system name' $info.Name 'projects-nfs'
Assert-Equal 'FB snapshot dir flag read' $info.SnapshotDirectoryEnabled 'True'
$fbCustom = [ordered]@{ VeeamPath = '\\x\custom-share'; Protocol = 'SMB'; Server = 'x'; ShareName = 'custom-share'; Array = 'fb'; Source = 'auto' }
Assert-Equal 'FB by smb.share_name fallback' (Resolve-EvpArraySource -Session $fb -Share $fbCustom).Name 'renamed-fs'
Assert-True  'FB export looked up by export_name' (((Get-HttpCalls).Uri -join ' ') -match "file-system-exports\?filter=export_name='custom-share'")
Reset-Logs
Assert-Throws 'FB NFS export resolves to its own member' { Resolve-EvpArraySource -Session $fb -Share ([ordered]@{ VeeamPath = 'x:/custom-share'; Protocol = 'NFS'; Server = 'x'; ShareName = 'custom-share'; Array = 'fb'; Source = 'auto' }) } 'exported \(NFS\)'
Assert-True  'FB export of the other protocol ignored' (((Get-HttpCalls).Uri -join ' ') -match 'names=other-fs' -and ((Get-HttpCalls).Uri -join ' ') -notmatch 'names=renamed-fs')
$fbDup = [ordered]@{ VeeamPath = '\\x\dup-share'; Protocol = 'SMB'; Server = 'x'; ShareName = 'dup-share'; Array = 'fb'; Source = 'auto' }
Assert-Throws 'FB export name on two servers is ambiguous' { Resolve-EvpArraySource -Session $fb -Share $fbDup } 'exists for 2 file systems'
Reset-Logs
Assert-Throws 'FB unknown' { Resolve-EvpArraySource -Session $fb -Share $unknown } 'no file system named or exported \(SMB\) as'
Assert-True  'FB unknown name answered 400 and was reported, not used' (((Get-HttpCalls).Uri -join ' ') -match 'file-systems\?names=nope')
$fbQuoted = [ordered]@{ VeeamPath = "\\x\it's"; Protocol = 'SMB'; Server = 'x'; ShareName = "it's"; Array = 'fb'; Source = 'auto' }
Assert-Throws 'FB share name with a quote refused, not spliced into the filter' { Resolve-EvpArraySource -Session $fb -Share $fbQuoted } 'single quote'

Write-TestSection 'Purity client: snapshots'
Reset-Logs
$ts = '20261020T081500Z'
$faSnap = New-EvpArraySnapshot -Session $fa -SourceName 'fs:dir' -Tag 'Veeam-Backup' -Timestamp $ts -KeepForMs 14400000 6>$null
$post = Get-HttpCalls | Where-Object Method -eq 'POST' | Select-Object -Last 1
Assert-Equal 'FA POST path'       $post.Uri 'https://fa/api/2.42/directory-snapshots?source_names=fs:dir'
Assert-Equal 'FA body client_name' $post.Body.client_name 'Veeam-Backup'
Assert-Equal 'FA body suffix'     $post.Body.suffix $ts
Assert-Equal 'FA body keep_for'   $post.Body.keep_for 14400000
Assert-Equal 'FA created name'    $faSnap.ArrayName "fs:dir.Veeam-Backup.$ts"
$null = New-EvpArraySnapshot -Session $fa -SourceName 'fs:dir' -Tag 'Veeam-Backup' -Timestamp '20261019T081500Z' -KeepForMs 0 6>$null
$post = Get-HttpCalls | Where-Object Method -eq 'POST' | Select-Object -Last 1
Assert-True 'FA keep_for omitted when 0' ($post.Body.PSObject.Properties.Name -notcontains 'keep_for')
$fbSnap = New-EvpArraySnapshot -Session $fb -SourceName 'myfs' -Tag 'Veeam-Backup' -Timestamp $ts 6>$null
$post = Get-HttpCalls | Where-Object Method -eq 'POST' | Select-Object -Last 1
Assert-Equal 'FB POST path'       $post.Uri 'https://fb/api/2.17/file-system-snapshots?source_names=myfs'
Assert-Equal 'FB body suffix only' (($post.Body.PSObject.Properties.Name | Sort-Object) -join ',') 'suffix'
Assert-Equal 'FB created name'    $fbSnap.ArrayName "myfs.Veeam-Backup-$ts"
Reset-Logs
$null = New-EvpArraySnapshot -Session $fb -SourceName 'myfs' -Tag 'Veeam-Backup' -WhatIf 6>$null
Assert-Equal 'WhatIf makes no POST' @(Get-HttpCalls | Where-Object Method -eq 'POST').Count 0

$list = Get-EvpArraySnapshots -Session $fa -SourceName 'fs:dir'
Assert-Equal 'FA list count' $list.Count 2
Assert-Equal 'FA list query' ((Get-HttpCalls | Where-Object Method -eq 'GET' | Select-Object -Last 1).Uri) 'https://fa/api/2.42/directory-snapshots?source_names=fs:dir'
$list = Get-EvpArraySnapshots -Session $fb -SourceName 'myfs'
Assert-Equal 'FB list uses filter=' ((Get-HttpCalls | Where-Object Method -eq 'GET' | Select-Object -Last 1).Uri) "https://fb/api/2.17/file-system-snapshots?filter=source.name='myfs'"
Assert-Equal 'FB foreign and source-less items dropped' $list.Count 1
Assert-Equal 'FB list name' $list[0].Name "myfs.Veeam-Backup-$ts"
Reset-Logs
$summary = Remove-EvpArraySnapshots -Session $fb -Snapshots $list 6>$null
Assert-Equal 'FB destroyed one' $summary.Destroyed 1
$patch = Get-HttpCalls | Where-Object Method -eq 'PATCH' | Select-Object -Last 1
Assert-Equal 'FB PATCH path' $patch.Uri "https://fb/api/2.17/file-system-snapshots?names=myfs.Veeam-Backup-$ts"
Assert-Equal 'FB PATCH body' $patch.Body.destroyed 'True'
$list = Get-EvpArraySnapshots -Session $fb -SourceName 'myfs'
$summary = Remove-EvpArraySnapshots -Session $fb -Snapshots $list 6>$null
Assert-Equal 'already destroyed skipped' $summary.AlreadyDestroyed 1
Reset-Logs
$summary = Remove-EvpArraySnapshots -Session $fa -Snapshots (Get-EvpArraySnapshots -Session $fa -SourceName 'fs:dir') -WhatIf 6>$null
Assert-Equal 'WhatIf makes no PATCH' @(Get-HttpCalls | Where-Object Method -eq 'PATCH').Count 0

# ---------------------------------------------------------------------------------------------
Write-TestSection 'Veeam adapter: PowerShell backend'
$cfgPath = New-LabConfigFile -Directory (Join-Path $tmp 'ps') -Backend 'PowerShell'
$config = Get-EvpConfig -Path $cfgPath
Reset-Logs
$session = Connect-EvpVeeam -Config $config -Platform $platform 6>$null 3>$null
Assert-Equal 'backend PowerShell' $session.Backend 'PowerShell'
Assert-Equal 'implicit connect (no user)' ($null -eq (Get-VeeamCalls | Where-Object Cmdlet -eq 'Connect-VBRServer').User) 'True'
$shares = Get-EvpVeeamShares -Session $session 6>$null
Assert-Equal 'six SMB/NFS shares, S3 excluded' $shares.Count 6
$found = Find-EvpVeeamShare -Shares $shares -VeeamPath '\\192.0.2.10\FINANCE-SMB\'
Assert-Equal 'case/trailing-insensitive match' $found.TypeName 'VBRNASSMBServer'
Assert-Throws 'protocol must match' { Find-EvpVeeamShare -Shares $shares -VeeamPath '192.0.2.10:/finance-smb' } 'not in the Veeam inventory'
Assert-Throws 'unknown share lists known ones' { Find-EvpVeeamShare -Shares $shares -VeeamPath '\\x\y' } 'Known SMB/NFS shares: .*finance-smb'
$nfs = Find-EvpVeeamShare -Shares $shares -VeeamPath '192.0.2.20:/projects-nfs'
Reset-Logs
$applied = Set-EvpVeeamStorageSnapshotPath -Session $session -Share $nfs -StorageSnapshotPath '192.0.2.20:/projects-nfs/.snapshot/x' -EnsureProcessingMode $true 6>$null
$call = Get-VeeamCalls | Select-Object -Last 1
Assert-Equal 'NFS cmdlet'        $call.Cmdlet 'Set-VBRNASNFSServer'
Assert-Equal 'NFS path'          $call.StorageSnapshotPath '192.0.2.20:/projects-nfs/.snapshot/x'
Assert-Equal 'failover off'      $call.Failover 'False'
Assert-Equal 'mode enforced'     $call.Mode 'StorageSnapshot'
Assert-Equal 'returns the path'  $applied '192.0.2.20:/projects-nfs/.snapshot/x'
$null = Set-EvpVeeamStorageSnapshotPath -Session $session -Share $found -StorageSnapshotPath '\\s\x' -EnsureProcessingMode $false 6>$null
$call = Get-VeeamCalls | Select-Object -Last 1
Assert-Equal 'SMB cmdlet'        $call.Cmdlet 'Set-VBRNASSMBServer'
Assert-Equal 'mode untouched when not enforced' $call.Mode ''
Reset-Logs
$null = Set-EvpVeeamStorageSnapshotPath -Session $session -Share $found -StorageSnapshotPath '\\s\x' -WhatIf 6>$null
Assert-Equal 'WhatIf makes no Set call' @(Get-VeeamCalls).Count 0
Disconnect-EvpVeeam -Session $session
$env:EVP_TEST_CONNECT_FAIL = '1'
Assert-Throws 'refused implicit connect fails fast with hint' { Connect-EvpVeeam -Config $config -Platform $platform 6>$null 3>$null } 'Identity service.*configure Veeam.User'
$env:EVP_TEST_CONNECT_FAIL = $null

Write-TestSection 'Veeam adapter: REST backend'
$state = New-LabState; Use-LabMock $state; Reset-Logs
$restCfg = Get-EvpConfig -Path (New-LabConfigFile -Directory (Join-Path $tmp 'rest') -Backend 'Rest')
Assert-Throws 'defective build refused' { Connect-EvpVeeam -Config $restCfg -Platform $platform 6>$null } 'silently reads the live share'
$state.VeeamBuild = '13.2.0.100'
$rest = Connect-EvpVeeam -Config $restCfg -Platform $platform 6>$null
Assert-Equal 'REST token obtained' $rest.Token 'vbr-token'
Assert-True 'password grant form' (((Get-HttpCalls | Where-Object Uri -like '*oauth2/token').Body) -match '^grant_type=password&username=svc&password=')
$shares = Get-EvpVeeamShares -Session $rest 6>$null
Assert-Equal 'REST shares' $shares.Count 2
$smb = Find-EvpVeeamShare -Shares $shares -VeeamPath '\\192.0.2.10\finance-smb'
Assert-Equal 'REST record mode' $smb.ProcessingMode 'Direct'
Reset-Logs
$null = Set-EvpVeeamStorageSnapshotPath -Session $rest -Share $smb -StorageSnapshotPath '\\192.0.2.10\finance-smb\.snapshot\x' -EnsureProcessingMode $true 6>$null
$put = Get-HttpCalls | Where-Object Method -eq 'PUT' | Select-Object -First 1
Assert-Equal 'PUT path'           $put.Uri 'https://vbr:9419/api/v1/inventory/unstructuredDataServers/smb-1'
Assert-Equal 'PUT snapshot path'  $put.Body.advancedSettings.storageSnapshotPath '\\192.0.2.10\finance-smb\.snapshot\x'
Assert-Equal 'PUT failover off'   $put.Body.advancedSettings.directBackupFailoverEnabled 'False'
Assert-Equal 'PUT mode'           $put.Body.advancedSettings.processingMode 'StorageSnapshot'
Assert-Equal 'PUT round-trips id' $put.Body.id 'smb-1'
Assert-True 'session polled to completion' (((Get-HttpCalls).Uri -join ' ') -match 'sessions/save-1')
$state.VeeamSaveResult = 'Failed'
Assert-Throws 'failed save session is an error' { Set-EvpVeeamStorageSnapshotPath -Session $rest -Share $smb -StorageSnapshotPath '\\s\x' 6>$null } 'failed to save share'
$state.VeeamBuild = '13.1.1.18'
$ackCfg = Get-EvpConfig -Path (New-LabConfigFile -Directory (Join-Path $tmp 'rest-ack') -Backend 'Rest' -Overrides @{ Veeam = @{ AcknowledgeRestDefect = $true } })
$ack = Connect-EvpVeeam -Config $ackCfg -Platform $platform 6>$null
Assert-Equal 'acknowledged defect connects' $ack.Backend 'Rest'
$loopback = Get-EvpConfig -Path (New-LabConfigFile -Directory (Join-Path $tmp 'rest-lo') -Backend 'Rest' -Overrides @{ Veeam = @{ Server = 'localhost' } })
if ($platform.IsLinux) { Assert-Throws 'localhost refused on Linux' { Connect-EvpVeeam -Config $loopback -Platform $platform 6>$null } 'loopback' }
else { Assert-Throws 'localhost refused on Linux (simulated)' { Connect-EvpVeeam -Config $loopback -Platform ([pscustomobject]@{ IsLinux = $true; IsWindows = $false; Identity = 'x'; Interactive = $false }) 6>$null } 'loopback' }

# ---------------------------------------------------------------------------------------------
Write-TestSection 'Pre phase: happy path (PowerShell backend, FA + FB)'
$state = New-LabState; Use-LabMock $state; Reset-Logs
$config = Get-EvpConfig -Path $cfgPath
$rc = Invoke-EvpPrePhase -Config $config -Platform $platform 6>$null 3>$null
Assert-Equal 'exit 0' $rc 0
$posts = @(Get-HttpCalls | Where-Object Method -eq 'POST' | Where-Object Uri -like '*snapshots*')
Assert-Equal 'one snapshot per source: multi dir once, FB once, smb once' $posts.Count 3
Assert-True 'same timestamp for all' (@($posts | ForEach-Object { if ($_.Body.suffix -match '(\d{8}T\d{6}Z)') { $Matches[1] } } | Sort-Object -Unique).Count -eq 1)
$sets = @(Get-VeeamCalls | Where-Object Cmdlet -like 'Set-*')
Assert-Equal 'four shares repointed' $sets.Count 4
$multiSmb = $sets | Where-Object Path -eq '\\192.0.2.10\shared'
$multiNfs = $sets | Where-Object Path -eq '192.0.2.10:/shared'
Assert-True 'multi SMB path' ($multiSmb.StorageSnapshotPath -match '^\\\\192\.0\.2\.10\\shared\\\.snapshot\\Veeam-Backup\.\d{8}T\d{6}Z$')
Assert-True 'multi NFS path' ($multiNfs.StorageSnapshotPath -match '^192\.0\.2\.10:/shared/\.snapshot/Veeam-Backup\.\d{8}T\d{6}Z$')
Assert-Equal 'multi SMB and NFS share one snapshot' ($multiSmb.StorageSnapshotPath -replace '.*[\\/]', '') ($multiNfs.StorageSnapshotPath -replace '.*[\\/]', '')
$fbSet = $sets | Where-Object Path -eq '192.0.2.20:/projects-nfs'
Assert-True 'FB NFS path carries fs name' ($fbSet.StorageSnapshotPath -match '^192\.0\.2\.20:/projects-nfs/\.snapshot/projects-nfs\.Veeam-Backup-\d{8}T\d{6}Z$')
Assert-True 'all failover off' (-not ($sets | Where-Object { $_.Failover -ne $false }))
Assert-True 'all mode enforced' (-not ($sets | Where-Object { $_.Mode -ne 'StorageSnapshot' }))
$faPost = $posts | Where-Object Uri -like 'https://fa/*' | Select-Object -First 1
Assert-Equal 'FA keep_for = KeepFor 1d + 7d' $faPost.Body.keep_for 691200000
$fbPost = $posts | Where-Object Uri -like 'https://fb/*' | Select-Object -First 1
Assert-True 'FB no keep_for' ($fbPost.Body.PSObject.Properties.Name -notcontains 'keep_for')

Write-TestSection 'Pre phase: sweep destroys only old tagged snapshots of this source'
$state = New-LabState
$state.FaSnapshots = @(
	@{ name = 'fs01:finance-smb.Veeam-Backup.20200101T000000Z'; source = @{ name = 'fs01:finance-smb' }; destroyed = $false },
	@{ name = 'fs01:finance-smb.Veeam-Backup.20200102T000000Z'; source = @{ name = 'fs01:finance-smb' }; destroyed = $true },
	@{ name = 'fs01:finance-smb.policy.daily-001'; source = @{ name = 'fs01:finance-smb' }; destroyed = $false },
	@{ name = "fs01:finance-smb.Veeam-Backup.$(Get-EvpTimestamp)"; source = @{ name = 'fs01:finance-smb' }; destroyed = $false }
)
Use-LabMock $state; Reset-Logs
$rc = Invoke-EvpPrePhase -Config $config -Platform $platform 6>$null 3>$null
Assert-Equal 'exit 0 with sweep' $rc 0
$patches = @(Get-HttpCalls | Where-Object Method -eq 'PATCH')
Assert-Equal 'exactly one old snapshot destroyed' $patches.Count 1
Assert-True 'the 2020 one' ($patches[0].Uri -like '*Veeam-Backup.20200101T000000Z')

Write-TestSection 'Pre phase: WhatIf changes nothing'
$state = New-LabState; Use-LabMock $state; Reset-Logs
$rc = Invoke-EvpPrePhase -Config $config -Platform $platform -WhatIf 6>$null 3>$null
Assert-Equal 'WhatIf exit 0' $rc 0
Assert-Equal 'no POST/PATCH' @(Get-HttpCalls | Where-Object { $_.Method -in 'POST', 'PATCH' -and $_.Uri -notlike '*/login' }).Count 0
Assert-Equal 'no Set-VBR*' @(Get-VeeamCalls | Where-Object Cmdlet -like 'Set-*').Count 0
Assert-True 'still read inventory and exports' ((Get-HttpCalls | Where-Object Uri -like '*directory-exports*').Count -gt 0)

Write-TestSection 'Pre phase: an unreachable array fails only its shares'
$sentinelPattern = '\.snapshot[\\/]__everpure-pre-backup-failed-\d{8}T\d{6}Z__$'
$state = New-LabState; $state.FaLoginStatus = 401; Use-LabMock $state; Reset-Logs
$rc = Invoke-EvpPrePhase -Config $config -Platform $platform 6>$null 3>$null
Assert-Equal 'exit 11 (partial: some shares fail-safe)' $rc 11
$sets = @(Get-VeeamCalls | Where-Object Cmdlet -like 'Set-*')
$sentinels = @($sets | Where-Object { $_.StorageSnapshotPath -match $sentinelPattern })
Assert-Equal 'sentinel on the three FlashArray shares' (($sentinels | ForEach-Object { $_.Path } | Sort-Object) -join ',') (('192.0.2.10:/shared', '\\192.0.2.10\finance-smb', '\\192.0.2.10\shared' | Sort-Object) -join ',')
Assert-True  'sentinel keeps separators' (($sentinels | Where-Object Path -like '\\*').StorageSnapshotPath -like '\\*\.snapshot\__*')
Assert-True  'sentinel failover off, mode enforced' (-not ($sentinels | Where-Object { $_.Failover -or $_.Mode -ne 'StorageSnapshot' }))
$fbSet = @($sets | Where-Object Path -eq '192.0.2.20:/projects-nfs')
Assert-True  'the FlashBlade share still backs up from its snapshot' ($fbSet.Count -eq 1 -and $fbSet[0].StorageSnapshotPath -match 'projects-nfs\.Veeam-Backup-\d{8}T\d{6}Z$' -and -not $fbSet[0].Failover)
Assert-Equal 'only the FlashBlade snapshot created' (@(Get-HttpCalls | Where-Object { $_.Method -eq 'POST' -and $_.Uri -like '*snapshots*' }) | ForEach-Object { ([uri]$_.Uri).Host }) 'fb'

Write-TestSection 'Pre phase: FailSafeScope Job keeps the 1.0.0 all-or-nothing behaviour'
$jobScope = Get-EvpConfig -Path (New-LabConfigFile -Directory (Join-Path $tmp 'scope-job') -Overrides @{ Behaviour = @{ FailSafeScope = 'job' } })
Assert-Equal 'scope normalised' $jobScope.Behaviour.FailSafeScope 'Job'
$state = New-LabState; $state.FaLoginStatus = 401; Use-LabMock $state; Reset-Logs
$rc = Invoke-EvpPrePhase -Config $jobScope -Platform $platform 6>$null 3>$null
Assert-Equal 'scope Job: exit 10' $rc 10
Assert-Equal 'scope Job: sentinel on all four shares' @(Get-VeeamCalls | Where-Object { $_.Cmdlet -like 'Set-*' -and $_.StorageSnapshotPath -match $sentinelPattern }).Count 4
Assert-Equal 'scope Job: no snapshot created' @(Get-HttpCalls | Where-Object { $_.Method -eq 'POST' -and $_.Uri -like '*snapshots*' }).Count 0

Write-TestSection 'Pre phase: OnFailure None (1.0.0 FailSafePath false) leaves failed shares alone'
$noFs = Get-EvpConfig -Path (New-LabConfigFile -Directory (Join-Path $tmp 'nofs') -Overrides @{ Behaviour = @{ FailSafePath = $false } })
Assert-Equal 'FailSafePath false means OnFailure None' $noFs.Behaviour.OnFailure 'None'
$state = New-LabState; $state.FaLoginStatus = 401; Use-LabMock $state; Reset-Logs
$rc = Invoke-EvpPrePhase -Config $noFs -Platform $platform 6>$null 3>$null
Assert-Equal 'exit 11' $rc 11
Assert-Equal 'only the working share is set' ((@(Get-VeeamCalls | Where-Object Cmdlet -like 'Set-*') | ForEach-Object { $_.Path }) -join ',') '192.0.2.20:/projects-nfs'
$state = New-LabState; $state.FaLoginStatus = 401; $state.FbSnapshotDirEnabled = $false; Use-LabMock $state; Reset-Logs
$rc = Invoke-EvpPrePhase -Config $noFs -Platform $platform 6>$null 3>$null
Assert-Equal 'nothing protected, nothing applied: exit of the first failure (array)' $rc 4

Write-TestSection 'Pre phase: OnFailure LiveFallback lets Veeam back up the live share'
$liveCfg = Get-EvpConfig -Path (New-LabConfigFile -Directory (Join-Path $tmp 'live') -Overrides @{ Behaviour = @{ OnFailure = 'livefallback' } })
Assert-Equal 'OnFailure normalised' $liveCfg.Behaviour.OnFailure 'LiveFallback'
Assert-Throws 'OnFailure validated' { Get-EvpConfig -Path (New-LabConfigFile -Directory (Join-Path $tmp 'live-bad') -Overrides @{ Behaviour = @{ OnFailure = 'Pray' } }) } 'Behaviour.OnFailure must be'
$state = New-LabState; $state.FaLoginStatus = 401; Use-LabMock $state; Reset-Logs
$r = Invoke-Captured { Invoke-EvpPrePhase -Config $liveCfg -Platform $platform }
Assert-Equal 'live fallback: exit 11' $r.Code 11
$sets = @(Get-VeeamCalls | Where-Object Cmdlet -like 'Set-*')
Assert-True  'live fallback: failed shares get the unreadable path with failover ON' (@($sets | Where-Object { $_.StorageSnapshotPath -match $sentinelPattern -and $_.Failover }).Count -eq 3)
Assert-True  'live fallback: the snapshot share keeps failover off' (-not ($sets | Where-Object { $_.Path -eq '192.0.2.20:/projects-nfs' -and $_.Failover }))
Assert-True  'live fallback: loudly reported' ($r.Text -match 'LIVE FALLBACK for 3 share')
Reset-Logs
$rc = Invoke-EvpPostPhase -Config $liveCfg -Platform $platform 6>$null 3>$null
Assert-True  'live fallback: the post phase disarms with failover ON too' (-not (Get-VeeamCalls | Where-Object { $_.Cmdlet -like 'Set-*' -and -not $_.Failover }))

Write-TestSection 'Pre phase: a share missing from the inventory fails alone'
$missing = Get-EvpConfig -Path (New-LabConfigFile -Directory (Join-Path $tmp 'missing') -Overrides @{ Shares = @(@{ VeeamPath = '\\192.0.2.10\finance-smb'; Array = 'fa' }, @{ VeeamPath = '\\192.0.2.10\does-not-exist'; Array = 'fa' }) })
$state = New-LabState; Use-LabMock $state; Reset-Logs
$rc = Invoke-EvpPrePhase -Config $missing -Platform $platform 6>$null 3>$null
Assert-Equal 'exit 11' $rc 11
$sets = @(Get-VeeamCalls | Where-Object Cmdlet -like 'Set-*')
Assert-True  'the known share backs up from its snapshot' ($sets.Count -eq 1 -and $sets[0].Path -eq '\\192.0.2.10\finance-smb' -and $sets[0].StorageSnapshotPath -notmatch $sentinelPattern)
$missingJob = Get-EvpConfig -Path (New-LabConfigFile -Directory (Join-Path $tmp 'missing-job') -Overrides @{ Shares = @(@{ VeeamPath = '\\192.0.2.10\finance-smb'; Array = 'fa' }, @{ VeeamPath = '\\192.0.2.10\does-not-exist'; Array = 'fa' }); Behaviour = @{ FailSafeScope = 'Job' } })
Reset-Logs
$rc = Invoke-EvpPrePhase -Config $missingJob -Platform $platform 6>$null 3>$null
Assert-Equal 'scope Job: exit 10 (sentinel on the known share)' $rc 10
Assert-Equal 'scope Job: no array call at all' @(Get-HttpCalls).Count 0

Write-TestSection 'Pre phase: Veeam connection failure'
$env:EVP_TEST_CONNECT_FAIL = '1'
$state = New-LabState; Use-LabMock $state; Reset-Logs
$rc = Invoke-EvpPrePhase -Config $config -Platform $platform 6>$null 3>$null
Assert-Equal 'exit 2' $rc 2
$env:EVP_TEST_CONNECT_FAIL = $null

Write-TestSection 'Pre phase: FlashBlade snapshot directory disabled fails only that source'
$state = New-LabState; $state.FbSnapshotDirEnabled = $false; Use-LabMock $state; Reset-Logs
$rc = Invoke-EvpPrePhase -Config $config -Platform $platform 6>$null 3>$null
Assert-Equal 'exit 11' $rc 11
Assert-Equal 'no FlashBlade snapshot created' @(Get-HttpCalls | Where-Object { $_.Method -eq 'POST' -and $_.Uri -like 'https://fb/*snapshots*' }).Count 0
Assert-Equal 'the FlashArray sources are snapshotted' @(Get-HttpCalls | Where-Object { $_.Method -eq 'POST' -and $_.Uri -like 'https://fa/*snapshots*' }).Count 2
Assert-True  'the FlashBlade share gets the sentinel' (@(Get-VeeamCalls | Where-Object { $_.Path -eq '192.0.2.20:/projects-nfs' -and $_.StorageSnapshotPath -match $sentinelPattern }).Count -eq 1)

# ---------------------------------------------------------------------------------------------
Write-TestSection 'Job guard (Veeam.JobId): PowerShell backend'
$jobId = 'aaaaaaaa-1111-4111-8111-000000000001'
$otherId = 'bbbbbbbb-2222-4222-8222-000000000002'
$labRoots = @('\\192.0.2.10\finance-smb', '\\192.0.2.10\shared', '192.0.2.10:/shared', '192.0.2.20:/projects-nfs')
$env:EVP_TEST_JOBS = ConvertTo-Json -Compress -Depth 4 -InputObject @(@{ Id = $jobId; Name = 'lab-job'; ShareRoots = $labRoots })
$bound = Get-EvpConfig -Path (New-LabConfigFile -Directory (Join-Path $tmp 'bound') -Overrides @{ Veeam = @{ JobId = $jobId.ToUpperInvariant() }; Snapshot = @{ KeepFor = 'none' } })
Assert-Equal 'JobId parsed and lower-cased' $bound.Veeam.JobId $jobId
# Only a clone's own session is active: the pre phase stops before touching anything.
$env:EVP_TEST_SESSIONS = ConvertTo-Json -Compress -InputObject @(@{ Id = 'cccccccc-3333-4333-8333-000000000003'; JobId = $otherId; Name = 'lab-job'; State = 'Working' })
$state = New-LabState; Use-LabMock $state; Reset-Logs
$rc = Invoke-EvpPrePhase -Config $bound -Platform $platform 6>$null 3>$null
Assert-Equal 'pre refused: exit 2' $rc 2
Assert-Equal 'no array call at all' @(Get-HttpCalls).Count 0
Assert-Equal 'no share touched' @(Get-VeeamCalls | Where-Object Cmdlet -like 'Set-*').Count 0
$rc = Invoke-EvpPrePhase -Config $bound -Platform $platform -WhatIf 6>$null 3>$null
Assert-Equal 'dry run only warns' $rc 0
$state = New-LabState
$state.FbSnapshots = @(@{ name = 'projects-nfs.Veeam-Backup-20200101T000000Z'; source = @{ name = 'projects-nfs' }; destroyed = $false })
Use-LabMock $state; Reset-Logs
$rc = Invoke-EvpPostPhase -Config $bound -Platform $platform 6>$null 3>$null
Assert-Equal 'post refused: exit 2' $rc 2
Assert-Equal 'nothing destroyed' @(Get-HttpCalls | Where-Object Method -eq 'PATCH').Count 0
# A session of the bound job is active: both phases run as usual.
$env:EVP_TEST_SESSIONS = ConvertTo-Json -Compress -InputObject @(
	@{ Id = 'cccccccc-3333-4333-8333-000000000003'; JobId = $jobId; Name = 'lab-job'; State = 'Stopped' },
	@{ Id = 'dddddddd-4444-4444-8444-000000000004'; JobId = $jobId; Name = 'lab-job'; State = 'Working' })
$state = New-LabState; Use-LabMock $state; Reset-Logs
$rc = Invoke-EvpPrePhase -Config $bound -Platform $platform 6>$null 3>$null
Assert-Equal 'pre runs inside the job session' $rc 0
Assert-Equal 'four shares repointed' @(Get-VeeamCalls | Where-Object Cmdlet -like 'Set-*').Count 4
Reset-Logs
$rc = Invoke-EvpPostPhase -Config $bound -Platform $platform 6>$null 3>$null
Assert-Equal 'post runs inside the job session' $rc 0
# An active full names its session 'job (Full)': the guard must still find it (lab, 13.1.1.18).
$env:EVP_TEST_SESSIONS = ConvertTo-Json -Compress -InputObject @(@{ Id = 'dddddddd-4444-4444-8444-00000000000f'; JobId = $jobId; Name = 'lab-job (Full)'; State = 'Postprocessing' })
$rc = Invoke-EvpPostPhase -Config $bound -Platform $platform 6>$null 3>$null
Assert-Equal 'post inside an active-full session (named "lab-job (Full)")' $rc 0
$env:EVP_TEST_SESSIONS = ConvertTo-Json -Compress -InputObject @(@{ Id = 'dddddddd-4444-4444-8444-00000000000e'; JobId = $otherId; Name = 'lab-job-clone (Full)'; State = 'Working' })
$rc = Invoke-EvpPostPhase -Config $bound -Platform $platform 6>$null 3>$null
Assert-Equal 'a clone whose name starts the same is still refused (JobId decides)' $rc 2
$env:EVP_TEST_SESSIONS = ConvertTo-Json -Compress -InputObject @(
	@{ Id = 'cccccccc-3333-4333-8333-000000000003'; JobId = $jobId; Name = 'lab-job'; State = 'Stopped' },
	@{ Id = 'dddddddd-4444-4444-8444-000000000004'; JobId = $jobId; Name = 'lab-job'; State = 'Working' })
Assert-True 'post destroyed the run snapshots' (@(Get-HttpCalls | Where-Object Method -eq 'PATCH').Count -ge 1)
# Unknown job ID (deleted and re-created job).
$stale = Get-EvpConfig -Path (New-LabConfigFile -Directory (Join-Path $tmp 'stale') -Overrides @{ Veeam = @{ JobId = $otherId } })
Reset-Logs
$rc = Invoke-EvpPrePhase -Config $stale -Platform $platform 6>$null 3>$null
Assert-Equal 'unknown job id: exit 2' $rc 2
Assert-Equal 'unknown job id: nothing touched' @(Get-VeeamCalls | Where-Object Cmdlet -like 'Set-*').Count 0
# The job is the share list: a job share missing from Shares (1.0.0 reported it) is covered.
$env:EVP_TEST_JOBS = ConvertTo-Json -Compress -Depth 4 -InputObject @(@{ Id = $jobId; Name = 'lab-job'; ShareRoots = $labRoots + '192.0.2.10:/finance-nfs' })
$state = New-LabState; Use-LabMock $state; Reset-Logs
$rc = Invoke-EvpVerifyPhase -Config $bound -Platform $platform 6>$null 3>$null
Assert-Equal 'verify covers a job share missing from Shares (1.1.0)' $rc 0
Assert-True 'its source was resolved through the interface mapping' (((Get-HttpCalls).Uri -join ' ') -match 'directory-exports\?export_names=finance-nfs')
$env:EVP_TEST_JOBS = ConvertTo-Json -Compress -Depth 4 -InputObject @(@{ Id = $jobId; Name = 'lab-job'; ShareRoots = $labRoots })
$rc = Invoke-EvpVerifyPhase -Config $bound -Platform $platform 6>$null 3>$null
Assert-Equal 'verify passes when job and Shares agree' $rc 0
$rc = Invoke-EvpVerifyPhase -Config $stale -Platform $platform 6>$null 3>$null
Assert-Equal 'verify reports an unknown job id (exit 2)' $rc 2
$env:EVP_TEST_JOBS = $null; $env:EVP_TEST_SESSIONS = $null

Write-TestSection 'Job guard (Veeam.JobId): REST backend'
$restBound = Get-EvpConfig -Path (New-LabConfigFile -Directory (Join-Path $tmp 'rest-bound') -Backend 'Rest' -Overrides @{ Veeam = @{ JobId = $jobId }; Shares = @(@{ VeeamPath = '192.0.2.20:/projects-nfs'; Array = 'fb' }) })
$state = New-LabState; $state.VeeamBuild = '13.2.0.100'
$state.VeeamJobs = @([pscustomobject]@{ id = $jobId; name = 'lab-job'; type = 'FileBackup' })
Use-LabMock $state; Reset-Logs
$rc = Invoke-EvpPrePhase -Config $restBound -Platform $platform 6>$null 3>$null
Assert-Equal 'REST: pre refused without a session' $rc 2
Assert-Equal 'REST: no share saved' @(Get-HttpCalls | Where-Object Method -eq 'PUT').Count 0
$state.VeeamSessions = @([pscustomobject]@{ id = 'eeeeeeee-5555-4555-8555-000000000005'; jobId = $jobId; state = 'Working'; creationTime = '2026-01-01T00:00:00Z' })
Reset-Logs
$rc = Invoke-EvpPrePhase -Config $restBound -Platform $platform 6>$null 3>$null
Assert-Equal 'REST: pre runs inside the session' $rc 0
Assert-True 'REST: sessions filtered by job id' (@(Get-HttpCalls | Where-Object Uri -like "*sessions?jobIdFilter=$jobId*").Count -ge 1)
$rc = Invoke-EvpVerifyPhase -Config $restBound -Platform $platform 6>$null 3>$null
Assert-Equal 'REST: verify passes (no object comparison)' $rc 0

# ---------------------------------------------------------------------------------------------
Write-TestSection 'Discovery: file interfaces and host addresses'
$state = New-LabState; Use-LabMock $state; Reset-Logs
$fa = Connect-EvpArray -ArrayConfig $faConfig -ApiToken (Get-Token 'fa-token') 6>$null
$fb = Connect-EvpArray -ArrayConfig $fbConfig -ApiToken (Get-Token 'fb-token') 6>$null
Assert-Equal 'FA: only enabled interfaces with service file' ((@(Get-EvpArrayFileInterfaces -Session $fa) | ForEach-Object Address) -join ',') '192.0.2.10'
Assert-Equal 'FB: data interfaces with their server' ((@(Get-EvpArrayFileInterfaces -Session $fb) | ForEach-Object { "$($_.Address)@$($_.Server)" }) -join ',') '192.0.2.20@srv1,192.0.2.21@srv2'
Assert-Equal 'IP literal used as is' (Resolve-EvpShareHostAddress -HostName '192.0.2.10') '192.0.2.10'
Assert-True  'a name is resolved by DNS' (@(Resolve-EvpShareHostAddress -HostName 'localhost').Count -ge 1)
Assert-Equal 'an unresolvable name has no address' @(Resolve-EvpShareHostAddress -HostName 'no-such-host.invalid' 3>$null).Count 0

Write-TestSection 'Discovery: mapping shares to arrays'
$discDir = Join-Path $tmp 'disc'
$discCfg = Get-EvpConfig -Path (New-LabConfigFile -Directory $discDir -Overrides @{ Shares = @(
			@{ VeeamPath = '\\192.0.2.10\finance-smb' }, @{ VeeamPath = '192.0.2.10:/shared' }, @{ VeeamPath = '192.0.2.20:/projects-nfs' }) })
$state = New-LabState; Use-LabMock $state; Reset-Logs
$plan = Connect-EvpArraysForShares -Config $discCfg -Platform $platform -Shares (Get-EvpRunShares -Config $discCfg -Job $null) 6>$null 3>$null
Assert-Equal 'every share mapped' @($plan.Shares).Count 3
Assert-Equal 'SMB on the FlashArray VIP -> fa' (@($plan.Shares) | Where-Object VeeamPath -eq '\\192.0.2.10\finance-smb').Array 'fa'
Assert-Equal 'NFS on the FlashBlade VIP -> fb' (@($plan.Shares) | Where-Object VeeamPath -eq '192.0.2.20:/projects-nfs').Array 'fb'
Assert-Equal 'sources resolved' (($plan.Groups.Keys | Sort-Object) -join ',') 'fa|fs01:finance-smb,fa|fs01:shared,fb|projects-nfs'
Assert-Equal 'the loaded configuration is not annotated' $discCfg.Shares[0].Array ''
$dup = @(New-EvpShareRecord -VeeamPath '\\192.0.2.21\dup-share')
$plan = Connect-EvpArraysForShares -Config $discCfg -Platform $platform -Shares $dup 6>$null 3>$null
Assert-Equal 'FB export on two servers settled by the server of the VIP' $plan.Groups.Values[0].SourceName 'fs-b'
$stray = @((New-EvpShareRecord -VeeamPath '\\192.0.2.10\finance-smb'), (New-EvpShareRecord -VeeamPath '\\192.0.2.99\old'))
Assert-Throws 'an address no array owns is an error (disabled interface ignored)' { Connect-EvpArraysForShares -Config $discCfg -Platform $platform -Shares $stray 6>$null 3>$null } 'no configured array has a file interface with address 192\.0\.2\.99'
$plan = Connect-EvpArraysForShares -Config $discCfg -Platform $platform -Shares $stray -Tolerant 6>$null 3>$null
Assert-Equal 'tolerant: the other share still maps' @($plan.Shares).Count 1
Assert-Equal 'tolerant: the stray share is reported' @($plan.Unmapped).Count 1
$state = New-LabState; $state.FbExtraAddress = '192.0.2.10'; Use-LabMock $state
Assert-Throws 'an address owned by two arrays is an error' { Connect-EvpArraysForShares -Config $discCfg -Platform $platform -Shares @(New-EvpShareRecord -VeeamPath '\\192.0.2.10\finance-smb') 6>$null 3>$null } 'file interface of 2 arrays \(fa, fb\)'
$pinned = @(New-EvpShareRecord -VeeamPath '\\192.0.2.10\finance-smb' -Array 'fa')
Assert-Equal 'an Array override settles it' @((Connect-EvpArraysForShares -Config $discCfg -Platform $platform -Shares $pinned 6>$null 3>$null).Shares).Count 1
# The cache names the array: nothing else is contacted.
$state = New-LabState; Use-LabMock $state; Reset-Logs
$cached = [pscustomobject]@{ Version = 1; Shares = @([pscustomobject]@{ VeeamPath = '\\192.0.2.10\finance-smb'; Array = 'fa' }); Sources = @() }
$plan = Connect-EvpArraysForShares -Config $discCfg -Platform $platform -Shares @(New-EvpShareRecord -VeeamPath '\\192.0.2.10\finance-smb') -State $cached 6>$null 3>$null
Assert-Equal 'cache-first: mapped' @($plan.Shares).Count 1
Assert-Equal 'cache-first: the FlashBlade was not contacted' @(Get-HttpCalls | Where-Object Uri -like 'https://fb/*').Count 0
# An array that is down only matters when a share needs it.
[System.IO.File]::WriteAllText((Join-Path $discDir 'secrets/fb.token'), "wrong`n")
$down = Get-EvpConfig -Path (Join-Path $discDir 'lab-job.jsonc')
$plan = Connect-EvpArraysForShares -Config $down -Platform $platform -Shares @(New-EvpShareRecord -VeeamPath '\\192.0.2.10\finance-smb') 6>$null 3>$null
Assert-Equal 'unreachable array not needed: share mapped' @($plan.Shares).Count 1
Assert-True  'unreachable array not needed: recorded' $plan.Unreachable.Contains('fb')
Assert-Throws 'unreachable array needed: named in the error' { Connect-EvpArraysForShares -Config $down -Platform $platform -Shares @(New-EvpShareRecord -VeeamPath '192.0.2.20:/projects-nfs') 6>$null 3>$null } 'not reachable: fb'
[System.IO.File]::WriteAllText((Join-Path $discDir 'secrets/fb.token'), "fb-token`n")

Write-TestSection 'Discovery: pre and post with the shares from the job and a global arrays file'
$discJobId = 'abababab-7777-4777-8777-000000000007'
$jobDir = Join-Path $tmp 'disc-job'
$jobCfgPath = New-LabConfigFile -Directory $jobDir -Name 'files' -Overrides @{ Veeam = @{ JobId = $discJobId }; Arrays = @(); Shares = @(); Snapshot = @{ KeepFor = 'none' } }
$null = Write-TestFile -Path (Join-Path $jobDir 'arrays.jsonc') -Content '{ "Arrays": [ { "Name": "fa", "Endpoint": "fa", "ApiTokenFile": "secrets/fa.token" }, { "Name": "fb", "Endpoint": "fb", "ApiTokenFile": "secrets/fb.token" } ] }'
$jobCfg = Get-EvpConfig -Path $jobCfgPath
Assert-Equal 'job config: arrays from arrays.jsonc' $jobCfg.Arrays.Count 2
$discRoots = @('\\192.0.2.10\finance-smb', '\\192.0.2.10\shared', '192.0.2.10:/shared', '192.0.2.20:/projects-nfs')
$env:EVP_TEST_JOBS = ConvertTo-Json -Compress -Depth 4 -InputObject @(@{ Id = $discJobId; Name = 'files'; ShareRoots = $discRoots + 'bucket-01' })
$env:EVP_TEST_SESSIONS = ConvertTo-Json -Compress -InputObject @(@{ Id = 'abababab-8888-4888-8888-000000000008'; JobId = $discJobId; Name = 'files'; State = 'Working' })
$state = New-LabState; Use-LabMock $state; Reset-Logs
$r = Invoke-Captured { Invoke-EvpPrePhase -Config $jobCfg -Platform $platform }
Assert-Equal 'pre exit 0' $r.Code 0
Assert-Equal 'the four job shares repointed' @(Get-VeeamCalls | Where-Object Cmdlet -like 'Set-*').Count 4
Assert-True  'a non-share job object is reported' ($r.Text -match "Job object 'bucket-01' is not an SMB share or NFS export")
$statePath = Join-Path $jobDir 'state/files.state.json'
Assert-True  'state written' (Test-Path $statePath)
$saved = Get-Content $statePath -Raw | ConvertFrom-Json
Assert-Equal 'state: shares' @($saved.Shares).Count 4
Assert-Equal 'state: sources' (($saved.Sources | ForEach-Object { "$($_.Array)|$($_.Source)" } | Sort-Object) -join ',') 'fa|fs01:finance-smb,fa|fs01:shared,fb|projects-nfs'
Assert-True  'state: inventory IDs from the job' (-not (@($saved.Shares) | Where-Object { -not $_.InventoryId }))
Assert-Equal 'state: job name' $saved.JobName 'files'
Reset-Logs
$r = Invoke-Captured { Invoke-EvpPrePhase -Config $jobCfg -Platform $platform }
Assert-Equal 'second pre exit 0' $r.Code 0
Assert-True  'second pre maps from the state' ($r.Text -match 'as in the last run')
Reset-Logs
$rc = Invoke-EvpPostPhase -Config $jobCfg -Platform $platform 6>$null 3>$null
Assert-Equal 'post exit 0' $rc 0
Assert-Equal 'post disarms the four job shares' @(Get-VeeamCalls | Where-Object Cmdlet -like 'Set-*').Count 4
# The FlashBlade share leaves the job; an old tagged snapshot is still on its file system.
$env:EVP_TEST_JOBS = ConvertTo-Json -Compress -Depth 4 -InputObject @(@{ Id = $discJobId; Name = 'files'; ShareRoots = $discRoots[0..2] })
$state.FbSnapshots += , @{ name = 'projects-nfs.Veeam-Backup-20200101T000000Z'; source = @{ name = 'projects-nfs' }; destroyed = $false; created = 0 }
Reset-Logs
$r = Invoke-Captured { Invoke-EvpPostPhase -Config $jobCfg -Platform $platform }
Assert-Equal 'post after a share left the job: exit 0' $r.Code 0
Assert-True  'its source is cleaned up from the state' ($r.Text -match "'projects-nfs' is no longer used by the job")
Assert-Equal 'the old snapshot on the orphaned source destroyed' @(Get-HttpCalls | Where-Object { $_.Method -eq 'PATCH' -and $_.Uri -like '*projects-nfs.Veeam-Backup-20200101T000000Z' }).Count 1
$saved = Get-Content $statePath -Raw | ConvertFrom-Json
Assert-Equal 'nothing tagged left there: dropped from the state' (($saved.Sources | ForEach-Object { $_.Source } | Sort-Object) -join ',') 'fs01:finance-smb,fs01:shared'
# Verify shows where every share comes from and passes.
$r = Invoke-Captured { Invoke-EvpVerifyPhase -Config $jobCfg -Platform $platform }
Assert-Equal 'verify with discovery passes' $r.Code 0
Assert-True  'verify lists the job shares' ($r.Text -match 'share \\\\192\.0\.2\.10\\finance-smb \[SMB\] from the job')
# -NoJobGuard: no session needed, the job is still read for its shares.
$env:EVP_TEST_SESSIONS = $null
$noGuard = Get-EvpConfig -Path $jobCfgPath
$noGuard.Veeam.JobGuard = $false
Reset-Logs
$rc = Invoke-EvpPrePhase -Config $noGuard -Platform $platform 6>$null 3>$null
Assert-Equal '-NoJobGuard: pre runs without a session' $rc 0
Assert-Equal '-NoJobGuard: still the job shares' @(Get-VeeamCalls | Where-Object Cmdlet -like 'Set-*').Count 3
$rc = Invoke-EvpPrePhase -Config $jobCfg -Platform $platform 6>$null 3>$null
Assert-Equal 'with the guard and no session: refused' $rc 2

Write-TestSection 'Fleet: members through one endpoint'
$flDir = Join-Path $tmp 'fleet'
$flShares = @(@{ VeeamPath = '\\192.0.2.40\fla-share' }, @{ VeeamPath = '\\192.0.2.41\flb-share' })
$flCfgPath = New-LabConfigFile -Directory $flDir -Name 'fleet-job' -Overrides @{ Arrays = @(@{ Name = 'labfleet'; Type = 'Fleet'; Endpoint = 'fl'; ApiTokenFile = 'secrets/fl.token' }); Shares = $flShares; Snapshot = @{ KeepFor = 'none' } }
[System.IO.File]::WriteAllText((Join-Path $flDir 'secrets/fl.token'), "fl-token`n")
$flCfg = Get-EvpConfig -Path $flCfgPath
Assert-Equal 'fleet entry type' $flCfg.Arrays['labfleet'].Type 'Fleet'
Assert-Throws 'a fleet is no array for a Shares override' { Get-EvpConfig -Path (New-LabConfigFile -Directory (Join-Path $tmp 'fleet-bad') -Overrides @{ Arrays = @(@{ Name = 'labfleet'; Type = 'Fleet'; Endpoint = 'fl'; ApiTokenFile = 't' }); Shares = @(@{ VeeamPath = '\\x\y'; Array = 'labfleet' }) }) } 'is a fleet; set Array to the member'
$memberOverride = Get-EvpConfig -Path (New-LabConfigFile -Directory (Join-Path $tmp 'fleet-member') -Overrides @{ Arrays = @(@{ Name = 'labfleet'; Type = 'Fleet'; Endpoint = 'fl'; ApiTokenFile = 't' }); Shares = @(@{ VeeamPath = '\\x\y'; Array = 'FLB' }) })
Assert-Equal 'a member name in a Shares override is checked at run time' $memberOverride.Shares[0].Array 'FLB'
$state = New-LabState; Use-LabMock $state; Reset-Logs
$pool = New-EvpArrayPool
$names = @(Get-EvpArrayNames -Config $flCfg -Platform $platform -Pool $pool 6>$null 3>$null)
Assert-Equal 'usable members: FlashArrays that joined' ($names -join ',') 'FLA,FLB'
Assert-True  'FlashBlade member skipped as cross-product' ($pool.Fleets['labfleet'].Skipped['FBX'] -match 'other product')
Assert-True  'member that has not joined skipped' ($pool.Fleets['labfleet'].Skipped['FLC'] -match 'joining')
Assert-Equal 'one login for the whole fleet' @(Get-HttpCalls | Where-Object { $_.Method -eq 'POST' -and $_.Uri -like '*/login' }).Count 1
Assert-Equal 'member session carries its context' $pool.Sessions['FLB'].Context 'FLB'
$plan = Connect-EvpArraysForShares -Config $flCfg -Platform $platform -Shares (Get-EvpRunShares -Config $flCfg -Job $null) -Pool $pool 6>$null 3>$null
Assert-Equal 'shares mapped to members' ((@($plan.Shares) | ForEach-Object { "$($_.ShareName)@$($_.Array)" }) -join ',') 'fla-share@FLA,flb-share@FLB'
Assert-True  'FlashArray server hint read from attached_servers' ((@($plan.Shares) | Where-Object ShareName -eq 'flb-share').ServerHint -eq '_array_server')
Assert-True  'every member call carries context_names' (-not (Get-HttpCalls | Where-Object { $_.Uri -like 'https://fl/api/2.42/directory-exports*' -and $_.Uri -notmatch 'context_names=FL[AB]' }))
# ActiveCluster: the realm VIP is on both members; the online one serves it.
$ac = @(New-EvpShareRecord -VeeamPath '\\192.0.2.30\ac-share')
$plan = Connect-EvpArraysForShares -Config $flCfg -Platform $platform -Shares $ac 6>$null 3>$null
Assert-Equal 'ActiveCluster: the online array serves the share' @($plan.Shares)[0].Array 'FLB'
Assert-Equal 'ActiveCluster: pod directory as source' $plan.Groups.Values[0].SourceName 'pod1::fsac:root'
$staleCache = [pscustomobject]@{ Version = 1; Shares = @([pscustomobject]@{ VeeamPath = '\\192.0.2.30\ac-share'; Array = 'FLA' }); Sources = @() }
$plan = Connect-EvpArraysForShares -Config $flCfg -Platform $platform -Shares @(New-EvpShareRecord -VeeamPath '\\192.0.2.30\ac-share') -State $staleCache 6>$null 3>$null
Assert-Equal 'ActiveCluster: a cached standby array is not trusted' @($plan.Shares)[0].Array 'FLB'
# Fail closed: an answer for another context, or none, is refused.
$state = New-LabState; $state.FlIgnoreContext = $true; Use-LabMock $state
Assert-Throws 'an endpoint that ignores context_names is refused' { Connect-EvpArraysForShares -Config $flCfg -Platform $platform -Shares @(New-EvpShareRecord -VeeamPath '\\192.0.2.41\flb-share' -Array 'FLB') 6>$null 3>$null } 'was answered for context .FLA.'
$state = New-LabState; $state.FlPostNoContext = $true; Use-LabMock $state
$p2 = New-EvpArrayPool
$flb = Open-EvpArraySession -Config $flCfg -Platform $platform -Name 'FLB' -Pool $p2 6>$null 3>$null
Assert-Throws 'a create answered without context is refused' { New-EvpArraySnapshot -Session $flb -SourceName 'fsb:dir1' -Tag 'veeam-x' 6>$null } "context '<none>'"
Assert-Equal 'unknown member: no session' $null (Open-EvpArraySession -Config $flCfg -Platform $platform -Name 'NOPE' -Pool $p2 3>$null)
Assert-True  'unknown member: reason recorded' ($p2.Unreachable['NOPE'] -match 'no array or fleet member')
# A direct entry for a member wins over the fleet.
$both = Get-EvpConfig -Path (New-LabConfigFile -Directory (Join-Path $tmp 'fleet-both') -Overrides @{ Arrays = @(@{ Name = 'labfleet'; Type = 'Fleet'; Endpoint = 'fl'; ApiTokenFile = 'secrets/fl.token' }, @{ Name = 'flb'; Endpoint = 'fl'; ApiTokenFile = 'secrets/fl.token' }); Shares = $flShares })
[System.IO.File]::WriteAllText((Join-Path $tmp 'fleet-both/secrets/fl.token'), "fl-token`n")
$state = New-LabState; Use-LabMock $state
$p3 = New-EvpArrayPool
$null = Get-EvpArrayNames -Config $both -Platform $platform -Pool $p3 6>$null 3>$null
Assert-True  'a member with its own entry is left to it' ($p3.Fleets['labfleet'].Skipped['FLB'] -match "own entry 'flb'")

Write-TestSection 'Fleet: pre and post through the fleet'
$labInventory = $env:EVP_TEST_INVENTORY
$env:EVP_TEST_INVENTORY = Join-Path $tmp 'fleet-inventory.json'
[System.IO.File]::WriteAllText($env:EVP_TEST_INVENTORY, (ConvertTo-Json -Depth 3 -InputObject @(
			@{ Type = 'VBRNASSMBServer'; Id = '22222222-2222-4222-8222-000000000001'; Path = '\\192.0.2.40\fla-share'; ProcessingMode = 'Direct'; DirectBackupFailoverEnabled = $true; StorageSnapshotPath = '' },
			@{ Type = 'VBRNASSMBServer'; Id = '22222222-2222-4222-8222-000000000002'; Path = '\\192.0.2.41\flb-share'; ProcessingMode = 'Direct'; DirectBackupFailoverEnabled = $true; StorageSnapshotPath = '' })))
$state = New-LabState; Use-LabMock $state; Reset-Logs
$rc = Invoke-EvpPrePhase -Config $flCfg -Platform $platform 6>$null 3>$null
Assert-Equal 'pre exit 0' $rc 0
$flPosts = @(Get-HttpCalls | Where-Object { $_.Method -eq 'POST' -and $_.Uri -like 'https://fl/api/2.42/directory-snapshots*' })
Assert-Equal 'one snapshot per member source, each with its context' (($flPosts | ForEach-Object { if ($_.Uri -match 'context_names=(\w+)') { $Matches[1] } } | Sort-Object) -join ',') 'FLA,FLB'
Assert-Equal 'snapshots created on the right members' (($state.FlSnapshots | ForEach-Object { "$($_.on):$($_.source.name)" } | Sort-Object) -join ',') 'FLA:fsa:dir1,FLB:fsb:dir1'
$flState = Get-Content (Join-Path $flDir 'state/fleet-job.state.json') -Raw | ConvertFrom-Json
Assert-Equal 'state records the members' (($flState.Sources | ForEach-Object { $_.Array } | Sort-Object) -join ',') 'FLA,FLB'
Reset-Logs
$rc = Invoke-EvpPostPhase -Config $flCfg -Platform $platform 6>$null 3>$null
Assert-Equal 'post exit 0' $rc 0
Assert-Equal 'post destroyed both, through their contexts' (($state.FlSnapshots | Where-Object destroyed | ForEach-Object on | Sort-Object) -join ',') 'FLA,FLB'
$r = Invoke-Captured { Invoke-EvpVerifyPhase -Config $flCfg -Platform $platform }
Assert-Equal 'verify passes with a fleet' $r.Code 0
Assert-True  'verify lists the fleet and its members' ($r.Text -match "OK   fleet labfleet: 'LABFLEET'" -and $r.Text -match 'OK     member FLB' -and $r.Text -match 'member FBX skipped')
# Orphans of an earlier run: one on a fleet member that needs its own entry (kept, exit 4, no
# snapshot failure), one on an array that is configured nowhere any more (dropped).
$flStatePath = Join-Path $flDir 'state/fleet-job.state.json'
$doc = Get-Content $flStatePath -Raw | ConvertFrom-Json
$doc.Sources = @($doc.Sources) + @([pscustomobject]@{ Array = 'FBX'; Platform = 'FlashBlade'; Source = 'fs-old' }, [pscustomobject]@{ Array = 'gone01'; Platform = 'FlashArray'; Source = 'x:y' })
[System.IO.File]::WriteAllText($flStatePath, ($doc | ConvertTo-Json -Depth 6))
Reset-Logs
$r = Invoke-Captured { Invoke-EvpPostPhase -Config $flCfg -Platform $platform }
Assert-Equal 'orphan on an unusable member: exit 4 (array), not 5' $r.Code 4
Assert-True  'the reason is printed' ($r.Text -match "Source 'fs-old' of the last run on 'FBX' cannot be cleaned up now: .*other product.*Kept for the next run")
Assert-True  'an orphan on an array configured nowhere is dropped' ($r.Text -match "Source 'x:y' of the last run was on array 'gone01', which is no longer configured")
$doc = Get-Content $flStatePath -Raw | ConvertFrom-Json
Assert-Equal 'state keeps the reachable-later orphan, drops the gone one' ((@($doc.Sources) | Where-Object { $_.Array -in 'FBX', 'gone01' } | ForEach-Object { $_.Array }) -join ',') 'FBX'
$env:EVP_TEST_INVENTORY = $labInventory

Write-TestSection 'File-to-tape job'
$tapeId = 'cdcdcdcd-9999-4999-8999-000000000009'
$tapeRoots = @('\\192.0.2.20\projects-smb', '192.0.2.20:/projects-nfs')
$env:EVP_TEST_JOBS = ConvertTo-Json -Compress -Depth 4 -InputObject @(@{ Id = $tapeId; Name = 'to-tape'; Kind = 'FileToTape'; ShareRoots = $tapeRoots })
$tapeCfg = Get-EvpConfig -Path (New-LabConfigFile -Directory (Join-Path $tmp 'tape') -Name 'to-tape' -Overrides @{ Veeam = @{ JobId = $tapeId }; Shares = @() })
$state = New-LabState; Use-LabMock $state; Reset-Logs
$session = Connect-EvpVeeam -Config $tapeCfg -Platform $platform 6>$null 3>$null
$tapeJob = Get-EvpVeeamJob -Session $session -JobId $tapeId
Assert-Equal 'tape: found as file-to-tape' $tapeJob.Kind 'FileToTape'
Assert-Equal 'tape: share paths without the nfs41:// prefix' ($tapeJob.ShareRoots -join ',') ($tapeRoots -join ',')
Assert-True  'tape: inventory IDs' (-not ($tapeJob.Shares | Where-Object { -not $_.InventoryId }))
Assert-Equal 'tape: found by name' (@(Find-EvpVeeamJobByName -Name 'to-tape') | ForEach-Object { "$($_.Kind):$($_.Id)" }) "FileToTape:$tapeId"
$rc = Invoke-EvpPrePhase -Config $tapeCfg -Platform $platform 6>$null 3>$null
Assert-Equal 'tape: pre refused without a tape session' $rc 2
$env:EVP_TEST_SESSIONS = ConvertTo-Json -Compress -InputObject @(@{ Id = 'cdcdcdcd-aaaa-4aaa-8aaa-00000000000a'; JobId = $tapeId; Name = 'to-tape'; State = 'Working' })
Reset-Logs
$rc = Invoke-EvpPrePhase -Config $tapeCfg -Platform $platform 6>$null 3>$null
Assert-Equal 'tape: pre runs inside the tape session' $rc 0
Assert-Equal 'tape: both shares repointed' @(Get-VeeamCalls | Where-Object Cmdlet -like 'Set-*').Count 2
Reset-Logs
$rc = Invoke-EvpPostPhase -Config $tapeCfg -Platform $platform 6>$null 3>$null
Assert-Equal 'tape: post exit 0' $rc 0
# Veeam types an object-storage-to-tape job FileToTape too; its bucket object has no path.
$env:EVP_TEST_JOBS = ConvertTo-Json -Compress -Depth 4 -InputObject @(@{ Id = $tapeId; Name = 'to-tape'; Kind = 'FileToTape'; ShareRoots = $tapeRoots + '@S3CompatibleServer' })
$tapeJob = Get-EvpVeeamJob -Session $session -JobId $tapeId
Assert-Equal 'tape: shares beside a bucket object' ($tapeJob.ShareRoots -join ',') ($tapeRoots -join ',')
Assert-Equal 'tape: bucket object listed as skipped' ($tapeJob.Skipped -join ',') 'S3CompatibleServer object without a path'
$env:EVP_TEST_JOBS = ConvertTo-Json -Compress -Depth 4 -InputObject @(@{ Id = $tapeId; Name = 'to-tape'; Kind = 'FileToTape'; ShareRoots = @('@S3CompatibleServer') })
Reset-Logs
$r = Invoke-Captured { Invoke-EvpPrePhase -Config $tapeCfg -Platform $platform }
Assert-True  'tape: bucket-only job refused, nothing repointed' ($r.Code -ne 0 -and $r.Text -match 'contains no SMB share or NFS export' -and -not @(Get-VeeamCalls | Where-Object Cmdlet -like 'Set-*').Count)
$env:EVP_TEST_JOBS = $null; $env:EVP_TEST_SESSIONS = $null

# ---------------------------------------------------------------------------------------------
Write-TestSection 'Post phase'
$state = New-LabState
$old = '20200101T000000Z'
$state.FaSnapshots = @(
	@{ name = "fs01:finance-smb.Veeam-Backup.$old"; source = @{ name = 'fs01:finance-smb' }; destroyed = $false },
	@{ name = "fs01:shared.Veeam-Backup.$old"; source = @{ name = 'fs01:shared' }; destroyed = $false },
	@{ name = 'fs01:shared.policy.daily-001'; source = @{ name = 'fs01:shared' }; destroyed = $false },
	@{ name = "fs01:shared.Other-Tag.$old"; source = @{ name = 'fs01:shared' }; destroyed = $false }
)
$state.FbSnapshots = @(@{ name = "projects-nfs.Veeam-Backup-$old"; source = @{ name = 'projects-nfs' }; destroyed = $false })
Use-LabMock $state; Reset-Logs
$rc = Invoke-EvpPostPhase -Config $config -Platform $platform 6>$null 3>$null
Assert-Equal 'post exit 0' $rc 0
$patches = @(Get-HttpCalls | Where-Object Method -eq 'PATCH')
Assert-Equal 'three tagged snapshots destroyed' $patches.Count 3
Assert-True 'policy snapshot untouched' (-not ($patches | Where-Object Uri -like '*policy*'))
Assert-True 'other tag untouched' (-not ($patches | Where-Object Uri -like '*Other-Tag*'))
$disarms = @(Get-VeeamCalls | Where-Object Cmdlet -like 'Set-*')
Assert-Equal 'post disarms all four shares' $disarms.Count 4
Assert-True 'disarm path is the awaiting sentinel' (-not ($disarms | Where-Object { $_.StorageSnapshotPath -notmatch '\.snapshot[\\/]__everpure-awaiting-pre-backup-\d{8}T\d{6}Z__$' }))
Assert-True 'disarm failover off, mode enforced' (-not ($disarms | Where-Object { $_.Failover -or $_.Mode -ne 'StorageSnapshot' }))
# Veeam unreachable and no job guard configured: cleanup still runs, the run reports partial.
$state = New-LabState
$state.FbSnapshots = @(@{ name = "projects-nfs.Veeam-Backup-$old"; source = @{ name = 'projects-nfs' }; destroyed = $false })
Use-LabMock $state; Reset-Logs
$env:EVP_TEST_CONNECT_FAIL = '1'
$rc = Invoke-EvpPostPhase -Config $config -Platform $platform 6>$null 3>$null
$env:EVP_TEST_CONNECT_FAIL = $null
Assert-Equal 'post without Veeam: exit 6 (partial)' $rc 6
Assert-Equal 'post without Veeam still destroys' @(Get-HttpCalls | Where-Object Method -eq 'PATCH').Count 1
Reset-Logs
$rc = Invoke-EvpPostPhase -Config $config -Platform $platform 6>$null 3>$null
Assert-Equal 'nothing left: still exit 0' $rc 0
$strict = Get-EvpConfig -Path (New-LabConfigFile -Directory (Join-Path $tmp 'strict') -Overrides @{ Behaviour = @{ FailIfNoSnapshots = $true }; Snapshot = @{ KeepFor = 'none' } })
$rc = Invoke-EvpPostPhase -Config $strict -Platform $platform 6>$null 3>$null
Assert-Equal 'FailIfNoSnapshots -> exit 5' $rc 5
$state = New-LabState
$state.FaSnapshots = @(
	@{ name = "fs01:finance-smb.Veeam-Backup.$old"; source = @{ name = 'fs01:finance-smb' }; destroyed = $false },
	@{ name = "fs01:finance-smb.Veeam-Backup.$(Get-EvpTimestamp)"; source = @{ name = 'fs01:finance-smb' }; destroyed = $false }
)
Use-LabMock $state; Reset-Logs
$keep = Get-EvpConfig -Path (New-LabConfigFile -Directory (Join-Path $tmp 'keep') -Overrides @{ Snapshot = @{ KeepFor = '1h' } })
$rc = Invoke-EvpPostPhase -Config $keep -Platform $platform 6>$null 3>$null
Assert-Equal 'young snapshot kept' @(Get-HttpCalls | Where-Object Method -eq 'PATCH').Count 1
Reset-Logs
$rc = Invoke-EvpPostPhase -Config $config -Platform $platform -WhatIf 6>$null 3>$null
Assert-Equal 'post WhatIf no PATCH' @(Get-HttpCalls | Where-Object Method -eq 'PATCH').Count 0
Assert-Equal 'post WhatIf no disarm' @(Get-VeeamCalls | Where-Object Cmdlet -like 'Set-*').Count 0

# ---------------------------------------------------------------------------------------------
Write-TestSection 'Verify phase'
$state = New-LabState; Use-LabMock $state; Reset-Logs
$rc = Invoke-EvpVerifyPhase -Config $config -Platform $platform 6>$null 3>$null
Assert-Equal 'verify passes' $rc 0
Assert-Equal 'verify changes nothing' @(Get-HttpCalls | Where-Object { $_.Method -in 'POST', 'PATCH', 'PUT' -and $_.Uri -notlike '*/login' }).Count 0
Assert-Equal 'verify no Set' @(Get-VeeamCalls | Where-Object Cmdlet -like 'Set-*').Count 0
$state = New-LabState
$state.FbSnapshots = @(
	@{ name = 'projects-nfs.Veeam-Backup-20200101T000000Z'; source = @{ name = 'projects-nfs' }; destroyed = $false },
	@{ name = 'projects-nfs.Veeam-Backup-20200102T000000Z'; source = @{ name = 'projects-nfs' }; destroyed = $true })
Use-LabMock $state
$r = Invoke-Captured { Invoke-EvpVerifyPhase -Config $config -Platform $platform }
Assert-True  'verify counts destroyed snapshots apart' ($r.Text -match "1 existing snapshot\(s\) of 'projects-nfs' carry tag 'Veeam-Backup'; 1 more destroyed, awaiting eradication")
$state = New-LabState; $state.FbSnapshotDirEnabled = $false; Use-LabMock $state
$rc = Invoke-EvpVerifyPhase -Config $missing -Platform $platform 6>$null 3>$null
Assert-Equal 'verify reports first problem category (share)' $rc 3
$rc = Invoke-EvpVerifyPhase -Config $config -Platform $platform 6>$null 3>$null
Assert-Equal 'verify flags disabled snapshot dir' $rc 5
$env:EVP_TEST_CONNECT_FAIL = '1'
$rc = Invoke-EvpVerifyPhase -Config $config -Platform $platform 6>$null 3>$null
Assert-Equal 'verify continues past Veeam failure and reports it' $rc 2
$env:EVP_TEST_CONNECT_FAIL = $null

# ---------------------------------------------------------------------------------------------
Write-TestSection 'Entry script end to end (child process)'
$entry = Join-Path $projectRoot 'Invoke-EverpureVeeamNasSnapshot.ps1'
$stubsPath = Join-Path $PSScriptRoot 'Stubs.ps1'
$modulePath = Join-Path $projectRoot 'EverpureVeeamNas.psd1'
function Invoke-Entry([string] $Phase, [string] $Config, [switch] $WhatIf) {
	# The child imports the module, installs the mock transport (a global, so the entry script's
	# Import-Module -Force keeps it), then runs the real entry script.
	$prelude = @"
`$ErrorActionPreference = 'Stop'
. '$stubsPath'
Import-Module '$modulePath' -Force
`$state = New-LabState
Set-EvpHttpInvoker (New-EvpMockResponder -Routes (New-LabRoutes -State `$state) -CallLog '$httpLog')
& '$entry' -Phase $Phase -ConfigFile '$Config' $(if ($WhatIf) { '-WhatIf' })
exit `$LASTEXITCODE
"@
	$preludePath = Write-TestFile -Path (Join-Path $tmp "prelude-$Phase.ps1") -Content $prelude
	$out = & (Get-PowerShellHostPath) -NoProfile -File $preludePath 2>&1
	return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($out -join "`n") }
}
Reset-Logs
$r = Invoke-Entry -Phase verify -Config $cfgPath
Assert-Equal 'verify exit 0' $r.ExitCode 0
Assert-True 'prints plan' ($r.Output -match 'Phase\s+: verify')
Assert-True 'prints script version' ($r.Output -match ('Script version\s+: ' + [regex]::Escape((Get-EvpVersion))))
Assert-True 'prints exit code' ($r.Output -match 'Exit code: 0')
$logFiles = @(Get-ChildItem (Join-Path (Split-Path $cfgPath) 'log') -Filter 'lab-job-*-verify.log')
Assert-Equal 'transcript written next to config (Logging.Directory=log)' $logFiles.Count 1
Reset-Logs
$r = Invoke-Entry -Phase pre -Config $cfgPath -WhatIf
Assert-Equal 'pre -WhatIf exit 0' $r.ExitCode 0
Assert-True 'dry run announced' ($r.Output -match 'DRY RUN')
Assert-Equal 'dry run still writes a transcript' @(Get-ChildItem (Join-Path (Split-Path $cfgPath) 'log') -Filter 'lab-job-*-pre.log').Count 1
Assert-Equal 'pre -WhatIf made no change' (@(Get-HttpCalls | Where-Object { $_.Method -in 'POST', 'PATCH' -and $_.Uri -notlike '*/login' }).Count + @(Get-VeeamCalls | Where-Object Cmdlet -like 'Set-*').Count) 0
Reset-Logs
$r = Invoke-Entry -Phase pre -Config $cfgPath
Assert-Equal 'pre exit 0' $r.ExitCode 0
Assert-Equal 'pre repointed four shares' @(Get-VeeamCalls | Where-Object Cmdlet -like 'Set-*').Count 4
Reset-Logs
$r = Invoke-Entry -Phase post -Config $cfgPath
Assert-Equal 'post exit 0' $r.ExitCode 0
$r = Invoke-Entry -Phase verify -Config (Join-Path $tmp 'does-not-exist.jsonc')
Assert-Equal 'bad config exit 1' $r.ExitCode 1
Assert-True 'bad config message' ($r.Output -match 'was not found')

Write-TestSection 'Secrets helper: -Array takes path and endpoint from arrays.jsonc'
$helper = Join-Path $projectRoot 'Protect-EverpureVeeamSecret.ps1'
$helperDir = Join-Path $tmp 'helper/jobs'
$null = Write-TestFile -Path (Join-Path $helperDir 'arrays.jsonc') -Content '{ "Arrays": [ { "Name": "fa", "Endpoint": "fa", "ApiTokenFile": "secrets/fa.token" }, { "Name": "fb", "Endpoint": "fb", "ApiTokenFile": "secrets/fb.token" } ] }'
function Invoke-Helper([string] $Arguments) {
	$prelude = @"
`$ErrorActionPreference = 'Stop'
. '$stubsPath'
Import-Module '$modulePath' -Force
`$state = New-LabState
Set-EvpHttpInvoker (New-EvpMockResponder -Routes (New-LabRoutes -State `$state) -CallLog '$httpLog')
# The bare message: the error view wraps at the console width, which differs between hosts.
try { & '$helper' -ArraysFile '$(Join-Path $helperDir 'arrays.jsonc')' $Arguments; exit 0 }
catch { Write-Host "ERROR: `$(`$_.Exception.Message)"; exit 1 }
"@
	$preludePath = Write-TestFile -Path (Join-Path $tmp 'prelude-helper.ps1') -Content $prelude
	$out = & (Get-PowerShellHostPath) -NoProfile -File $preludePath 2>&1
	return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($out -join "`n") }
}
$r = Invoke-Helper "-Array fa -Secret (ConvertTo-SecureString 'fa-token' -AsPlainText -Force) -Force"
Assert-Equal 'helper -Array: exit 0' $r.ExitCode 0
Assert-True  'helper -Array: token at the path from arrays.jsonc' (Test-Path (Join-Path $helperDir 'secrets/fa.token'))
Assert-True  'helper -Array: verified against the endpoint from arrays.jsonc' ($r.Output -match "Verification succeeded: FlashArray 'fa01'")
$r = Invoke-Helper "-Array fb -Secret (ConvertTo-SecureString 'wrong' -AsPlainText -Force) -NoVerify -Force"
Assert-Equal 'helper -NoVerify: exit 0 without a login' $r.ExitCode 0
$r = Invoke-Helper '-Array * -VerifyOnly'
Assert-True  'helper -Array * -VerifyOnly: the good token passes' ($r.Output -match "Verification succeeded: FlashArray 'fa01'")
Assert-True  'helper -Array * -VerifyOnly: the bad one is reported, the run fails' ($r.ExitCode -ne 0 -and $r.Output -match '1 of 2 array\(s\) failed: fb')
$r = Invoke-Helper '-Array nope -VerifyOnly'
Assert-True  'helper: unknown array names the defined ones' ($r.ExitCode -ne 0 -and $r.Output -match 'nope\. Arrays defined there: fa, fb')
# -Endpoint adds the array, creating the arrays file from the sample when there is none.
Remove-Item -LiteralPath (Join-Path $helperDir 'arrays.jsonc'), (Join-Path $helperDir 'secrets') -Recurse -Force
$r = Invoke-Helper "-Array fa -Endpoint fa -Secret (ConvertTo-SecureString 'fa-token' -AsPlainText -Force)"
Assert-Equal 'helper -Endpoint: exit 0' $r.ExitCode 0
Assert-True  'helper -Endpoint: arrays file created and the array added' ($r.Output -match 'Created .*arrays\.jsonc' -and $r.Output -match "Added array 'fa'")
Assert-Equal 'helper -Endpoint: entry in the file' ((Read-EvpArraysFile -Path (Join-Path $helperDir 'arrays.jsonc'))['fa'].Endpoint) 'fa'
Assert-True  'helper -Endpoint: token stored at secrets/fa.token' (Test-Path (Join-Path $helperDir 'secrets/fa.token'))
Assert-True  'helper -Endpoint: and verified' ($r.Output -match "Verification succeeded: FlashArray 'fa01'")
$r = Invoke-Helper "-Array fb -Endpoint fb -Tls system -Secret (ConvertTo-SecureString 'fb-token' -AsPlainText -Force) -NoVerify"
Assert-Equal 'helper -Endpoint: second array appended' (((Read-EvpArraysFile -Path (Join-Path $helperDir 'arrays.jsonc')).Keys) -join ',') 'fa,fb'
Assert-Equal 'helper -Endpoint: Tls written into the entry' ((Read-EvpArraysFile -Path (Join-Path $helperDir 'arrays.jsonc'))['fb'].Tls) 'system'
$r = Invoke-Helper "-Array fa -Endpoint other -Secret (ConvertTo-SecureString 'x' -AsPlainText -Force) -Force"
Assert-True  'helper -Endpoint: another endpoint for a known array is refused' ($r.ExitCode -ne 0 -and $r.Output -match "with endpoint 'fa'\. Edit the entry there")
$r = Invoke-Helper "-Array fa, fb -Endpoint fa"
Assert-True  'helper -Endpoint: only one array at a time' ($r.ExitCode -ne 0 -and $r.Output -match 'adds one array')
$r = Invoke-Helper "-Array labfleet -Endpoint fl -Fleet -Secret (ConvertTo-SecureString 'fl-token' -AsPlainText -Force)"
Assert-Equal 'helper -Fleet: exit 0' $r.ExitCode 0
Assert-Equal 'helper -Fleet: entry of type Fleet' ((Read-EvpArraysFile -Path (Join-Path $helperDir 'arrays.jsonc'))['labfleet'].Type) 'Fleet'
Assert-True  'helper -Fleet: verification lists the members' ($r.Output -match "Fleet       : 'LABFLEET', usable members FLA, FLB" -and $r.Output -match 'skipped FBX')
$r = Invoke-Helper "-Array labfleet -Endpoint fl -Secret (ConvertTo-SecureString 'fl-token' -AsPlainText -Force) -Force"
Assert-True  'helper: a fleet entry is not silently an array' ($r.ExitCode -ne 0 -and $r.Output -match 'as Type Fleet')

Write-TestSection 'Generator: nothing is written without a valid job'
$generator = Join-Path $projectRoot 'New-EverpureVeeamJobScripts.ps1'
$genJobId = 'efefefef-bbbb-4bbb-8bbb-00000000000b'
$env:EVP_TEST_JOBS = ConvertTo-Json -Compress -Depth 4 -InputObject @(
	@{ Id = $genJobId; Name = 'gen-job'; ShareRoots = @('\\192.0.2.10\finance-smb') },
	@{ Id = 'efefefef-cccc-4ccc-8ccc-00000000000c'; Name = 'twice'; ShareRoots = @() },
	@{ Id = 'efefefef-dddd-4ddd-8ddd-00000000000d'; Name = 'twice'; Kind = 'FileToTape'; ShareRoots = @() })
function Invoke-Generator([string] $Directory, [string] $Arguments) {
	$prelude = @"
`$ErrorActionPreference = 'Stop'
try { & '$generator' -JobsDirectory '$Directory' $Arguments; exit 0 }
catch { Write-Host "ERROR: `$(`$_.Exception.Message)"; exit 1 }
"@
	$preludePath = Write-TestFile -Path (Join-Path $tmp 'prelude-generator.ps1') -Content $prelude
	$out = & (Get-PowerShellHostPath) -NoProfile -File $preludePath 2>&1
	return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($out -join "`n") }
}
$genDir = Join-Path $tmp 'gen/jobs'
$r = Invoke-Generator $genDir '-Job no-such-job'
Assert-True  'unknown job name: error' ($r.ExitCode -ne 0 -and $r.Output -match "No file backup or file-to-tape job named 'no-such-job'")
Assert-True  'unknown job name: nothing written, not even the folder' (-not (Test-Path $genDir))
$r = Invoke-Generator $genDir '-Job twice'
Assert-True  'two jobs with the name: error naming both' ($r.ExitCode -ne 0 -and $r.Output -match '2 jobs are named .twice.' -and $r.Output -match 'FileToTape')
$r = Invoke-Generator $genDir '-Job gen-job -JobId 00000000-0000-0000-0000-000000000000'
Assert-True  'unknown -JobId: error' ($r.ExitCode -ne 0 -and $r.Output -match 'Check -JobId' -and -not (Test-Path $genDir))
$r = Invoke-Generator $genDir '-Job gen-job'
Assert-Equal 'job found by name: exit 0' $r.ExitCode 0
Assert-True  'job found by name: its ID in the configuration' (Select-String -Path (Join-Path $genDir 'gen-job.jsonc') -Pattern "`"JobId`": `"$genJobId`"" -Quiet)
Assert-Throws 'a fresh job without arrays says how to add one' { Get-EvpConfig -Path (Join-Path $genDir 'gen-job.jsonc') } 'Protect-EverpureVeeamSecret\.ps1 -Array <name> -Endpoint'
Assert-True  'job found by name: wrappers and arrays file' ((Test-Path (Join-Path $genDir 'gen-job-pre.ps1')) -and (Test-Path (Join-Path $genDir 'arrays.jsonc')))
$r = Invoke-Generator $genDir "-Job renamed -JobId $($genJobId.ToUpperInvariant())"
Assert-True  'known -JobId: accepted, the job name shown' ($r.ExitCode -eq 0 -and $r.Output -match "job 'gen-job' found for ID $genJobId")
$r = Invoke-Generator $genDir '-Job unbound -NoJobId'
Assert-True  '-NoJobId: written with a warning' ($r.ExitCode -eq 0 -and $r.Output -match 'No job binding' -and (Select-String -Path (Join-Path $genDir 'unbound.jsonc') -Pattern '"JobId": ""' -Quiet))
$r = Invoke-Generator $genDir "-Job x -NoJobId -JobId $genJobId"
Assert-True  '-NoJobId with -JobId: refused' ($r.ExitCode -ne 0 -and $r.Output -match 'either -JobId or -NoJobId')
$env:EVP_TEST_JOBS = $null

Write-TestSection 'WhatIf forwarding is explicit in the orchestration source'
$orchestrate = Get-Content (Join-Path $projectRoot 'lib/Orchestrate.ps1') -Raw
Assert-True 'New-EvpArraySnapshot forwards WhatIf' ($orchestrate -match 'New-EvpArraySnapshot[^\n]*-WhatIf:\$WhatIfPreference')
Assert-True 'Set-EvpVeeamStorageSnapshotPath forwards WhatIf' ($orchestrate -match 'Set-EvpVeeamStorageSnapshotPath[^\n]*-WhatIf:\$WhatIfPreference')
Assert-True 'Remove-EvpArraySnapshots forwards WhatIf' ($orchestrate -match 'Remove-EvpArraySnapshots[^\n]*-WhatIf:\$WhatIfPreference')
# ForEach-Object <Member> honours -WhatIf: in a dry run it prints "What if: Retrieve the value
# for property" and returns nothing, which once made the pre phase dry run see no shares.
$memberForm = @(Get-ChildItem (Join-Path $projectRoot 'lib'), $projectRoot -Filter '*.ps1' -File | Select-String -Pattern 'ForEach-Object [A-Za-z]' | ForEach-Object { "$($_.Filename):$($_.LineNumber)" })
Assert-Equal 'no ForEach-Object <Member> in the product code' ($memberForm -join ', ') ''

Set-EvpHttpInvoker $null
Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Complete-TestRun
