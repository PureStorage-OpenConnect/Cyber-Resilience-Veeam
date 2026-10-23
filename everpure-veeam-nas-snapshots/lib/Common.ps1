# Copyright 2026 Everpure, Inc.
# SPDX-License-Identifier: Apache-2.0

<#
	Common layer: platform facts, environment fix-ups, configuration loading and validation,
	duration parsing, share path parsing and snapshot naming.

	Nothing in here talks to Veeam or to an array. Everything is pure and therefore testable on
	any machine with PowerShell 7.
#>

#region Platform

function Get-EvpPlatform {
	<#
	.SYNOPSIS
		Returns the facts about the host that decide platform defaults.
	.DESCRIPTION
		The only place that inspects the operating system. Everything else asks this object, so
		the Windows/Linux differences stay in one spot: install and log locations, how secrets
		are protected, whether 'localhost' may be used for Veeam, and whether HOME needs fixing.
	#>
	[CmdletBinding()]
	[OutputType([psobject])]
	param()

	$onWindows = [bool]($IsWindows -or $env:OS -eq 'Windows_NT')
	$onLinux = [bool]$IsLinux

	$identity = 'unknown'
	$elevated = $null
	try {
		if ($onWindows) {
			$current = [System.Security.Principal.WindowsIdentity]::GetCurrent()
			$identity = $current.Name
			# True for an elevated administrator and for LOCAL SYSTEM; false in a UAC-filtered session.
			$elevated = [System.Security.Principal.WindowsPrincipal]::new($current).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
		} else {
			$identity = [System.Environment]::UserName
			if ([string]::IsNullOrWhiteSpace($identity)) { $identity = "uid $(& id -u 2>$null)" }
		}
	} catch {
		Write-Verbose "Could not determine the current identity: $($_.Exception.Message)"
	}

	$interactive = $true
	try { $interactive = [Environment]::UserInteractive } catch {
		Write-Verbose 'Could not determine whether this session is interactive.'
	}

	# The Veeam Software Appliance runs job scripts in a sandbox whose only persistent writable
	# location is this directory. Everything else under /var/lib/veeam/scripts is read-only.
	$sandboxRoot = '/var/lib/veeam/scripts/sandbox'

	[pscustomobject]@{
		IsWindows    = $onWindows
		IsLinux      = $onLinux
		Name         = if ($onWindows) { 'Windows' } elseif ($onLinux) { 'Linux' } else { 'Other' }
		Identity     = $identity
		IsElevated   = $elevated
		Interactive  = $interactive
		HomeIsEmpty  = [string]::IsNullOrEmpty($env:HOME)
		SandboxRoot  = $sandboxRoot
		InSandbox    = [bool]($onLinux -and (Test-Path -LiteralPath $sandboxRoot -PathType Container))
	}
}

function Initialize-EvpEnvironment {
	<#
	.SYNOPSIS
		Applies the environment fix-ups a job script needs before its first HTTPS call.
	.DESCRIPTION
		On Linux .NET opens the per-user certificate store under $HOME while building a
		certificate chain, even when validation is skipped. The appliance sandbox starts scripts
		with HOME unset, so every TLS handshake fails with "the home directory of the current
		user could not be determined". Setting HOME to any writable directory fixes it. Confirmed
		in real job runs on the appliance (see docs/unified-nas-snapshot-plan.md, R11).
	.PARAMETER Platform
		From Get-EvpPlatform.
	.PARAMETER WritableDirectory
		Directory to point HOME at when it is empty. Typically the log directory.
	#>
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
		Justification = 'Changes only this process environment, and -WhatIf must not disable TLS for the dry run it is describing.')]
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)] $Platform,
		[string] $WritableDirectory
	)

	if ($Platform.IsLinux -and $Platform.HomeIsEmpty) {
		$target = $WritableDirectory
		if (-not $target -or -not (Test-Path -LiteralPath $target -PathType Container)) { $target = '/tmp' }
		$env:HOME = $target
		Write-Host "HOME was empty; set to '$target' so that .NET can complete TLS handshakes."
	}
}

#endregion

#region Configuration

function Read-EvpJsonFile {
	<# Reads a JSON file that may contain // and /* */ comments. Private helper. #>
	[CmdletBinding()]
	param([Parameter(Mandatory)] [string] $Path)

	try {
		$raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
		return ($raw | ConvertFrom-Json -Depth 16 -ErrorAction Stop)
	} catch {
		throw "Configuration file '$Path' could not be read as JSON: $($_.Exception.Message)"
	}
}

function Get-EvpProperty {
	<# Returns a property of a PSCustomObject or $null when absent. Private helper. #>
	param($Object, [string] $Name)
	if ($null -eq $Object) { return $null }
	if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Name)) { return $Object[$Name] } else { return $null } }
	if ($Object.PSObject.Properties.Name -contains $Name) { return $Object.$Name }
	return $null
}

