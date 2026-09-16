<#
.SYNOPSIS
    Removes what earlier builds left in target\ and dist\, and keeps every cache a
    current build can still reuse.

.DESCRIPTION
    Cargo never deletes an artifact. Whatever changes a unit's identity - the
    package version, a dependency version, RUSTFLAGS, the toolchain - gives it a
    new hash, and the old copy stays forever. This package bumps its version on
    nearly every build, and every bump orphaned a debug test binary with its
    ~150 MB PDB plus an incremental session: target\ had reached 32.7 GB.

    What is KEPT is read from Cargo's own records, never guessed from file ages:

      1. LIVE units - what the build that just ran used, as named by
         `--message-format=json` (fresh units included). Never removed.
      2. The package's own units: the NEWEST unit of every configuration (target
         kind, profile, RUSTFLAGS, features, toolchain). The debug bin of
         `cargo run` and rust-analyzer's check units are configurations of their
         own, not garbage. One nobody has compiled for -RetentionDays is abandoned.
      3. Everything REACHABLE from 1 and 2 through the dependency edges each
         fingerprint records. A dependency stays because a kept unit was built
         against it, so an old serde after `cargo update` goes at once, and what
         a previous toolchain or an abandoned RUSTFLAGS value built goes once its
         configuration has not been compiled for -RetentionDays.
      4. Units whose last compile FAILED (Cargo empties their hash file first) and
         anything compiled in the last day that no live unit supersedes: a failed
         rust-analyzer check must not cost its whole dependency tree.

    Incremental sessions carry no unit hash, so they are matched by time: rustc
    opens and finalizes a session between a unit's invoked.timestamp and its
    fingerprint write. A crate directory with no entry inside a kept unit's
    window belongs to a unit that is gone.

    The profile's .cargo-lock is held for the whole prune, exactly as Cargo holds
    it, so a concurrent cargo or rust-analyzer waits instead of reading a
    half-deleted unit. A busy profile is skipped.

    FAILS SAFE. A fingerprint it cannot read is kept; a live unit whose edges do
    not resolve - the mark of a layout this script does not understand - aborts
    the profile with nothing removed. A wrong removal costs a rebuild, and this
    runs after every build.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\prune-build-outputs.ps1 -DryRun
#>
[CmdletBinding()]
param(
    # Cargo target directory. Default: target\ beside Cargo.toml.
    [string]$TargetDir,
    # stdout of `cargo ... --message-format=json` from the build that just ran.
    [string[]]$CargoMessages = @(),
    # dist\ and the installer the build just produced: every OTHER
    # DelegatorSetup-*.exe there goes to the Recycle Bin.
    [string]$DistDir,
    [string]$KeepInstaller,
    # When the build started: a -KeepInstaller older than this is not the one it produced.
    [Nullable[DateTime]]$BuiltAfterUtc = $null,
    # A configuration of the package nobody has compiled for this long is abandoned.
    [int]$RetentionDays = 30,
    [switch]$DryRun
)

function ConvertTo-FingerprintHex {
    <#
      A dependency edge stores a fingerprint as a decimal u64; the unit's own hash
      file stores the same value as the hex of its LITTLE-ENDIAN bytes (cargo's
      util::to_hex). Measured on this tree: edge 12209406853615975629 is the file
      "cdfcff5bd88670a9".
    #>
    param([string]$Decimal, [hashtable]$Cache = @{})
    $hex = $Cache[$Decimal]
    if ($hex) { return $hex }
    $bytes = [BitConverter]::GetBytes([UInt64]::Parse($Decimal, [Globalization.CultureInfo]::InvariantCulture))
    if (-not [BitConverter]::IsLittleEndian) { [Array]::Reverse($bytes) }
    $hex = [BitConverter]::ToString($bytes).Replace("-", "").ToLowerInvariant()
    $Cache[$Decimal] = $hex
    return $hex
}

function Get-CargoTargetCrateName {
    <#
      The crate a fingerprint kind file compiles, spelled the way rustc names its
      incremental directory: "test-bin-delegator" -> "delegator",
      "build-script-build-script-build" -> "build_script_build".
    #>
    param([string]$Kind)
    $name = $Kind -replace '^(test|doc|run)-', ''
    $name = $name -replace '^(lib|bin|example|integration-test|bench|build-script)-', ''
    return $name.Replace("-", "_")
}

