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
Assert-Throws 'defective build refused' { Connect-EvpVeeam -Config $restCfg -Platform $platform 6>$null } 'case #08278019'
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

Write-TestSection 'Pre phase: array failure applies the fail-safe'
$state = New-LabState; $state.FaLoginStatus = 401; Use-LabMock $state; Reset-Logs
$rc = Invoke-EvpPrePhase -Config $config -Platform $platform 6>$null 3>$null
Assert-Equal 'exit 10' $rc 10
$sets = @(Get-VeeamCalls | Where-Object Cmdlet -like 'Set-*')
Assert-Equal 'sentinel on all four shares' $sets.Count 4
Assert-True 'sentinel path' (-not ($sets | Where-Object { $_.StorageSnapshotPath -notmatch '\.snapshot[\\/]__everpure-pre-backup-failed-\d{8}T\d{6}Z__$' }))
Assert-True 'sentinel keeps separators' (($sets | Where-Object Path -like '\\*').StorageSnapshotPath -like '\\*\.snapshot\__*')
Assert-True 'sentinel failover off, mode enforced' (-not ($sets | Where-Object { $_.Failover -or $_.Mode -ne 'StorageSnapshot' }))
Assert-Equal 'no snapshot created' @(Get-HttpCalls | Where-Object { $_.Method -eq 'POST' -and $_.Uri -like '*snapshots*' }).Count 0

Write-TestSection 'Pre phase: fail-safe can be turned off'
$noFs = Get-EvpConfig -Path (New-LabConfigFile -Directory (Join-Path $tmp 'nofs') -Overrides @{ Behaviour = @{ FailSafePath = $false } })
$state = New-LabState; $state.FaLoginStatus = 401; Use-LabMock $state; Reset-Logs
$rc = Invoke-EvpPrePhase -Config $noFs -Platform $platform 6>$null 3>$null
Assert-Equal 'exit 4 (array)' $rc 4
Assert-Equal 'no Set calls' @(Get-VeeamCalls | Where-Object Cmdlet -like 'Set-*').Count 0

Write-TestSection 'Pre phase: missing share is fatal before any snapshot'
$missing = Get-EvpConfig -Path (New-LabConfigFile -Directory (Join-Path $tmp 'missing') -Overrides @{ Shares = @(@{ VeeamPath = '\\192.0.2.10\finance-smb'; Array = 'fa' }, @{ VeeamPath = '\\192.0.2.10\does-not-exist'; Array = 'fa' }) })
$state = New-LabState; Use-LabMock $state; Reset-Logs
$rc = Invoke-EvpPrePhase -Config $missing -Platform $platform 6>$null 3>$null
Assert-Equal 'exit 10 (sentinel on the resolved share)' $rc 10
Assert-Equal 'no array call at all' @(Get-HttpCalls).Count 0
Assert-Equal 'one sentinel' @(Get-VeeamCalls | Where-Object Cmdlet -like 'Set-*').Count 1

Write-TestSection 'Pre phase: Veeam connection failure'
$env:EVP_TEST_CONNECT_FAIL = '1'
$state = New-LabState; Use-LabMock $state; Reset-Logs
$rc = Invoke-EvpPrePhase -Config $config -Platform $platform 6>$null 3>$null
Assert-Equal 'exit 2' $rc 2
$env:EVP_TEST_CONNECT_FAIL = $null

Write-TestSection 'Pre phase: FlashBlade snapshot directory disabled'
$state = New-LabState; $state.FbSnapshotDirEnabled = $false; Use-LabMock $state; Reset-Logs
$rc = Invoke-EvpPrePhase -Config $config -Platform $platform 6>$null 3>$null
Assert-Equal 'exit 10' $rc 10
Assert-Equal 'no snapshot created before the check' @(Get-HttpCalls | Where-Object { $_.Method -eq 'POST' -and $_.Uri -like '*snapshots*' }).Count 0

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
Assert-True 'post destroyed the run snapshots' (@(Get-HttpCalls | Where-Object Method -eq 'PATCH').Count -ge 1)
# Unknown job ID (deleted and re-created job).
$stale = Get-EvpConfig -Path (New-LabConfigFile -Directory (Join-Path $tmp 'stale') -Overrides @{ Veeam = @{ JobId = $otherId } })
Reset-Logs
$rc = Invoke-EvpPrePhase -Config $stale -Platform $platform 6>$null 3>$null
Assert-Equal 'unknown job id: exit 2' $rc 2
Assert-Equal 'unknown job id: nothing touched' @(Get-VeeamCalls | Where-Object Cmdlet -like 'Set-*').Count 0
# Verify compares the job's shares with Shares.
$env:EVP_TEST_JOBS = ConvertTo-Json -Compress -Depth 4 -InputObject @(@{ Id = $jobId; Name = 'lab-job'; ShareRoots = $labRoots + '192.0.2.10:/finance-nfs' })
$state = New-LabState; Use-LabMock $state; Reset-Logs
$rc = Invoke-EvpVerifyPhase -Config $bound -Platform $platform 6>$null 3>$null
Assert-Equal 'verify flags a job share missing from Shares (exit 1, config)' $rc 1
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

Write-TestSection 'WhatIf forwarding is explicit in the orchestration source'
$orchestrate = Get-Content (Join-Path $projectRoot 'lib/Orchestrate.ps1') -Raw
Assert-True 'New-EvpArraySnapshot forwards WhatIf' ($orchestrate -match 'New-EvpArraySnapshot[^\n]*-WhatIf:\$WhatIfPreference')
Assert-True 'Set-EvpVeeamStorageSnapshotPath forwards WhatIf' ($orchestrate -match 'Set-EvpVeeamStorageSnapshotPath[^\n]*-WhatIf:\$WhatIfPreference')
Assert-True 'Remove-EvpArraySnapshots forwards WhatIf' ($orchestrate -match 'Remove-EvpArraySnapshots[^\n]*-WhatIf:\$WhatIfPreference')

Set-EvpHttpInvoker $null
Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Complete-TestRun