function Resolve-EvpConfigPath {
	<# Resolves a possibly relative path against the configuration file directory. #>
	param([string] $Value, [string] $BaseDirectory)
	if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
	if ([System.IO.Path]::IsPathRooted($Value)) { return $Value }
	return [System.IO.Path]::GetFullPath((Join-Path $BaseDirectory $Value))
}

function Get-EvpConfig {
	<#
	.SYNOPSIS
		Loads, validates and normalises a configuration file.
	.DESCRIPTION
		Returns an ordered hashtable with every setting present and defaulted, so the rest of
		the code never has to test for missing keys. Relative file paths resolve against the
		directory holding the configuration file, which works identically on both platforms.
		Validation is deliberately strict: a misconfiguration must fail at verify time, not at
		02:00 in a job.
	.PARAMETER Path
		Path to the JSON (with comments) configuration file.
	.OUTPUTS
		Ordered hashtable with the sections Veeam, Arrays (merged from the arrays file and this
		file), Shares, Snapshot, Behaviour, Logging, State and the meta keys ConfigPath,
		ConfigDirectory, ProfileName and ArraysFile ($null when there is none).
	#>
	[CmdletBinding()]
	[OutputType([System.Collections.Specialized.OrderedDictionary])]
	param([Parameter(Mandatory)] [string] $Path)

	$fullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
	if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
		throw "Configuration file '$fullPath' was not found."
	}
	$raw = Read-EvpJsonFile -Path $fullPath
	$baseDir = Split-Path -Parent $fullPath
	$profileName = [System.IO.Path]::GetFileNameWithoutExtension($fullPath)
	$problems = [System.Collections.Generic.List[string]]::new()

	# --- Veeam -------------------------------------------------------------------------------
	$v = Get-EvpProperty $raw 'Veeam'
	$backend = [string](Get-EvpProperty $v 'Backend')
	if (-not $backend) { $backend = 'auto' }
	if ($backend -notin @('auto', 'PowerShell', 'Rest')) { $problems.Add("Veeam.Backend must be 'auto', 'PowerShell' or 'Rest' (got '$backend').") }
	$tls = [string](Get-EvpProperty $v 'Tls')
	if (-not $tls) { $tls = 'skip' }
	if ($tls -notmatch '^(skip|system|thumbprint:([0-9A-Fa-f]{40}|[0-9A-Fa-f]{64}))$') { $problems.Add("Veeam.Tls must be 'skip', 'system' or 'thumbprint:<hex>' (got '$tls').") }
	$veeamUser = [string](Get-EvpProperty $v 'User')
	$veeamPasswordFile = Resolve-EvpConfigPath -Value ([string](Get-EvpProperty $v 'PasswordFile')) -BaseDirectory $baseDir
	if ([bool]$veeamUser -xor [bool]$veeamPasswordFile) { $problems.Add('Veeam.User and Veeam.PasswordFile must be set together or not at all.') }
	$port = Get-EvpProperty $v 'Port'
	$force = Get-EvpProperty $v 'ForceAcceptTlsCertificate'
	$ack = Get-EvpProperty $v 'AcknowledgeRestDefect'
	$jobId = ([string](Get-EvpProperty $v 'JobId')).Trim()
	if ($jobId -and $jobId -notmatch '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') {
		$problems.Add("Veeam.JobId must be the job's GUID as shown by Get-VBRUnstructuredBackupJob or the REST API, or empty (got '$jobId').")
	}
	$veeam = [ordered]@{
		Backend                   = $backend
		Server                    = if (Get-EvpProperty $v 'Server') { [string](Get-EvpProperty $v 'Server') } else { 'localhost' }
		Port                      = if ($null -ne $port) { [int]$port } else { 9419 }
		User                      = $veeamUser
		PasswordFile              = $veeamPasswordFile
		Tls                       = $tls
		ForceAcceptTlsCertificate = if ($null -ne $force) { [bool]$force } else { $true }
		ApiVersion                = if (Get-EvpProperty $v 'ApiVersion') { [string](Get-EvpProperty $v 'ApiVersion') } else { '1.3-rev2' }
		AcknowledgeRestDefect     = if ($null -ne $ack) { [bool]$ack } else { $false }
		JobId                     = $jobId.ToLowerInvariant()
		# Not a file setting: -NoJobGuard turns it off for one run and keeps JobId, which also
		# names the job the shares are read from.
		JobGuard                  = [bool]$jobId
	}

	# --- Arrays ------------------------------------------------------------------------------
	# The global arrays file (one for all jobs, default arrays.jsonc beside this file) plus any
	# Arrays listed here, as 1.0.0 required. A name defined twice is an error, not an override.
	$arrays = [ordered]@{}
	$arraysFileSetting = [string](Get-EvpProperty $raw 'ArraysFile')
	$arraysFile = if ($arraysFileSetting) { Resolve-EvpConfigPath -Value $arraysFileSetting -BaseDirectory $baseDir } else { Join-Path $baseDir 'arrays.jsonc' }
	if (Test-Path -LiteralPath $arraysFile -PathType Leaf) {
		try {
			$rawArraysFile = Read-EvpJsonFile -Path $arraysFile
			Add-EvpArrayConfig -Target $arrays -RawArrays (Get-EvpProperty $rawArraysFile 'Arrays') -BaseDirectory (Split-Path -Parent $arraysFile) -Origin $arraysFile -Problems $problems
		} catch { $problems.Add($_.Exception.Message) }
	} else {
		if ($arraysFileSetting) { $problems.Add("ArraysFile '$arraysFile' was not found.") }
		$arraysFile = $null
	}
	Add-EvpArrayConfig -Target $arrays -RawArrays (Get-EvpProperty $raw 'Arrays') -BaseDirectory $baseDir -Origin $fullPath -Problems $problems
	if ($arrays.Count -eq 0) { $problems.Add("No arrays are defined. Add each array once with .\Protect-EverpureVeeamSecret.ps1 -Array <name> -Endpoint <management address>, which writes it to '$(Join-Path $baseDir 'arrays.jsonc')' and stores its token, or list them in Arrays in this file.") }

	# --- Shares ------------------------------------------------------------------------------
	# With Veeam.JobId the shares come from the job at run time and these entries only override
	# Array or Source for one share. Without it they are the share list, as in 1.0.0.
	$shares = [System.Collections.Generic.List[object]]::new()
	$rawShares = @(Get-EvpProperty $raw 'Shares' | Where-Object { $null -ne $_ })
	if ($rawShares.Count -eq 0 -and -not $jobId) { $problems.Add('Shares must list at least one share, or set Veeam.JobId so the shares are read from the job.') }
	$index = 0
	$seenPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
	foreach ($s in $rawShares) {
		$index++
		$veeamPath = [string](Get-EvpProperty $s 'VeeamPath')
		if (-not $veeamPath) { $problems.Add("Shares[$index] has no VeeamPath."); continue }
		$protocol = Get-EvpShareProtocol -VeeamPath $veeamPath
		if (-not $protocol) { $problems.Add("Shares[$index]: '$veeamPath' is neither an SMB path (\\server\share) nor an NFS path (server:/export)."); continue }
		if (-not $seenPaths.Add((Get-EvpNormalizedSharePath -VeeamPath $veeamPath))) { $problems.Add("Shares: '$veeamPath' is listed more than once."); continue }
		# Empty Array: mapped through the arrays' file interfaces at run time. A fleet member is only
		# known once the fleet is asked, so with a fleet configured the name is checked at run time.
		$arrayName = [string](Get-EvpProperty $s 'Array')
		$haveFleet = [bool]@($arrays.Values | Where-Object { $_.Type -eq 'Fleet' }).Count
		if ($arrayName -and -not $arrays.Contains($arrayName) -and -not $haveFleet) { $problems.Add("Shares[$index] ('$veeamPath') references unknown array '$arrayName'.") }
		elseif ($arrayName -and $arrays.Contains($arrayName) -and $arrays[$arrayName].Type -eq 'Fleet') { $problems.Add("Shares[$index] ('$veeamPath'): '$arrayName' is a fleet; set Array to the member array that serves the share, or leave it empty.") }
		$source = [string](Get-EvpProperty $s 'Source')
		if (-not $source) { $source = 'auto' }
		$shares.Add((New-EvpShareRecord -VeeamPath $veeamPath -Array $arrayName -Source $source -Origin 'config'))
	}

	# --- Snapshot ----------------------------------------------------------------------------
	$sn = Get-EvpProperty $raw 'Snapshot'
	$tag = [string](Get-EvpProperty $sn 'Tag')
	if (-not $tag) { $tag = Get-EvpDefaultSnapshotTag -ProfileName $profileName -JobId $veeam.JobId }
	if ($tag -notmatch '^[A-Za-z0-9-]{1,40}$' -or $tag -notmatch '[A-Za-z]' -or $tag -match '^-|-$') {
		$problems.Add("Snapshot.Tag '$tag' is invalid: 1 to 40 letters, digits and '-', at least one letter, not starting or ending with '-'. Both arrays enforce this character set.")
	}
	# One retention setting. 'none' (default): the post phase destroys the run's snapshots and
	# the pre phase sweeps whatever an earlier run left behind. A duration keeps every snapshot
	# of this tag for that long; both phases destroy only older ones. At most 358 days, so the
	# FlashArray backstop below still fits the array's 365-day keep_for limit.
	$keepFor = Get-EvpProperty $sn 'KeepFor'
	$keepForText = if ($null -eq $keepFor -or [string]$keepFor -eq '') { 'none' } else { [string]$keepFor }
	$keepForMs = 0L
	try { $keepForMs = ConvertTo-EvpMilliseconds -Duration $keepForText -MaximumMs 30931200000L } catch { $problems.Add("Snapshot.KeepFor: $($_.Exception.Message) KeepFor is at most 358d, so the FlashArray backstop of KeepFor plus 7 days fits the array's 365-day limit.") }
	# FlashArray backstop expiry (keep_for) in case neither phase ever runs again: retention plus
	# a week. FlashBlade has no per-snapshot expiry.
	$arrayExpiryMs = $keepForMs + 604800000L
	$root = [string](Get-EvpProperty $sn 'SnapshotRootDirName')
	if (-not $root) { $root = '.snapshot' }
	$snapshot = [ordered]@{
		Tag                 = $tag
		KeepFor             = $keepForText
		KeepForMs           = $keepForMs
		ArrayExpiryMs       = $arrayExpiryMs
		SnapshotRootDirName = $root
		MatchPattern        = Get-EvpSnapshotMatchPattern -Tag $tag
	}

	# --- Behaviour ---------------------------------------------------------------------------
	$b = Get-EvpProperty $raw 'Behaviour'
	$failSafe = Get-EvpProperty $b 'FailSafePath'
	$ensureMode = Get-EvpProperty $b 'EnsureProcessingMode'
	$failIfNone = Get-EvpProperty $b 'FailIfNoSnapshots'
	$scope = [string](Get-EvpProperty $b 'FailSafeScope')
	if (-not $scope) { $scope = 'Share' }
	if ($scope -notin @('Share', 'Job')) { $problems.Add("Behaviour.FailSafeScope must be 'Share' or 'Job' (got '$scope').") }
	# What a share that cannot be protected gets. FailSafe: a non-existent snapshot path with
	# failover off, the backup fails. LiveFallback: the same path with failover on, so Veeam backs
	# up the live share and warns. None: left as it is. FailSafePath (1.0.0) false means None.
	$onFailure = [string](Get-EvpProperty $b 'OnFailure')
	if (-not $onFailure) { $onFailure = if ($null -ne $failSafe -and -not [bool]$failSafe) { 'None' } else { 'FailSafe' } }
	$onFailureNames = @{ failsafe = 'FailSafe'; livefallback = 'LiveFallback'; none = 'None' }
	if (-not $onFailureNames.ContainsKey($onFailure.ToLowerInvariant())) { $problems.Add("Behaviour.OnFailure must be 'FailSafe', 'LiveFallback' or 'None' (got '$onFailure')."); $onFailure = 'FailSafe' }
	$onFailure = $onFailureNames[$onFailure.ToLowerInvariant()]
	$behaviour = [ordered]@{
		OnFailure            = $onFailure
		FailSafePath         = ($onFailure -ne 'None')
		FailSafeScope        = (Get-Culture).TextInfo.ToTitleCase($scope.ToLowerInvariant())
		EnsureProcessingMode = if ($null -ne $ensureMode) { [bool]$ensureMode } else { $true }
		FailIfNoSnapshots    = if ($null -ne $failIfNone) { [bool]$failIfNone } else { $false }
	}
	if ($behaviour.FailIfNoSnapshots -and $keepForMs -gt 0) {
		$problems.Add('Behaviour.FailIfNoSnapshots cannot be combined with a Snapshot.KeepFor duration: the post phase then normally finds nothing old enough to destroy, and every run would fail.')
	}

	# --- Logging -----------------------------------------------------------------------------
	$l = Get-EvpProperty $raw 'Logging'
	$retention = Get-EvpProperty $l 'RetentionDays'
	$logging = [ordered]@{
		Directory     = Resolve-EvpConfigPath -Value ([string](Get-EvpProperty $l 'Directory')) -BaseDirectory $baseDir
		RetentionDays = if ($null -ne $retention) { [int]$retention } else { 30 }
	}

	# --- State -------------------------------------------------------------------------------
	$st = Get-EvpProperty $raw 'State'
	$state = [ordered]@{
		Directory = Resolve-EvpConfigPath -Value ([string](Get-EvpProperty $st 'Directory')) -BaseDirectory $baseDir
	}

	if ($problems.Count -gt 0) {
		throw ("Configuration file '$fullPath' is invalid:`n  - " + ($problems -join "`n  - "))
	}

	return [ordered]@{
		ConfigPath      = $fullPath
		ConfigDirectory = $baseDir
		ProfileName     = $profileName
		ArraysFile      = $arraysFile
		Veeam           = $veeam
		Arrays          = $arrays
		Shares          = $shares
		Snapshot        = $snapshot
		Behaviour       = $behaviour
		Logging         = $logging
		State           = $state
	}
}