function Read-CargoUnit {
    <#
      One .fingerprint\<package>-<hash> directory.
        Known=$false     a layout this script does not recognise: never removed.
        Complete=$false  no JSON - the unit never once compiled; nothing reuses it.
        Pending=$true    the hash file is empty. Cargo truncates it before it
                         recompiles a unit and refills it only on success, so the
                         last attempt failed or never finished. The JSON still
                         describes the last SUCCESS, and the next attempt builds
                         against the same dependencies, so its edges still count.
        Invoked          when Cargo last started the unit (invoked.timestamp).
        Succeeded        when Cargo last recorded a success (the JSON's write time).
        End              the latest write of all: "last compiled" for ages.
    #>
    param([System.IO.DirectoryInfo]$Directory, [hashtable]$HexCache = @{})

    $nameMatch = [regex]::Match($Directory.Name, '^(?<name>.+)-(?<hash>[0-9a-f]{16})$')
    if (-not $nameMatch.Success) { return $null }
    $unit = [pscustomobject]@{
        Name = $nameMatch.Groups["name"].Value
        Hash = $nameMatch.Groups["hash"].Value
        Kind = ""
        Crate = ""
        Fingerprint = ""
        Family = ""
        Deps = @()
        Invoked = [DateTime]::MinValue
        Succeeded = [DateTime]::MinValue
        End = [DateTime]::MinValue
        Known = $true
        Complete = $true
        Pending = $false
    }

    $json = $null
    $jsonCount = 0
    $invoked = $null
    foreach ($file in $Directory.GetFiles()) {
        $time = $file.LastWriteTimeUtc
        if ($time -gt $unit.End) { $unit.End = $time }
        if ($file.Name -eq "invoked.timestamp") {
            $invoked = $time
        } elseif ($file.Extension -eq ".json") {
            $json = $file
            $jsonCount++
        }
    }
    if ($jsonCount -eq 0) {
        $unit.Complete = $false
        return $unit
    }
    if ($jsonCount -gt 1) {
        $unit.Known = $false
        return $unit
    }
    $unit.Succeeded = $json.LastWriteTimeUtc
    if ($null -eq $invoked) { $unit.Invoked = $unit.Succeeded } else { $unit.Invoked = $invoked }

    $unit.Kind = [System.IO.Path]::GetFileNameWithoutExtension($json.Name)
    $unit.Crate = Get-CargoTargetCrateName $unit.Kind
    try {
        $hashText = [System.IO.File]::ReadAllText((Join-Path $Directory.FullName $unit.Kind)).Trim()
        $text = [System.IO.File]::ReadAllText($json.FullName)
    } catch {
        $unit.Known = $false
        return $unit
    }
    if ($hashText -match '^[0-9a-f]{16}$') {
        $unit.Fingerprint = $hashText
    } else {
        $unit.Pending = $true
    }

    $parts = @($unit.Name, $unit.Kind)
    foreach ($key in @("rustc", "target", "profile", "path", "config", "compile_kind")) {
        $field = [regex]::Match($text, '"' + $key + '":(\d+)')
        if (-not $field.Success) {
            $unit.Known = $false
            return $unit
        }
        $parts += $field.Groups[1].Value
    }
    $features = [regex]::Match($text, '"features":"((?:[^"\\]|\\.)*)"')
    $rustflags = [regex]::Match($text, '"rustflags":(\[(?:[^\[\]"]|"(?:[^"\\]|\\.)*")*\])')
    $deps = [regex]::Match($text, '"deps":(\[(?>"(?:[^"\\]|\\.)*"|[^\[\]"]+|\[(?<open>)|\](?<-open>))*(?(open)(?!))\])')
    if (-not ($features.Success -and $rustflags.Success -and $deps.Success)) {
        $unit.Known = $false
        return $unit
    }
    $parts += $features.Groups[1].Value
    $parts += $rustflags.Groups[1].Value
    $unit.Family = $parts -join "|"

    # An edge is [package id hash, extern name, public, fingerprint]. If the count
    # of entries and of parsed edges disagree, the shape changed: unknown, not empty.
    $edges = [regex]::Matches($deps.Groups[1].Value, '\[\d+,"(?:[^"\\]|\\.)*",(?:true|false),(\d+)')
    $entries = [regex]::Matches($deps.Groups[1].Value, '\[\d+,').Count
    if ($edges.Count -ne $entries) {
        $unit.Known = $false
        return $unit
    }
    $unit.Deps = @(foreach ($edge in $edges) { ConvertTo-FingerprintHex $edge.Groups[1].Value $HexCache })
    return $unit
}

function Resolve-CargoArtifactPath {
    <#
      Which profile directory an artifact from a JSON message lives in, and the
      unit hash its path carries: deps\<crate>-<hash>.*, examples\<crate>-<hash>.*,
      build\<package>-<hash>\... An uplifted file carries no hash.
    #>
    param([string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path)
    $inDeps = [regex]::Match($full, '^(?<profile>.+)\\(?:deps|examples)\\(?<file>[^\\]+)$')
    if ($inDeps.Success) {
        $hash = [regex]::Match($inDeps.Groups["file"].Value, '-(?<hash>[0-9a-f]{16})(?:\.|$)')
        $value = $null
        if ($hash.Success) { $value = $hash.Groups["hash"].Value }
        return [pscustomobject]@{ ProfileDir = $inDeps.Groups["profile"].Value; Hash = $value }
    }
    $inBuild = [regex]::Match($full, '^(?<profile>.+)\\build\\[^\\]+-(?<hash>[0-9a-f]{16})(?:\\.*)?$')
    if ($inBuild.Success) {
        return [pscustomobject]@{ ProfileDir = $inBuild.Groups["profile"].Value; Hash = $inBuild.Groups["hash"].Value }
    }
    return [pscustomobject]@{ ProfileDir = [System.IO.Path]::GetDirectoryName($full); Hash = $null }
}

function Get-CargoLiveUnits {
    <#
      What the build that just ran used, from Cargo's JSON messages, grouped by
      profile directory (key: the lower-cased full path):
        Hashes - unit hashes read off deps\ and build\ paths.
        Bins   - bin targets whose only artifact is UNHASHED. On MSVC Cargo never
                 puts the hash in a path package's executable name (the PDB path
                 is embedded in the exe), so that unit is identified by its edges.
    #>
    param([string[]]$Messages)
    $byProfile = @{}
    foreach ($line in $Messages) {
        if ([string]::IsNullOrEmpty($line) -or $line[0] -ne '{') { continue }
        if ($line -notmatch '"reason":"(compiler-artifact|build-script-executed)"') { continue }
        $message = $line | ConvertFrom-Json
        $binTarget = $null
        if ($message.reason -eq "build-script-executed") {
            $paths = @([string]$message.out_dir)
        } else {
            $paths = @($message.filenames) + @($message.executable)
            if (@($message.target.kind) -contains "bin") { $binTarget = [string]$message.target.name }
        }
        foreach ($path in $paths) {
            if ([string]::IsNullOrEmpty($path)) { continue }
            $artifact = Resolve-CargoArtifactPath $path
            $key = $artifact.ProfileDir.ToLowerInvariant()
            $entry = $byProfile[$key]
            if ($null -eq $entry) {
                $entry = @{
                    Hashes = New-Object System.Collections.Generic.HashSet[string]
                    Bins = New-Object System.Collections.Generic.HashSet[string]
                }
                $byProfile[$key] = $entry
            }
            if ($artifact.Hash) {
                [void]$entry.Hashes.Add($artifact.Hash)
            } elseif ($binTarget) {
                [void]$entry.Bins.Add($binTarget)
            }
        }
    }
    return $byProfile
}

function Get-DirectoryBytes {
    param([string]$Path)
    $total = [int64]0
    try {
        foreach ($file in ([System.IO.DirectoryInfo]$Path).EnumerateFiles("*", [System.IO.SearchOption]::AllDirectories)) {
            $total += $file.Length
        }
    } catch {
        # The size is only reported, never decided on; an unreadable subtree counts as what was summed so far.
    }
    return $total
}

function Get-CargoPrunePlan {
    <#
      Decides, without touching anything, which units, orphaned artifacts and
      incremental directories of one profile directory go. Status "pruned" means
      Items is the plan; anything else leaves the profile alone, Detail says why.
    #>
    param(
        [string]$ProfileDir,
        # This profile's entry from Get-CargoLiveUnits, or $null when the build did not use it.
        $LiveUnits,
        [string[]]$LocalPackages = @(),
        [int]$RetentionDays = 30,
        [DateTime]$NowUtc = [DateTime]::UtcNow
    )

    $plan = [pscustomobject]@{
        Status = "pruned"
        Detail = ""
        Units = 0
        Unreadable = 0
        RemovedUnits = 0
        Items = New-Object System.Collections.Generic.List[object]
    }
    $fingerprintRoot = Join-Path $ProfileDir ".fingerprint"
    $hexCache = @{}
    $units = New-Object System.Collections.Generic.List[object]
    foreach ($directory in ([System.IO.DirectoryInfo]$fingerprintRoot).GetDirectories()) {
        $unit = Read-CargoUnit $directory $hexCache
        if ($null -ne $unit) { $units.Add($unit) }
    }
    $plan.Units = $units.Count

    $isLocal = @{}
    foreach ($name in $LocalPackages) { $isLocal[$name] = $true }
    $byHash = @{}
    $byFingerprint = @{}
    $localUnreadable = $false
    foreach ($unit in $units) {
        $byHash[$unit.Hash] = $unit
        if (-not $unit.Known) {
            $plan.Unreadable++
            if ($isLocal.ContainsKey($unit.Name)) { $localUnreadable = $true }
        }
        if ($unit.Fingerprint) {
            if (-not $byFingerprint.ContainsKey($unit.Fingerprint)) {
                $byFingerprint[$unit.Fingerprint] = New-Object System.Collections.Generic.List[object]
            }
            $byFingerprint[$unit.Fingerprint].Add($unit)
        }
    }

    $liveHashes = New-Object System.Collections.Generic.HashSet[string]
    if ($null -ne $LiveUnits) {
        foreach ($hash in $LiveUnits.Hashes) {
            $unit = $byHash[$hash]
            if ($null -eq $unit -or -not $unit.Known -or -not $unit.Complete -or $unit.Pending) {
                $plan.Status = "aborted"
                $plan.Detail = "live unit $hash has no usable fingerprint"
                return $plan
            }
            [void]$liveHashes.Add($hash)
        }
        foreach ($binTarget in $LiveUnits.Bins) {
            $candidates = @(foreach ($unit in $units) {
                if ($unit.Known -and $unit.Complete -and -not $unit.Pending -and $isLocal.ContainsKey($unit.Name) -and $unit.Kind -eq "bin-$binTarget") { $unit }
            })
            if ($candidates.Count -eq 0) {
                $plan.Status = "aborted"
                $plan.Detail = "live bin $binTarget has no fingerprint"
                return $plan
            }
            # The unit that was built against exactly the live dependencies. An old
            # version's bin points at an old build-script run, another RUSTFLAGS
            # value's bin at other copies of every dependency.
            $builtAgainstLive = @(foreach ($unit in $candidates) {
                if ($unit.Deps.Count -eq 0) { continue }
                $allLive = $true
                foreach ($dep in $unit.Deps) {
                    $depIsLive = $false
                    if ($byFingerprint.ContainsKey($dep)) {
                        foreach ($target in $byFingerprint[$dep]) {
                            if ($liveHashes.Contains($target.Hash)) {
                                $depIsLive = $true
                                break
                            }
                        }
                    }
                    if (-not $depIsLive) {
                        $allLive = $false
                        break
                    }
                }
                if ($allLive) { $unit }
            })
            if ($builtAgainstLive.Count -eq 0) {
                $builtAgainstLive = @($candidates | Sort-Object -Property End -Descending | Select-Object -First 1)
            }
            foreach ($unit in $builtAgainstLive) { [void]$liveHashes.Add($unit.Hash) }
        }
        # Cargo validated every edge of a live unit moments ago. One that does not
        # resolve means this script misreads the layout, and nothing may be removed.
        foreach ($hash in $liveHashes) {
            foreach ($dep in $byHash[$hash].Deps) {
                if (-not $byFingerprint.ContainsKey($dep)) {
                    $plan.Status = "aborted"
                    $plan.Detail = "an edge of live unit $($byHash[$hash].Name)-$hash does not resolve"
                    return $plan
                }
            }
        }
    }

    # Newest unit per configuration of the local package. Ordinal keys: two
    # RUSTFLAGS values that differ only in case are two configurations.
    $families = New-Object System.Collections.Hashtable ([StringComparer]::Ordinal)
    foreach ($unit in $units) {
        if (-not ($unit.Known -and $unit.Complete -and $isLocal.ContainsKey($unit.Name))) { continue }
        $family = $families[$unit.Family]
        if ($null -eq $family) {
            $family = @{ Newest = $unit; HasLive = $false }
            $families[$unit.Family] = $family
        } elseif ($unit.End -gt $family.Newest.End) {
            $family.Newest = $unit
        }
        if ($liveHashes.Contains($unit.Hash)) { $family.HasLive = $true }
    }
    $roots = New-Object System.Collections.Generic.List[object]
    foreach ($hash in $liveHashes) { $roots.Add($byHash[$hash]) }
    $cutoff = $NowUtc.AddDays(-$RetentionDays)
    foreach ($family in $families.Values) {
        if (-not $family.HasLive -and $family.Newest.End -ge $cutoff) { $roots.Add($family.Newest) }
    }
    # Only a current build of the package itself may anchor a prune: if the package
    # name was misread, every unit would look unreachable.
    if ($roots.Count -eq 0) {
        $plan.Status = "skipped"
        $plan.Detail = "no recent build of $($LocalPackages -join ', ') to anchor on"
        return $plan
    }
    $edgeCount = 0
    $resolvedCount = 0
    foreach ($root in $roots) {
        foreach ($dep in $root.Deps) {
            $edgeCount++
            if ($byFingerprint.ContainsKey($dep)) { $resolvedCount++ }
        }
    }
    if ($edgeCount -gt 0 -and ($resolvedCount * 2) -lt $edgeCount) {
        $plan.Status = "aborted"
        $plan.Detail = "only $resolvedCount of $edgeCount dependency edges resolve"
        return $plan
    }

    # Two more kinds of root, neither of which may anchor on its own:
    # - a dependency whose recompile failed within the retention window: the next
    #   attempt needs everything its last success was built against;
    # - anything compiled in the last day that no live unit supersedes - the
    #   dependencies of a check that failed before it EVER succeeded have no edge
    #   leading to them at all.
    # A superseded unit (a live one shares its configuration) is garbage however new.
    $liveFamilies = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::Ordinal)
    foreach ($hash in $liveHashes) { [void]$liveFamilies.Add($byHash[$hash].Family) }
    $recent = $NowUtc.AddDays(-1)
    foreach ($unit in $units) {
        # -and and -or share one precedence in PowerShell: the parentheses say what is meant.
        if ((-not $unit.Known) -or ($isLocal.ContainsKey($unit.Name) -and $unit.Complete)) { continue }
        $superseded = $unit.Complete -and $liveFamilies.Contains($unit.Family)
        if ($superseded) { continue }
        if (($unit.Pending -and $unit.End -ge $cutoff) -or $unit.End -ge $recent) { $roots.Add($unit) }
    }

    $kept = New-Object System.Collections.Generic.HashSet[string]
    $toVisit = New-Object System.Collections.Generic.Stack[object]
    foreach ($root in $roots) {
        if ($kept.Add($root.Hash)) { $toVisit.Push($root) }
    }
    while ($toVisit.Count -gt 0) {
        $unit = $toVisit.Pop()
        foreach ($dep in $unit.Deps) {
            if (-not $byFingerprint.ContainsKey($dep)) { continue }
            foreach ($target in $byFingerprint[$dep]) {
                if ($kept.Add($target.Hash)) { $toVisit.Push($target) }
            }
        }
    }
    foreach ($unit in $units) {
        if (-not $unit.Known) { [void]$kept.Add($unit.Hash) }
    }

    $artifacts = @{}
    foreach ($subdir in @("deps", "examples")) {
        $path = Join-Path $ProfileDir $subdir
        if (-not [System.IO.Directory]::Exists($path)) { continue }
        foreach ($file in ([System.IO.DirectoryInfo]$path).GetFiles()) {
            $hashMatch = [regex]::Match($file.Name, '-([0-9a-f]{16})(?:\.|$)')
            if (-not $hashMatch.Success) { continue }
            $hash = $hashMatch.Groups[1].Value
            if (-not $artifacts.ContainsKey($hash)) { $artifacts[$hash] = New-Object System.Collections.Generic.List[object] }
            $artifacts[$hash].Add($file)
        }
    }
    $buildDirs = @{}
    $buildRoot = Join-Path $ProfileDir "build"
    if ([System.IO.Directory]::Exists($buildRoot)) {
        foreach ($directory in ([System.IO.DirectoryInfo]$buildRoot).GetDirectories()) {
            $hashMatch = [regex]::Match($directory.Name, '-([0-9a-f]{16})$')
            if ($hashMatch.Success) { $buildDirs[$hashMatch.Groups[1].Value] = $directory }
        }
    }

    # Artifacts before the fingerprint: interrupted halfway, Cargo sees a unit
    # with missing outputs and rebuilds it, never a fingerprint vouching for nothing.
    foreach ($unit in $units) {
        if ($kept.Contains($unit.Hash)) { continue }
        $plan.RemovedUnits++
        if ($artifacts.ContainsKey($unit.Hash)) {
            foreach ($file in $artifacts[$unit.Hash]) {
                $plan.Items.Add([pscustomobject]@{ Path = $file.FullName; Kind = "unit"; IsDirectory = $false; Bytes = $file.Length })
            }
        }
        if ($buildDirs.ContainsKey($unit.Hash)) {
            $path = $buildDirs[$unit.Hash].FullName
            $plan.Items.Add([pscustomobject]@{ Path = $path; Kind = "unit"; IsDirectory = $true; Bytes = (Get-DirectoryBytes $path) })
        }
        $path = Join-Path $fingerprintRoot "$($unit.Name)-$($unit.Hash)"
        $plan.Items.Add([pscustomobject]@{ Path = $path; Kind = "unit"; IsDirectory = $true; Bytes = (Get-DirectoryBytes $path) })
    }
    foreach ($hash in @($artifacts.Keys)) {
        if ($byHash.ContainsKey($hash)) { continue }
        foreach ($file in $artifacts[$hash]) {
            $plan.Items.Add([pscustomobject]@{ Path = $file.FullName; Kind = "orphan"; IsDirectory = $false; Bytes = $file.Length })
        }
    }
    foreach ($hash in @($buildDirs.Keys)) {
        if ($byHash.ContainsKey($hash)) { continue }
        $path = $buildDirs[$hash].FullName
        $plan.Items.Add([pscustomobject]@{ Path = $path; Kind = "orphan"; IsDirectory = $true; Bytes = (Get-DirectoryBytes $path) })
    }

    # A local unit whose kind cannot be read could own any incremental directory.
    $incrementalRoot = Join-Path $ProfileDir "incremental"
    if ($localUnreadable -or -not [System.IO.Directory]::Exists($incrementalRoot)) { return $plan }
    $slack = [TimeSpan]::FromSeconds(5)
    $windows = @{}
    foreach ($unit in $units) {
        if (-not ($kept.Contains($unit.Hash) -and $unit.Known -and $unit.Complete -and $isLocal.ContainsKey($unit.Name))) { continue }
        if ($unit.Kind -like "run-*") { continue }
        if ($unit.Pending -or $unit.Invoked -gt $unit.Succeeded) {
            # The last attempt failed: rustc threw its session away, and the one left
            # is the last success's. That success's start was overwritten, so allow
            # it an hour - a debug test link on this disk alone has taken minutes.
            $low = $unit.Succeeded.AddHours(-1)
        } else {
            $low = $unit.Invoked - $slack
        }
        if (-not $windows.ContainsKey($unit.Crate)) { $windows[$unit.Crate] = New-Object System.Collections.Generic.List[object] }
        $windows[$unit.Crate].Add(@($low, ($unit.Succeeded + $slack)))
    }
    foreach ($crateDir in ([System.IO.DirectoryInfo]$incrementalRoot).GetDirectories()) {
        $crateMatch = [regex]::Match($crateDir.Name, '^(?<crate>.+)-[0-9a-z]+$')
        if (-not $crateMatch.Success) { continue }
        $crate = $crateMatch.Groups["crate"].Value
        $claimed = $false
        if ($windows.ContainsKey($crate)) {
            foreach ($entry in $crateDir.GetFileSystemInfos()) {
                $time = $entry.LastWriteTimeUtc
                foreach ($window in $windows[$crate]) {
                    if ($time -ge $window[0] -and $time -le $window[1]) {
                        $claimed = $true
                        break
                    }
                }
                if ($claimed) { break }
            }
        }
        if (-not $claimed) {
            $plan.Items.Add([pscustomobject]@{ Path = $crateDir.FullName; Kind = "incremental"; IsDirectory = $true; Bytes = (Get-DirectoryBytes $crateDir.FullName) })
        }
    }
    return $plan
}

function Invoke-CargoProfilePrune {
    <# Get-CargoPrunePlan under the profile's .cargo-lock, then carries it out. #>
    param(
        [string]$ProfileDir,
        $LiveUnits,
        [string[]]$LocalPackages = @(),
        [int]$RetentionDays = 30,
        [DateTime]$NowUtc = [DateTime]::UtcNow,
        [switch]$DryRun
    )
    $summary = [pscustomobject]@{
        ProfileDir = $ProfileDir
        Status = "skipped"
        Detail = ""
        Units = 0
        Unreadable = 0
        RemovedUnits = 0
        RemovedIncremental = 0
        RemovedOrphans = 0
        Bytes = [int64]0
        Failed = 0
    }
    if (-not [System.IO.Directory]::Exists((Join-Path $ProfileDir ".fingerprint"))) {
        $summary.Detail = "not a Cargo profile directory"
        return $summary
    }

    # Cargo takes an exclusive byte-range lock on this file for as long as it
    # works in the directory. LockFile fails at once instead of waiting.
    $lock = $null
    try {
        $lock = [System.IO.File]::Open((Join-Path $ProfileDir ".cargo-lock"), [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::ReadWrite)
        $lock.Lock(0, [long]::MaxValue)
    } catch {
        if ($null -ne $lock) { $lock.Dispose() }
        $summary.Detail = "Cargo is using it"
        return $summary
    }
    try {
        $plan = Get-CargoPrunePlan -ProfileDir $ProfileDir -LiveUnits $LiveUnits -LocalPackages $LocalPackages -RetentionDays $RetentionDays -NowUtc $NowUtc
        $summary.Status = $plan.Status
        $summary.Detail = $plan.Detail
        $summary.Units = $plan.Units
        $summary.Unreadable = $plan.Unreadable
        if ($plan.Status -ne "pruned") { return $summary }
        $summary.RemovedUnits = $plan.RemovedUnits
        foreach ($item in $plan.Items) {
            if (-not $DryRun) {
                try {
                    if ($item.IsDirectory) {
                        [System.IO.Directory]::Delete($item.Path, $true)
                    } else {
                        [System.IO.File]::Delete($item.Path)
                    }
                } catch {
                    # A test binary still running, a PDB held by a debugger: it stays
                    # for the next prune, and the count says so.
                    $summary.Failed++
                    continue
                }
            }
            $summary.Bytes += $item.Bytes
            if ($item.Kind -eq "incremental") { $summary.RemovedIncremental++ }
            if ($item.Kind -eq "orphan") { $summary.RemovedOrphans++ }
        }
        return $summary
    } finally {
        # Closing the handle releases the lock.
        $lock.Dispose()
    }
}

function Get-CargoPackageName {
    <# The [package] name from Cargo.toml, as an array (empty when there is none). #>
    param([string]$ManifestPath)
    if (-not [System.IO.File]::Exists($ManifestPath)) { return @() }
    $inPackage = $false
    foreach ($line in [System.IO.File]::ReadAllLines($ManifestPath)) {
        $section = [regex]::Match($line, '^\s*\[([^\]]+)\]\s*(#.*)?$')
        if ($section.Success) {
            $inPackage = $section.Groups[1].Value.Trim() -eq "package"
            continue
        }
        $name = [regex]::Match($line, '^\s*name\s*=\s*"([^"]+)"')
        if ($inPackage -and $name.Success) { return @($name.Groups[1].Value) }
    }
    return @()
}

function Get-StaleInstallers {
    <# Every DelegatorSetup-*.exe in dist\ except the one the build just produced. #>
    param([string]$DistDir, [string]$KeepInstaller)
    if (-not [System.IO.Directory]::Exists($DistDir)) { return @() }
    $keep = [System.IO.Path]::GetFullPath($KeepInstaller)
    return @(foreach ($file in ([System.IO.DirectoryInfo]$DistDir).GetFiles("DelegatorSetup-*.exe")) {
        # .NET's 3-letter extension quirk would also match ".exe_" and the like.
        if ($file.Extension -ne ".exe") { continue }
        if (-not [string]::Equals($file.FullName, $keep, [StringComparison]::OrdinalIgnoreCase)) { $file }
    })
}

function Get-RecycleBinRefusal {
    <#
      Why the Recycle Bin would NOT keep this file, or $null when it would. With
      FOF_NOCONFIRMATION, SHFileOperation deletes for good - and still returns 0 -
      when the bin is switched off for the volume or the file exceeds its size
      limit, so both are read first from the settings Explorer itself uses.
    #>
    param([System.IO.FileInfo]$File)
    foreach ($policy in @("HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer", "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer")) {
        $noRecycle = (Get-ItemProperty -LiteralPath $policy -Name NoRecycleFiles -ErrorAction SilentlyContinue).NoRecycleFiles
        if ($noRecycle -eq 1) { return "a policy switches the Recycle Bin off" }
    }
    $drive = [System.IO.Path]::GetPathRoot($File.FullName).TrimEnd('\')
    if ($drive -notmatch '^[A-Za-z]:$') { return "$drive has no Recycle Bin" }
    $volume = Get-CimInstance -ClassName Win32_Volume -Filter "DriveLetter='$drive'" -ErrorAction SilentlyContinue
    $guid = [regex]::Match([string]$volume.DeviceID, '\{[0-9A-Fa-f-]+\}').Value
    if (-not $guid) { return "no volume found for $drive" }
    $settings = Get-ItemProperty -LiteralPath "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\BitBucket\Volume\$guid" -ErrorAction SilentlyContinue
    if ($null -ne $settings) {
        if ($settings.NukeOnDelete -eq 1) { return "the Recycle Bin is off for $drive" }
        if ($null -ne $settings.MaxCapacity -and $File.Length -gt ([int64]$settings.MaxCapacity * 1MB)) {
            return "larger than the Recycle Bin of $drive"
        }
    }
    return $null
}

function Send-ToRecycleBin {
    <#
      Returns 0 once the shell reports the delete done. An old installer is not a
      cache: a version that was never tagged cannot be rebuilt, so it goes where
      the owner can still take it back - Get-RecycleBinRefusal decides whether it
      would. No dialog ever (FOF_NOERRORUI): this runs at the end of an unattended
      build.
    #>
    param([string]$Path)
    # SHFILEOPSTRUCT is packed differently in a 32-bit process.
    if (-not [Environment]::Is64BitProcess) { return -2 }
    if (-not ("DelegatorBuild.RecycleBin" -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace DelegatorBuild
{
    public static class RecycleBin
    {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct SHFILEOPSTRUCT
        {
            public IntPtr hwnd;
            public uint wFunc;
            public string pFrom;
            public string pTo;
            public ushort fFlags;
            [MarshalAs(UnmanagedType.Bool)] public bool fAnyOperationsAborted;
            public IntPtr hNameMappings;
            public string lpszProgressTitle;
        }

        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        private static extern int SHFileOperation(ref SHFILEOPSTRUCT operation);

        public static int Send(string path)
        {
            SHFILEOPSTRUCT operation = new SHFILEOPSTRUCT();
            operation.wFunc = 3;                               // FO_DELETE
            operation.pFrom = path + "\0\0";                   // a double-NUL-terminated list
            operation.fFlags = 0x0040 | 0x0010 | 0x0400 | 0x0004; // ALLOWUNDO | NOCONFIRMATION | NOERRORUI | SILENT
            int result = SHFileOperation(ref operation);
            if (result == 0 && operation.fAnyOperationsAborted) { result = -1; }
            return result;
        }
    }
}
'@
    }
    return [DelegatorBuild.RecycleBin]::Send([System.IO.Path]::GetFullPath($Path))
}

function Invoke-InstallerPrune {
    <#
      Every other DelegatorSetup-*.exe in dist\ to the Recycle Bin. Refuses when
      the installer to keep is missing, or older than -BuiltAfterUtc: then the
      build did not produce it (its version line and installer\Delegator.iss
      disagree), and "every other installer" would include the one it did produce.
      Moved: names gone to the bin (or that would go, on a dry run). Left: what
      stays, with why.
    #>
    param([string]$DistDir, [string]$KeepInstaller, [Nullable[DateTime]]$BuiltAfterUtc = $null, [switch]$DryRun)
    $result = [pscustomobject]@{ Status = "pruned"; Detail = ""; Moved = @(); Left = @() }
    if (-not [System.IO.File]::Exists($KeepInstaller)) {
        $result.Status = "skipped"
        $result.Detail = "$KeepInstaller does not exist"
        return $result
    }
    if ($null -ne $BuiltAfterUtc -and [System.IO.File]::GetLastWriteTimeUtc($KeepInstaller) -lt [DateTime]$BuiltAfterUtc) {
        $result.Status = "skipped"
        $result.Detail = "$KeepInstaller is older than this build"
        return $result
    }
    foreach ($stale in @(Get-StaleInstallers -DistDir $DistDir -KeepInstaller $KeepInstaller)) {
        if ($DryRun) {
            $result.Moved += $stale.Name
            continue
        }
        $refusal = Get-RecycleBinRefusal $stale
        if ($refusal) {
            $result.Left += "$($stale.Name) ($refusal)"
            continue
        }
        $code = Send-ToRecycleBin $stale.FullName
        if ($code -eq 0 -and -not [System.IO.File]::Exists($stale.FullName)) {
            $result.Moved += $stale.Name
        } else {
            $result.Left += "$($stale.Name) (SHFileOperation returned $code)"
        }
    }
    return $result
}

function Format-ByteSize {
    param([int64]$Bytes)
    if ($Bytes -ge 1GB) { return "{0:N1} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N0} MB" -f ($Bytes / 1MB) }
    return "{0:N0} KB" -f ($Bytes / 1KB)
}

if ($MyInvocation.InvocationName -eq ".") { return }

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
if (-not $TargetDir) { $TargetDir = Join-Path $projectRoot "target" }
$TargetDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($TargetDir)
$freedVerb = "freed"
if ($DryRun) { $freedVerb = "would free" }

$localPackages = @(Get-CargoPackageName (Join-Path $projectRoot "Cargo.toml"))
if ($localPackages.Count -eq 0) {
    Write-Warning "prune: no [package] name in Cargo.toml, target\ left untouched"
} elseif ([System.IO.Directory]::Exists($TargetDir)) {
    $live = Get-CargoLiveUnits $CargoMessages
    # target\<profile>, and target\<triple or tool>\<profile> one level down.
    $profileDirs = @(foreach ($directory in ([System.IO.DirectoryInfo]$TargetDir).GetDirectories()) {
        if ([System.IO.Directory]::Exists((Join-Path $directory.FullName ".fingerprint"))) {
            $directory.FullName
            continue
        }
        foreach ($nested in $directory.GetDirectories()) {
            if ([System.IO.Directory]::Exists((Join-Path $nested.FullName ".fingerprint"))) { $nested.FullName }
        }
    })
    foreach ($profileDir in $profileDirs) {
        $summary = Invoke-CargoProfilePrune -ProfileDir $profileDir -LiveUnits $live[$profileDir.ToLowerInvariant()] -LocalPackages $localPackages -RetentionDays $RetentionDays -DryRun:$DryRun
        $label = $profileDir.Substring($TargetDir.Length).TrimStart('\')
        if ($summary.Status -ne "pruned") {
            Write-Host ("prune {0}: {1} - {2}" -f $label, $summary.Status, $summary.Detail)
            continue
        }
        $line = "prune {0}: {1} of {2} units, {3} incremental, {4} orphaned - {5} {6}" -f $label, $summary.RemovedUnits, $summary.Units, $summary.RemovedIncremental, $summary.RemovedOrphans, $freedVerb, (Format-ByteSize $summary.Bytes)
        if ($summary.Failed -gt 0) { $line += " ($($summary.Failed) in use, left for next time)" }
        if ($summary.Unreadable -gt 0) { $line += " ($($summary.Unreadable) unreadable fingerprints kept)" }
        Write-Host $line
    }
}

if ($DistDir -and $KeepInstaller) {
    $DistDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DistDir)
    $KeepInstaller = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($KeepInstaller)
    $installers = Invoke-InstallerPrune -DistDir $DistDir -KeepInstaller $KeepInstaller -BuiltAfterUtc $BuiltAfterUtc -DryRun:$DryRun
    if ($installers.Status -ne "pruned") {
        Write-Warning "prune dist: $($installers.Detail), dist\ left untouched"
    }
    $movedVerb = "moved to the Recycle Bin"
    if ($DryRun) { $movedVerb = "would go to the Recycle Bin" }
    foreach ($name in $installers.Moved) { Write-Host "prune dist: $name $movedVerb" }
    foreach ($entry in $installers.Left) { Write-Warning "prune dist: $entry stays" }
}