function Read-EvpArraysFile {
	<#
	.SYNOPSIS
		Loads an arrays file on its own, validated like the arrays of a job configuration.
	.DESCRIPTION
		For Protect-EverpureVeeamSecret.ps1, which stores each array's token at the path and
		verifies it against the endpoint the arrays file already names.
	.OUTPUTS
		Ordered hashtable, array name -> array entry (Name, Endpoint, ApiTokenFile resolved, Platform, Tls).
	#>
	[CmdletBinding()]
	[OutputType([System.Collections.Specialized.OrderedDictionary])]
	param([Parameter(Mandatory)] [string] $Path)
	$fullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
	if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw "Arrays file '$fullPath' was not found. New-EverpureVeeamJobScripts.ps1 creates it in the jobs folder." }
	$arrays = [ordered]@{}
	$problems = [System.Collections.Generic.List[string]]::new()
	Add-EvpArrayConfig -Target $arrays -RawArrays (Get-EvpProperty (Read-EvpJsonFile -Path $fullPath) 'Arrays') -BaseDirectory (Split-Path -Parent $fullPath) -Origin $fullPath -Problems $problems
	if ($problems.Count -gt 0) { throw ("Arrays file '$fullPath' is invalid:`n  - " + ($problems -join "`n  - ")) }
	return $arrays
}

function Add-EvpArraysFileEntry {
	<#
	.SYNOPSIS
		Appends one array to the Arrays list of an arrays file, keeping its comments and layout.
	.DESCRIPTION
		A JSON round trip would drop every comment, so the entry is inserted as text before the
		closing bracket of "Arrays", with a comma after the previous entry when there is one. The
		scan skips strings and comments, so commented-out examples do not count as entries. The
		result is read back and validated; on any problem the file is restored.
		The token file is secrets/<Name>.token, relative to the arrays file.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[Parameter(Mandatory)] [string] $Path,
		[Parameter(Mandatory)] [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')] [string] $Name,
		[Parameter(Mandatory)] [string] $Endpoint,
		[string] $Tls = 'skip',
		[ValidateSet('Array', 'Fleet')] [string] $Type = 'Array'
	)
	$fullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
	$text = [System.IO.File]::ReadAllText($fullPath)

	# Find '[' after the top-level "Arrays" key and its matching ']', outside strings and comments.
	$i = 0; $depth = 0; $lastKey = $null; $listStart = -1; $listEnd = -1; $lastSignificant = -1
	while ($i -lt $text.Length) {
		$c = $text[$i]
		if ($c -eq '/' -and $i + 1 -lt $text.Length -and $text[$i + 1] -eq '/') { $i = $text.IndexOf("`n", $i); if ($i -lt 0) { break }; continue }
		if ($c -eq '/' -and $i + 1 -lt $text.Length -and $text[$i + 1] -eq '*') { $i = $text.IndexOf('*/', $i + 2); if ($i -lt 0) { break }; $i += 2; continue }
		if ($c -eq '"') {
			$j = $i + 1
			while ($j -lt $text.Length -and $text[$j] -ne '"') { if ($text[$j] -eq '\') { $j++ }; $j++ }
			$lastKey = $text.Substring($i + 1, $j - $i - 1)
			$lastSignificant = $j; $i = $j + 1; continue
		}
		if ([char]::IsWhiteSpace($c)) { $i++; continue }
		if ($c -in '{', '[') {
			$depth++
			if ($c -eq '[' -and $depth -eq 2 -and $lastKey -eq 'Arrays' -and $listStart -lt 0) { $listStart = $i }
		} elseif ($c -in '}', ']') {
			if ($c -eq ']' -and $listStart -ge 0 -and $listEnd -lt 0 -and $depth -eq 2) { $listEnd = $i; break }
			$depth--
		}
		if ($c -ne ':') { $lastKey = if ($c -eq ',') { $null } else { $lastKey } }
		$lastSignificant = $i
		$i++
	}
	if ($listStart -lt 0 -or $listEnd -lt 0) { throw "'$fullPath' has no top-level Arrays list. Add `"Arrays`": [] to it first." }

	$typeText = if ($Type -eq 'Fleet') { '"Type": "Fleet", ' } else { '' }
	$entry = '{{ "Name": {0}, {4}"Endpoint": {1}, "ApiTokenFile": {2}, "Platform": "auto", "Tls": {3} }}' -f ($Name | ConvertTo-Json), ($Endpoint | ConvertTo-Json), ("secrets/$Name.token" | ConvertTo-Json), ($Tls | ConvertTo-Json), $typeText
	$lineStart = $text.LastIndexOf("`n", $listEnd) + 1
	$closingOnOwnLine = [string]::IsNullOrWhiteSpace($text.Substring($lineStart, $listEnd - $lineStart))
	$newText = if ($closingOnOwnLine) { $text.Insert($lineStart, "`t`t$entry`n") } else { $text.Insert($listEnd, "`n`t`t$entry`n`t") }
	# A previous entry ends with '}' as the last significant character before ']'.
	if ($lastSignificant -gt $listStart -and $text[$lastSignificant] -eq '}') { $newText = $newText.Insert($lastSignificant + 1, ',') }

	if (-not $PSCmdlet.ShouldProcess($fullPath, "Add $($Type.ToLowerInvariant()) '$Name' ($Endpoint)")) { return }
	[System.IO.File]::WriteAllText($fullPath, $newText, [System.Text.UTF8Encoding]::new($false))
	try {
		$arrays = Read-EvpArraysFile -Path $fullPath
		if (-not $arrays.Contains($Name)) { throw "the new entry was not found after writing" }
	} catch {
		[System.IO.File]::WriteAllText($fullPath, $text, [System.Text.UTF8Encoding]::new($false))
		throw "Could not add array '$Name' to '$fullPath' ($($_.Exception.Message)); the file was left unchanged. Add the entry by hand."
	}
}

function Add-EvpArrayConfig {
	<#
	.SYNOPSIS
		Validates array entries and adds them to Target, keyed by name. Private helper.
	.PARAMETER Origin
		File the entries come from, named in messages and kept on each entry.
	#>
	param(
		[Parameter(Mandatory)] [System.Collections.Specialized.OrderedDictionary] $Target,
		$RawArrays,
		[Parameter(Mandatory)] [string] $BaseDirectory,
		[Parameter(Mandatory)] [string] $Origin,
		[Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.Generic.List[string]] $Problems
	)
	$index = 0
	foreach ($a in @($RawArrays | Where-Object { $null -ne $_ })) {
		$index++
		$name = [string](Get-EvpProperty $a 'Name')
		if (-not $name) { $Problems.Add("Arrays[$index] in '$Origin' has no Name."); continue }
		if ($Target.Contains($name)) {
			$where = if ($Target[$name].Origin -eq $Origin) { "more than once in '$Origin'" } else { "in both '$($Target[$name].Origin)' and '$Origin'" }
			$Problems.Add("Arrays: the name '$name' is defined $where."); continue
		}
		# Type Fleet: the endpoint is one member of an Everpure fleet, and the other members of the
		# same product are reached through it (context_names). See lib/Discovery.ps1.
		$type = [string](Get-EvpProperty $a 'Type')
		if (-not $type) { $type = 'Array' }
		if ($type -notin @('Array', 'Fleet')) { $Problems.Add("Arrays['$name'].Type must be 'Array' or 'Fleet' (got '$type')."); $type = 'Array' }
		$platform = [string](Get-EvpProperty $a 'Platform')
		if (-not $platform) { $platform = 'auto' }
		if ($platform -notin @('auto', 'FlashArray', 'FlashBlade')) { $Problems.Add("Arrays['$name'].Platform must be 'auto', 'FlashArray' or 'FlashBlade'.") }
		$aTls = [string](Get-EvpProperty $a 'Tls')
		if (-not $aTls) { $aTls = 'skip' }
		if ($aTls -notmatch '^(skip|system|thumbprint:([0-9A-Fa-f]{40}|[0-9A-Fa-f]{64}))$') { $Problems.Add("Arrays['$name'].Tls must be 'skip', 'system' or 'thumbprint:<hex>'.") }
		$endpoint = [string](Get-EvpProperty $a 'Endpoint')
		if (-not $endpoint) { $Problems.Add("Arrays['$name'] has no Endpoint.") }
		$tokenFile = Resolve-EvpConfigPath -Value ([string](Get-EvpProperty $a 'ApiTokenFile')) -BaseDirectory $BaseDirectory
		if (-not $tokenFile) { $Problems.Add("Arrays['$name'] has no ApiTokenFile.") }
		$Target[$name] = [ordered]@{
			Name         = $name
			Type         = $type
			Endpoint     = $endpoint
			ApiTokenFile = $tokenFile
			Platform     = $platform
			Tls          = $aTls
			Origin       = $Origin
		}
	}
}

function New-EvpShareRecord {
	<#
	.SYNOPSIS
		The share record the orchestration works with, from a path and optional overrides.
	.PARAMETER Array
		Array name, or empty to map the share through the arrays' file interfaces.
	.PARAMETER Origin
		Where the share came from: 'config' (Shares), 'job' (the Veeam job's objects) or 'cache'.
	#>
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
		Justification = 'Builds a record; changes nothing.')]
	[CmdletBinding()]
	[OutputType([System.Collections.Specialized.OrderedDictionary])]
	param(
		[Parameter(Mandatory)] [string] $VeeamPath,
		[string] $Array,
		[string] $Source = 'auto',
		[string] $InventoryId,
		[string] $Origin = 'config'
	)
	$parts = Split-EvpSharePath -VeeamPath $VeeamPath
	return [ordered]@{
		VeeamPath   = $VeeamPath
		Protocol    = $parts.Protocol
		Server      = $parts.Server
		ShareName   = $parts.ShareName
		Array       = $Array
		Source      = if ($Source) { $Source } else { 'auto' }
		InventoryId = $InventoryId
		Origin      = $Origin
		ServerHint  = $null
	}
}

#endregion

#region Durations

function ConvertTo-EvpMilliseconds {
	<#
	.SYNOPSIS
		Converts a compact duration such as '7d', '48h' or '6h30m' into milliseconds.
	.DESCRIPTION
		Units, combinable in descending order: w, d, h, m, s. 'none', 'never', 'off', '0' and an
		empty value mean "no duration" and return 0. A bare number is rejected because its unit
		would be anyone's guess. Optional bounds exist for FlashArray keep_for, which the array
		accepts between 5 minutes and 365 days.
	#>
	[CmdletBinding()]
	[OutputType([long])]
	param(
		[AllowNull()] [AllowEmptyString()] [string] $Duration,
		[long] $MinimumMs = 0,
		[long] $MaximumMs = 0
	)

	if ([string]::IsNullOrWhiteSpace($Duration)) { return 0L }
	$text = $Duration.Trim()
	if ($text -in @('0', 'none', 'never', 'off', 'unlimited')) { return 0L }
	if ($text -match '^\d+$') {
		throw "Duration '$text' has no unit. Use a form such as '7d', '48h', '1d12h', '6h30m' or '90m', or 'none'."
	}
	$pattern = '^(?:(?<w>\d+)w)?(?:(?<d>\d+)d)?(?:(?<h>\d+)h)?(?:(?<m>\d+)m)?(?:(?<s>\d+)s)?$'
	$parsed = [regex]::Match($text, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
	if (-not $parsed.Success -or [string]::IsNullOrEmpty($parsed.Value)) {
		throw "Could not parse duration '$Duration'. Use units w, d, h, m and s in descending order, or 'none'."
	}
	$factors = @{ w = 604800000L; d = 86400000L; h = 3600000L; m = 60000L; s = 1000L }
	$total = 0L
	foreach ($unit in 'w', 'd', 'h', 'm', 's') {
		$group = $parsed.Groups[$unit]
		if ($group.Success) { $total += ([long]$group.Value) * $factors[$unit] }
	}
	if ($total -eq 0) { return 0L }
	if (($MinimumMs -gt 0 -and $total -lt $MinimumMs) -or ($MaximumMs -gt 0 -and $total -gt $MaximumMs)) {
		throw "Duration '$Duration' resolves to $total ms, outside the accepted range ($MinimumMs to $MaximumMs ms)."
	}
	return $total
}

#endregion

#region Share paths

function Get-EvpShareProtocol {
	<# Returns 'SMB' for \\server\share, 'NFS' for server:/export, otherwise $null. #>
	[CmdletBinding()]
	[OutputType([string])]
	param([Parameter(Mandatory)] [string] $VeeamPath)

	if ($VeeamPath -match '^\\\\[^\\]+\\[^\\]+') { return 'SMB' }
	if ($VeeamPath -match '^[^\\/:\s]+:/.+') { return 'NFS' }
	return $null
}

function Split-EvpSharePath {
	<#
	.SYNOPSIS
		Splits a Veeam share path into server and share (or export) name.
	.DESCRIPTION
		'\\192.0.2.10\finance-smb' -> Server 192.0.2.10, ShareName finance-smb.
		'192.0.2.21:/projects-nfs' -> Server 192.0.2.21, ShareName projects-nfs.
		An NFS export path may contain further path segments; they are kept in ShareName.
	#>
	[CmdletBinding()]
	[OutputType([psobject])]
	param([Parameter(Mandatory)] [string] $VeeamPath)

	$trimmed = $VeeamPath.TrimEnd('\', '/')
	if ($trimmed -match '^\\\\([^\\]+)\\(.+)$') {
		return [pscustomobject]@{ Protocol = 'SMB'; Server = $Matches[1]; ShareName = $Matches[2] }
	}
	if ($trimmed -match '^([^\\/:\s]+):/(.*)$') {
		return [pscustomobject]@{ Protocol = 'NFS'; Server = $Matches[1]; ShareName = $Matches[2] }
	}
	throw "'$VeeamPath' is neither an SMB path (\\server\share) nor an NFS path (server:/export)."
}

function Get-EvpNormalizedSharePath {
	<# Canonical form for comparing share paths: lower case, trailing separators removed. #>
	[CmdletBinding()]
	[OutputType([string])]
	param([Parameter(Mandatory)] [string] $VeeamPath)
	return $VeeamPath.Trim().TrimEnd('\', '/').ToLowerInvariant()
}

function Get-EvpStorageSnapshotPath {
	<#
	.SYNOPSIS
		Builds the storage snapshot path Veeam reads from, in the share's own separator style.
	.DESCRIPTION
		SMB: \\server\share\.snapshot\<name>    NFS: server:/export/.snapshot/<name>
	#>
	[CmdletBinding()]
	[OutputType([string])]
	param(
		[Parameter(Mandatory)] [string] $VeeamPath,
		[Parameter(Mandatory)] [string] $SnapshotDirectoryName,
		[string] $SnapshotRootDirName = '.snapshot'
	)
	$protocol = Get-EvpShareProtocol -VeeamPath $VeeamPath
	$separator = if ($protocol -eq 'SMB') { '\' } else { '/' }
	return '{0}{1}{2}{1}{3}' -f $VeeamPath.TrimEnd('\', '/'), $separator, $SnapshotRootDirName, $SnapshotDirectoryName
}

#endregion

#region Snapshot naming

function Get-EvpTimestamp {
	<# UTC timestamp in ISO 8601 basic form, valid as a snapshot suffix on both arrays. #>
	[CmdletBinding()]
	[OutputType([string])]
	param([datetime] $Time = [datetime]::UtcNow)
	return $Time.ToUniversalTime().ToString('yyyyMMdd\THHmmss\Z')
}

function Get-EvpDefaultSnapshotTag {
	<#
	.SYNOPSIS
		Default Snapshot.Tag: 'veeam-' plus the profile name, reduced to the tag character set.
	.DESCRIPTION
		Gives every job configuration its own tag, so two jobs on one array source never sweep or
		destroy each other's snapshots. Anything but letters and digits becomes '-', runs of '-'
		collapse, and the result is cut to the 40-character tag limit. When the profile name
		leaves nothing usable, the job ID (without dashes) is used, and failing that 'veeam-backup'.
	#>
	[CmdletBinding()]
	[OutputType([string])]
	param([string] $ProfileName, [string] $JobId)
	foreach ($candidate in $ProfileName, ($JobId -replace '-', '')) {
		$escaped = ($candidate -replace '[^A-Za-z0-9]+', '-').Trim('-')
		if ($escaped) {
			$tag = "veeam-$escaped"
			return $tag.Substring(0, [Math]::Min(40, $tag.Length)).TrimEnd('-')
		}
	}
	return 'veeam-backup'
}

function New-EvpSnapshotName {
	<#
	.SYNOPSIS
		Renders the snapshot name for one platform from the tag and a timestamp.
	.DESCRIPTION
		FlashArray takes client_name and suffix separately and renders '<dir>.<client>.<suffix>';
		the directory visible under .snapshot is '<client>.<suffix>'. FlashBlade takes a single
		suffix and renders '<fs>.<suffix>'; the directory under .snapshot is that full name.
		FlashBlade rejects dots in the suffix, so there the tag and timestamp are joined by '-'.
		See docs/unified-nas-snapshot-plan.md section 5a.
	.PARAMETER SourceName
		FlashBlade file system name (needed for its directory name). Ignored for FlashArray.
	#>
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
		Justification = 'Builds a name; changes nothing.')]
	[CmdletBinding()]
	[OutputType([psobject])]
	param(
		[Parameter(Mandatory)] [string] $Tag,
		[Parameter(Mandatory)] [ValidateSet('FlashArray', 'FlashBlade')] [string] $Platform,
		[string] $SourceName,
		[string] $Timestamp = (Get-EvpTimestamp)
	)

	if ($Platform -eq 'FlashArray') {
		return [pscustomobject]@{
			Platform      = $Platform
			Timestamp     = $Timestamp
			ClientName    = $Tag
			Suffix        = $Timestamp
			DirectoryName = '{0}.{1}' -f $Tag, $Timestamp
			ArrayName     = if ($SourceName) { '{0}.{1}.{2}' -f $SourceName, $Tag, $Timestamp } else { $null }
		}
	}
	$suffix = '{0}-{1}' -f $Tag, $Timestamp
	return [pscustomobject]@{
		Platform      = $Platform
		Timestamp     = $Timestamp
		ClientName    = $null
		Suffix        = $suffix
		DirectoryName = if ($SourceName) { '{0}.{1}' -f $SourceName, $suffix } else { $suffix }
		ArrayName     = if ($SourceName) { '{0}.{1}' -f $SourceName, $suffix } else { $null }
	}
}

function Get-EvpSnapshotMatchPattern {
	<# Regex recognising snapshots created with this tag on either platform. #>
	[CmdletBinding()]
	[OutputType([string])]
	param([Parameter(Mandatory)] [string] $Tag)
	return '(^|\.){0}[.-](\d{{8}}T\d{{6}}Z)$' -f [regex]::Escape($Tag)
}

function Get-EvpSnapshotTimestamp {
	<# Extracts the UTC creation time encoded in a snapshot name, or $null when it does not match. #>
	[CmdletBinding()]
	[OutputType([Nullable[datetime]])]
	param(
		[Parameter(Mandatory)] [string] $Name,
		[Parameter(Mandatory)] [string] $Tag
	)
	$m = [regex]::Match($Name, (Get-EvpSnapshotMatchPattern -Tag $Tag))
	if (-not $m.Success) { return $null }
	try {
		return [datetime]::ParseExact($m.Groups[2].Value, 'yyyyMMdd\THHmmss\Z', [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
	} catch { return $null }
}

function Get-EvpSentinelDirectoryName {
	<#
	.SYNOPSIS
		Deliberately non-existent snapshot directory that makes the next job run fail visibly.
	.PARAMETER Reason
		PreFailed: the fail-safe of a failed pre phase. Disarmed: set by the post phase, so a job
		whose next pre phase never gets as far as the fail-safe cannot read the last snapshot.
	#>
	[CmdletBinding()]
	[OutputType([string])]
	param([string] $Timestamp = (Get-EvpTimestamp), [ValidateSet('PreFailed', 'Disarmed')] [string] $Reason = 'PreFailed')
	$label = if ($Reason -eq 'Disarmed') { 'awaiting-pre-backup' } else { 'pre-backup-failed' }
	return '__everpure-{0}-{1}__' -f $label, $Timestamp
}

#endregion
