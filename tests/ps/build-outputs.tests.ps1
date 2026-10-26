<#
    prune-build-outputs.ps1: what the post-build prune may remove from a Cargo
    target directory, and what it must keep.

    The expensive mistake is removing a cache the next build needs - that is a
    rebuild, and a release rebuild here is minutes of fat LTO on a spinning disk.
    The cheap one is keeping garbage. So every case builds a small profile
    directory in the shape Cargo 1.95 writes it (fingerprint JSON, the
    little-endian hash file, deps\ artifacts, incremental sessions) and asserts
    on what is left on disk, not on what the plan claims.
#>

$script:PruneNow = [DateTime]::UtcNow

function ConvertTo-TestEdge {
    # The decimal a dependency edge stores for the little-endian hex a hash file holds.
    param([string]$Hex)
    $bytes = New-Object byte[] 8
    for ($i = 0; $i -lt 8; $i++) { $bytes[$i] = [Convert]::ToByte($Hex.Substring($i * 2, 2), 16) }
    return [BitConverter]::ToUInt64($bytes, 0).ToString([Globalization.CultureInfo]::InvariantCulture)
}

function New-TestProfileDir {
    $dir = Join-Path $script:Sandbox ("cargo-" + [Guid]::NewGuid().ToString("n").Substring(0, 8) + "\debug")
    foreach ($sub in @(".fingerprint", "deps", "build", "incremental")) {
        New-Item -ItemType Directory -Force -Path (Join-Path $dir $sub) | Out-Null
    }
    [System.IO.File]::WriteAllText((Join-Path $dir ".cargo-lock"), "")
    return $dir
}

function New-TestUnit {
    param(
        [string]$ProfileDir,
        [string]$Name,
        [string]$Hash,
        [string]$Kind,
        [string]$Fingerprint,
        [string[]]$Deps = @(),
        [string]$ProfileHash = "9",
        [string]$SourcePath = "500",
        [string]$Rustflags = "[]",
        # When Cargo last STARTED the unit (invoked.timestamp).
        [DateTime]$Compiled = $script:PruneNow.AddHours(-1),
        # When it last recorded a SUCCESS (the JSON). Defaults to 8 s after $Compiled.
        [Nullable[DateTime]]$Written = $null,
        # The attempt started at $Compiled failed: Cargo emptied the hash file then.
        [switch]$Pending,
        [string[]]$Artifacts = @(),
        [switch]$BuildDir
    )
    if ($null -eq $Written) { $Written = $Compiled.AddSeconds(8) }
    $dir = Join-Path $ProfileDir ".fingerprint\$Name-$Hash"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $edges = @(foreach ($dep in $Deps) { '[7,"dep",false,' + (ConvertTo-TestEdge $dep) + ']' }) -join ","
    $json = '{"rustc":11,"features":"[]","declared_features":"[]","target":22,"profile":' + $ProfileHash +
        ',"path":' + $SourcePath + ',"deps":[' + $edges + '],"local":[{"CheckDepInfo":{"dep_info":"x","checksum":false}}],' +
        '"rustflags":' + $Rustflags + ',"config":33,"compile_kind":0}'
    [System.IO.File]::WriteAllText((Join-Path $dir "$Kind.json"), $json)
    [System.IO.File]::WriteAllText((Join-Path $dir "invoked.timestamp"), "")
    [System.IO.File]::SetLastWriteTimeUtc((Join-Path $dir "invoked.timestamp"), $Compiled)
    [System.IO.File]::SetLastWriteTimeUtc((Join-Path $dir "$Kind.json"), [DateTime]$Written)
    if ($Pending) {
        [System.IO.File]::WriteAllText((Join-Path $dir $Kind), "")
        [System.IO.File]::SetLastWriteTimeUtc((Join-Path $dir $Kind), $Compiled)
    } else {
        [System.IO.File]::WriteAllText((Join-Path $dir $Kind), $Fingerprint)
        [System.IO.File]::SetLastWriteTimeUtc((Join-Path $dir $Kind), [DateTime]$Written)
    }
    foreach ($artifact in $Artifacts) {
        [System.IO.File]::WriteAllBytes((Join-Path $ProfileDir "deps\$artifact"), (New-Object byte[] 1024))
    }
    if ($BuildDir) {
        $out = Join-Path $ProfileDir "build\$Name-$Hash\out"
        New-Item -ItemType Directory -Force -Path $out | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $out "resource.rc"), "")
    }
}

function New-TestSession {
    # An incremental crate directory whose one session was finalized at $At.
    param([string]$ProfileDir, [string]$CrateDir, [DateTime]$At, [switch]$NoLock)
    $dir = Join-Path $ProfileDir "incremental\$CrateDir"
    $session = Join-Path $dir "s-hm7hg6bkao-0r1yirs-6bvgjechm52qrh9wo6ptro868"
    New-Item -ItemType Directory -Force -Path $session | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $session "dep-graph.bin"), "")
    [System.IO.File]::SetLastWriteTimeUtc((Join-Path $session "dep-graph.bin"), $At)
    if (-not $NoLock) {
        [System.IO.File]::WriteAllText((Join-Path $dir "s-hm7hg6bkao-0r1yirs.lock"), "")
        [System.IO.File]::SetLastWriteTimeUtc((Join-Path $dir "s-hm7hg6bkao-0r1yirs.lock"), $At.AddSeconds(-4))
    }
    [System.IO.Directory]::SetLastWriteTimeUtc($session, $At)
}

function Test-UnitPresent {
    param([string]$ProfileDir, [string]$Unit)
    return (Test-Path -LiteralPath (Join-Path $ProfileDir ".fingerprint\$Unit"))
}

function New-TestMessage {
    param([string]$ProfileDir, [string[]]$Filenames = @(), [string]$Executable, [string]$OutDir, [string]$Kind = "lib", [string]$TargetName = "x")
    if ($OutDir) {
        return (@{ reason = "build-script-executed"; out_dir = (Join-Path $ProfileDir $OutDir) } | ConvertTo-Json -Compress)
    }
    $message = @{
        reason = "compiler-artifact"
        target = @{ kind = @($Kind); name = $TargetName }
        filenames = @(foreach ($file in $Filenames) { Join-Path $ProfileDir $file })
        executable = $null
        fresh = $true
    }
    if ($Executable) { $message.executable = Join-Path $ProfileDir $Executable }
    return ($message | ConvertTo-Json -Compress -Depth 5)
}

function New-TestScenario {
    <#
      One debug profile holding every relationship the prune distinguishes:
        serde-...01 / delegator-...(2|3)01   live: the dependency, build-script run and test unit just used
        delegator-3...02 + serde-...02       the previous version's test unit and the serde it linked
        delegator-4...01 / 4...02            `cargo build`'s debug bin: newest kept, older gone
        delegator-5...01 + serde-...03       rust-analyzer's check units, 10 days old, current serde version
        delegator-6...01 + serde-...04       a RUSTFLAGS configuration last built 40 days ago
    #>
    $p = New-TestProfileDir
    $old = $script:PruneNow.AddDays(-3)
    New-TestUnit $p "serde" "1000000000000001" "lib-serde" "a100000000000001" -Artifacts @("libserde-1000000000000001.rlib", "libserde-1000000000000001.rmeta") -ProfileHash "4"
    New-TestUnit $p "serde" "1000000000000002" "lib-serde" "a100000000000002" -SourcePath "499" -Compiled $old -Artifacts @("libserde-1000000000000002.rlib") -ProfileHash "4"
    New-TestUnit $p "serde" "1000000000000003" "lib-serde" "a100000000000003" -ProfileHash "3" -Compiled $script:PruneNow.AddDays(-20) -Artifacts @("libserde-1000000000000003.rmeta")
    New-TestUnit $p "serde" "1000000000000004" "lib-serde" "a100000000000004" -ProfileHash "4" -Rustflags '["--remap-path-prefix=X=Y"]' -Compiled $script:PruneNow.AddDays(-40) -Artifacts @("libserde-1000000000000004.rlib")
    New-TestUnit $p "delegator" "2000000000000001" "run-build-script-build-script-build" "b100000000000001" -ProfileHash "0" -SourcePath "0" -BuildDir
    New-TestUnit $p "delegator" "2000000000000002" "run-build-script-build-script-build" "b100000000000002" -ProfileHash "0" -SourcePath "0" -Compiled $old -BuildDir
    New-TestUnit $p "delegator" "3000000000000001" "test-bin-delegator" "c100000000000001" -Deps @("a100000000000001", "b100000000000001") -Artifacts @("delegator-3000000000000001.exe", "delegator-3000000000000001.pdb")
    New-TestUnit $p "delegator" "3000000000000002" "test-bin-delegator" "c100000000000002" -Deps @("a100000000000002", "b100000000000002") -Compiled $old -Artifacts @("delegator-3000000000000002.exe", "delegator-3000000000000002.pdb")
    New-TestUnit $p "delegator" "4000000000000001" "bin-delegator" "d100000000000001" -ProfileHash "8" -Deps @("a100000000000001") -Compiled $script:PruneNow.AddDays(-2)
    New-TestUnit $p "delegator" "4000000000000002" "bin-delegator" "d100000000000002" -ProfileHash "8" -Deps @("a100000000000002") -Compiled $script:PruneNow.AddDays(-5)
    New-TestUnit $p "delegator" "5000000000000001" "bin-delegator" "e100000000000001" -ProfileHash "6" -Deps @("a100000000000003") -Compiled $script:PruneNow.AddDays(-10)
    New-TestUnit $p "delegator" "6000000000000001" "test-bin-delegator" "f100000000000001" -Rustflags '["--remap-path-prefix=X=Y"]' -Deps @("a100000000000004") -Compiled $script:PruneNow.AddDays(-40)
    $messages = @(
        (New-TestMessage $p -Executable "deps\delegator-3000000000000001.exe" -Filenames @("deps\delegator-3000000000000001.exe") -Kind "bin" -TargetName "delegator"),
        (New-TestMessage $p -Filenames @("deps\libserde-1000000000000001.rlib", "deps\libserde-1000000000000001.rmeta") -TargetName "serde"),
        (New-TestMessage $p -OutDir "build\delegator-2000000000000001\out")
    )
    return [pscustomobject]@{ ProfileDir = $p; Messages = $messages }
}

function Invoke-TestPrune {
    param($Scenario, [switch]$WithoutMessages, [switch]$DryRun)
    $live = $null
    if (-not $WithoutMessages) {
        $live = (Get-CargoLiveUnits $Scenario.Messages)[$Scenario.ProfileDir.ToLowerInvariant()]
    }
    return Invoke-CargoProfilePrune -ProfileDir $Scenario.ProfileDir -LiveUnits $live -LocalPackages @("delegator") -NowUtc $script:PruneNow -DryRun:$DryRun
}

Test-Case "an edge's decimal and a hash file's hex are the same little-endian value" {
    # The pair measured in this repository's target\debug, not a constructed one.
    Assert-Equal "cdfcff5bd88670a9" (ConvertTo-FingerprintHex "12209406853615975629")
    Assert-Equal "12209406853615975629" (ConvertTo-TestEdge "cdfcff5bd88670a9")
}

Test-Case "a kind file names its crate the way rustc names the incremental directory" {
    Assert-Equal "delegator" (Get-CargoTargetCrateName "test-bin-delegator")
    Assert-Equal "delegator" (Get-CargoTargetCrateName "bin-delegator")
    Assert-Equal "build_script_build" (Get-CargoTargetCrateName "build-script-build-script-build")
    Assert-Equal "build_script_build" (Get-CargoTargetCrateName "run-build-script-build-script-build")
    Assert-Equal "raw_window_handle" (Get-CargoTargetCrateName "lib-raw_window_handle")
    Assert-Equal "test_runner" (Get-CargoTargetCrateName "bin-test-runner")
}

Test-Case "live artifacts are grouped by profile directory, with or without a hash" {
    $p = New-TestProfileDir
    $live = Get-CargoLiveUnits @(
        (New-TestMessage $p -Executable "deps\delegator-3000000000000001.exe" -Kind "bin" -TargetName "delegator"),
        (New-TestMessage $p -Filenames @("deps\serde_derive-1000000000000009.dll", "deps\serde_derive-1000000000000009.pdb") -Kind "proc-macro"),
        (New-TestMessage $p -Filenames @("build\ring-2000000000000009\build-script-build.exe") -Kind "custom-build"),
        (New-TestMessage $p -OutDir "build\ring-2000000000000008\out"),
        (New-TestMessage $p -Filenames @("delegator.exe", "delegator.pdb") -Kind "bin" -TargetName "delegator"),
        "   Compiling serde v1.0.228",
        '{"reason":"build-finished","success":true}'
    )
    $entry = $live[$p.ToLowerInvariant()]
    Assert-NotNull $entry
    Assert-Equal 4 $entry.Hashes.Count
    foreach ($hash in @("3000000000000001", "1000000000000009", "2000000000000009", "2000000000000008")) {
        Assert-True ($entry.Hashes.Contains($hash)) "hash $hash"
    }
    Assert-Equal 1 $entry.Bins.Count
    Assert-True ($entry.Bins.Contains("delegator"))
}

Test-Case "the previous version goes, everything the build used stays" {
    $s = New-TestScenario
    $p = $s.ProfileDir
    $summary = Invoke-TestPrune $s
    Assert-Equal "pruned" $summary.Status $summary.Detail
    foreach ($unit in @("serde-1000000000000001", "delegator-2000000000000001", "delegator-3000000000000001")) {
        Assert-True (Test-UnitPresent $p $unit) "live unit $unit must stay"
    }
    Assert-True (Test-Path -LiteralPath (Join-Path $p "deps\delegator-3000000000000001.pdb"))
    Assert-True (Test-Path -LiteralPath (Join-Path $p "deps\libserde-1000000000000001.rlib"))
    Assert-True (Test-Path -LiteralPath (Join-Path $p "build\delegator-2000000000000001\out"))
    foreach ($unit in @("delegator-3000000000000002", "serde-1000000000000002", "delegator-2000000000000002")) {
        Assert-False (Test-UnitPresent $p $unit) "superseded unit $unit must go"
    }
    Assert-False (Test-Path -LiteralPath (Join-Path $p "deps\delegator-3000000000000002.pdb")) "its PDB is the bulk of the garbage"
    Assert-False (Test-Path -LiteralPath (Join-Path $p "build\delegator-2000000000000002"))
}

Test-Case "another live configuration of the package keeps what it links against" {
    $s = New-TestScenario
    $p = $s.ProfileDir
    Invoke-TestPrune $s | Out-Null
    # `cargo build`'s bin: only the newest of its configuration.
    Assert-True (Test-UnitPresent $p "delegator-4000000000000001")
    Assert-False (Test-UnitPresent $p "delegator-4000000000000002")
    # rust-analyzer's check units are 10 and 20 days old and still a cache.
    Assert-True (Test-UnitPresent $p "delegator-5000000000000001")
    Assert-True (Test-UnitPresent $p "serde-1000000000000003") "a check-mode dependency is reachable from its check root"
    Assert-True (Test-Path -LiteralPath (Join-Path $p "deps\libserde-1000000000000003.rmeta"))
}

Test-Case "a configuration nobody compiled within the retention window goes with its dependencies" {
    $s = New-TestScenario
    $p = $s.ProfileDir
    Invoke-TestPrune $s | Out-Null
    Assert-False (Test-UnitPresent $p "delegator-6000000000000001")
    Assert-False (Test-UnitPresent $p "serde-1000000000000004")
    Assert-False (Test-Path -LiteralPath (Join-Path $p "deps\libserde-1000000000000004.rlib"))
}

Test-Case "without messages the newest unit of each configuration anchors the prune" {
    $s = New-TestScenario
    $p = $s.ProfileDir
    $summary = Invoke-TestPrune $s -WithoutMessages
    Assert-Equal "pruned" $summary.Status $summary.Detail
    Assert-True (Test-UnitPresent $p "delegator-3000000000000001")
    Assert-True (Test-UnitPresent $p "serde-1000000000000001")
    Assert-True (Test-UnitPresent $p "delegator-2000000000000001")
    Assert-False (Test-UnitPresent $p "delegator-3000000000000002")
    Assert-False (Test-UnitPresent $p "serde-1000000000000002")
}

Test-Case "an unhashed bin is kept by the live units it was built against, however old" {
    # MSVC: a path package's exe has no hash in its name, so no message names the
    # unit. The stale one is deliberately the NEWER of the two - built on another
    # branch's dependencies after the live one - so "newest" is the wrong answer.
    $p = New-TestProfileDir
    $ancient = $script:PruneNow.AddDays(-60)
    New-TestUnit $p "serde" "1000000000000001" "lib-serde" "a100000000000001" -Compiled $ancient -Artifacts @("libserde-1000000000000001.rlib")
    New-TestUnit $p "serde" "1000000000000002" "lib-serde" "a100000000000002" -SourcePath "499" -Compiled $ancient.AddDays(1) -Artifacts @("libserde-1000000000000002.rlib")
    New-TestUnit $p "delegator" "7000000000000001" "bin-delegator" "9100000000000001" -Deps @("a100000000000001") -Compiled $ancient
    New-TestUnit $p "delegator" "7000000000000002" "bin-delegator" "9100000000000002" -Deps @("a100000000000002") -Compiled $ancient.AddDays(1)
    $live = (Get-CargoLiveUnits @(
        (New-TestMessage $p -Filenames @("deps\libserde-1000000000000001.rlib") -TargetName "serde"),
        (New-TestMessage $p -Filenames @("delegator.exe", "delegator.pdb") -Kind "bin" -TargetName "delegator")
    ))[$p.ToLowerInvariant()]
    $summary = Invoke-CargoProfilePrune -ProfileDir $p -LiveUnits $live -LocalPackages @("delegator") -NowUtc $script:PruneNow
    Assert-Equal "pruned" $summary.Status $summary.Detail
    Assert-True (Test-UnitPresent $p "delegator-7000000000000001") "a fresh release bin must survive the retention window"
    Assert-False (Test-UnitPresent $p "delegator-7000000000000002")
    Assert-False (Test-UnitPresent $p "serde-1000000000000002")
}

Test-Case "a live unit whose edge does not resolve aborts the profile with nothing removed" {
    # Cargo validated a live unit's edges moments ago; a dangling one means the
    # layout is misread, and the reachability pass would delete live dependencies.
    $s = New-TestScenario
    $p = $s.ProfileDir
    New-TestUnit $p "delegator" "3000000000000001" "test-bin-delegator" "c100000000000001" -Deps @("a100000000000001", "0badbadbadbadbad")
    $summary = Invoke-TestPrune $s
    Assert-Equal "aborted" $summary.Status
    Assert-True (Test-UnitPresent $p "delegator-3000000000000002") "nothing may be removed after an abort"
}

Test-Case "a fingerprint it cannot read is kept, never guessed at" {
    $s = New-TestScenario
    $p = $s.ProfileDir
    $dir = Join-Path $p ".fingerprint\serde-1000000000000099"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $dir "lib-serde.json"), '{"rustc":')
    [System.IO.File]::WriteAllText((Join-Path $dir "lib-serde"), "a100000000000099")
    [System.IO.File]::WriteAllBytes((Join-Path $p "deps\libserde-1000000000000099.rlib"), (New-Object byte[] 16))
    $summary = Invoke-TestPrune $s
    Assert-Equal "pruned" $summary.Status $summary.Detail
    Assert-Equal 1 $summary.Unreadable
    Assert-True (Test-UnitPresent $p "serde-1000000000000099")
    Assert-True (Test-Path -LiteralPath (Join-Path $p "deps\libserde-1000000000000099.rlib"))
}

Test-Case "a profile Cargo is working in is skipped" {
    $s = New-TestScenario
    $p = $s.ProfileDir
    $held = [System.IO.File]::Open((Join-Path $p ".cargo-lock"), [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::ReadWrite)
    try {
        $held.Lock(0, [long]::MaxValue)
        $summary = Invoke-TestPrune $s
    } finally {
        $held.Dispose()
    }
    Assert-Equal "skipped" $summary.Status
    Assert-Match "Cargo is using it" $summary.Detail
    Assert-True (Test-UnitPresent $p "delegator-3000000000000002")
}

Test-Case "a dry run reports the plan and removes nothing" {
    $s = New-TestScenario
    $p = $s.ProfileDir
    $summary = Invoke-TestPrune $s -DryRun
    Assert-Equal "pruned" $summary.Status $summary.Detail
    Assert-Equal 6 $summary.RemovedUnits "3002, 1002, 2002, 4002, 6001, 1004"
    Assert-True ($summary.Bytes -gt 0)
    Assert-True (Test-UnitPresent $p "delegator-3000000000000002")
    Assert-True (Test-Path -LiteralPath (Join-Path $p "deps\delegator-3000000000000002.pdb"))
}

Test-Case "no recent build of the package means nothing is removed" {
    # Nothing to anchor reachability on: every unit would look unreachable.
    $p = New-TestProfileDir
    $long = $script:PruneNow.AddDays(-45)
    New-TestUnit $p "serde" "1000000000000001" "lib-serde" "a100000000000001" -Compiled $long
    New-TestUnit $p "delegator" "3000000000000001" "test-bin-delegator" "c100000000000001" -Deps @("a100000000000001") -Compiled $long
    $summary = Invoke-CargoProfilePrune -ProfileDir $p -LiveUnits $null -LocalPackages @("delegator") -NowUtc $script:PruneNow
    Assert-Equal "skipped" $summary.Status
    Assert-True (Test-UnitPresent $p "serde-1000000000000001")
    Assert-True (Test-UnitPresent $p "delegator-3000000000000001")
}

Test-Case "incremental sessions follow the unit that wrote them" {
    $s = New-TestScenario
    $p = $s.ProfileDir
    $liveCompiled = $script:PruneNow.AddHours(-1)
    New-TestSession $p "delegator-0aaaaaaaaaaaa" $liveCompiled.AddSeconds(6)
    New-TestSession $p "delegator-0bbbbbbbbbbbb" $script:PruneNow.AddDays(-3).AddSeconds(6)
    # A session at the live unit's time but of a crate no kept unit compiles.
    New-TestSession $p "build_script_build-0cccccccccccc" $liveCompiled.AddSeconds(6)
    New-Item -ItemType Directory -Force -Path (Join-Path $p "incremental\not-a-crate-dir!") | Out-Null
    $summary = Invoke-TestPrune $s
    Assert-Equal "pruned" $summary.Status $summary.Detail
    Assert-True (Test-Path -LiteralPath (Join-Path $p "incremental\delegator-0aaaaaaaaaaaa")) "the live test unit's session"
    Assert-False (Test-Path -LiteralPath (Join-Path $p "incremental\delegator-0bbbbbbbbbbbb")) "the previous version's session"
    Assert-False (Test-Path -LiteralPath (Join-Path $p "incremental\build_script_build-0cccccccccccc"))
    Assert-True (Test-Path -LiteralPath (Join-Path $p "incremental\not-a-crate-dir!")) "a name it does not recognise is left alone"
    Assert-Equal 2 $summary.RemovedIncremental
}

Test-Case "a long compile's session is matched by when it was finalized, not when it started" {
    # A debug test build of this crate once took 8 minutes on the spinning disk.
    # Without the lock file only the finalized session is left to match.
    $s = New-TestScenario
    $p = $s.ProfileDir
    $started = $script:PruneNow.AddHours(-1)
    New-TestUnit $p "delegator" "3000000000000001" "test-bin-delegator" "c100000000000001" -Deps @("a100000000000001", "b100000000000001") -Compiled $started -Written $started.AddMinutes(10)
    New-TestSession $p "delegator-0eeeeeeeeeeee" $started.AddMinutes(10).AddSeconds(-1) -NoLock
    Invoke-TestPrune $s | Out-Null
    Assert-True (Test-Path -LiteralPath (Join-Path $p "incremental\delegator-0eeeeeeeeeeee"))
}

Test-Case "a unit whose last compile failed keeps the session of its last success" {
    # rustc discards a failed session; the one left was finalized before the last
    # successful JSON write - here 40 minutes before, a long link on this disk -
    # and the start of that success was overwritten by the failed attempt.
    $s = New-TestScenario
    $p = $s.ProfileDir
    $success = $script:PruneNow.AddDays(-2)
    New-TestUnit $p "delegator" "4000000000000001" "bin-delegator" "d100000000000001" -ProfileHash "8" -Deps @("a100000000000001") -Compiled $script:PruneNow.AddMinutes(-30) -Written $success -Pending
    New-TestSession $p "delegator-0dddddddddddd" $success.AddMinutes(-40) -NoLock
    Invoke-TestPrune $s | Out-Null
    Assert-True (Test-UnitPresent $p "delegator-4000000000000001")
    Assert-True (Test-Path -LiteralPath (Join-Path $p "incremental\delegator-0dddddddddddd"))
}

Test-Case "a failed recompile still holds what its last success was built against" {
    # Cargo empties a unit's hash file before recompiling it and refills it only on
    # success. A rust-analyzer check that fails on a half-typed edit leaves exactly
    # that - and its check-mode dependencies are reachable through nothing else.
    $s = New-TestScenario
    $p = $s.ProfileDir
    New-TestUnit $p "delegator" "5000000000000001" "bin-delegator" "e100000000000001" -ProfileHash "6" -Deps @("a100000000000003") -Compiled $script:PruneNow.AddHours(-2) -Written $script:PruneNow.AddDays(-10) -Pending
    $summary = Invoke-TestPrune $s
    Assert-Equal "pruned" $summary.Status $summary.Detail
    Assert-True (Test-UnitPresent $p "delegator-5000000000000001")
    Assert-True (Test-UnitPresent $p "serde-1000000000000003") "the check-mode dependency tree must survive a failed check"
    Assert-True (Test-Path -LiteralPath (Join-Path $p "deps\libserde-1000000000000003.rmeta"))
}

Test-Case "a failed dependency recompile keeps the dependencies under it" {
    $s = New-TestScenario
    $p = $s.ProfileDir
    # tokio failed to rebuild three days ago - outside the one-day grace, inside the
    # retention window. Nothing kept points at it (its hash file is empty), but the
    # next attempt needs what its last success was built against.
    New-TestUnit $p "mio" "1000000000000011" "lib-mio" "a100000000000011" -ProfileHash "4" -SourcePath "611" -Compiled $script:PruneNow.AddDays(-12)
    New-TestUnit $p "tokio" "1000000000000012" "lib-tokio" "a100000000000012" -ProfileHash "4" -SourcePath "612" -Deps @("a100000000000011") -Compiled $script:PruneNow.AddDays(-3) -Written $script:PruneNow.AddDays(-12) -Pending
    Invoke-TestPrune $s | Out-Null
    Assert-True (Test-UnitPresent $p "tokio-1000000000000012")
    Assert-True (Test-UnitPresent $p "mio-1000000000000011")
}

Test-Case "a live set that names a unit mid-recompile aborts" {
    # Cargo just reported the test unit built, so an empty hash file means another
    # cargo got in between - or the layout is misread. Its edges still resolve, so
    # only this check stops the prune.
    $s = New-TestScenario
    $p = $s.ProfileDir
    New-TestUnit $p "delegator" "3000000000000001" "test-bin-delegator" "c100000000000001" -Deps @("a100000000000001", "b100000000000001") -Pending
    $summary = Invoke-TestPrune $s
    Assert-Equal "aborted" $summary.Status
    Assert-True (Test-UnitPresent $p "delegator-3000000000000002") "nothing may be removed after an abort"
}

Test-Case "anything compiled in the last day stays unless a live unit supersedes it" {
    # The dependencies of a check that failed before it ever succeeded: no JSON,
    # so no edge leads to them. A day bounds what that can leave behind.
    $s = New-TestScenario
    $p = $s.ProfileDir
    $hourAgo = $script:PruneNow.AddHours(-1)
    New-TestUnit $p "tokio" "1000000000000021" "lib-tokio" "a100000000000021" -ProfileHash "3" -SourcePath "612" -Compiled $hourAgo -Artifacts @("libtokio-1000000000000021.rmeta")
    # Same configuration as the live serde, built an hour ago against another graph: garbage.
    New-TestUnit $p "serde" "1000000000000022" "lib-serde" "a100000000000022" -ProfileHash "4" -Compiled $hourAgo -Artifacts @("libserde-1000000000000022.rlib")
    foreach ($unit in @(@{ Hash = "9000000000000001"; At = $hourAgo }, @{ Hash = "9000000000000002"; At = $script:PruneNow.AddDays(-3) })) {
        $dir = Join-Path $p ".fingerprint\delegator-$($unit.Hash)"
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $dir "invoked.timestamp"), "")
        [System.IO.File]::SetLastWriteTimeUtc((Join-Path $dir "invoked.timestamp"), $unit.At)
    }
    Invoke-TestPrune $s | Out-Null
    Assert-True (Test-UnitPresent $p "tokio-1000000000000021") "an unreached check dependency from the last hour"
    Assert-False (Test-UnitPresent $p "serde-1000000000000022") "a live unit supersedes it"
    Assert-True (Test-UnitPresent $p "delegator-9000000000000001") "a first check that failed an hour ago"
    Assert-False (Test-UnitPresent $p "delegator-9000000000000002") "one that failed three days ago"
}

Test-Case "artifacts with no fingerprint at all are removed, unhashed outputs never" {
    $s = New-TestScenario
    $p = $s.ProfileDir
    [System.IO.File]::WriteAllBytes((Join-Path $p "deps\libgone-8000000000000001.rlib"), (New-Object byte[] 16))
    New-Item -ItemType Directory -Force -Path (Join-Path $p "build\gone-8000000000000001\out") | Out-Null
    [System.IO.File]::WriteAllBytes((Join-Path $p "deps\delegator.exe"), (New-Object byte[] 16))
    $summary = Invoke-TestPrune $s
    Assert-False (Test-Path -LiteralPath (Join-Path $p "deps\libgone-8000000000000001.rlib"))
    Assert-False (Test-Path -LiteralPath (Join-Path $p "build\gone-8000000000000001"))
    Assert-True (Test-Path -LiteralPath (Join-Path $p "deps\delegator.exe")) "the MSVC bin is unhashed and belongs to whichever unit built it last"
    Assert-Equal 2 $summary.RemovedOrphans
}

Test-Case "the package name is read from [package], not from a dependency table" {
    $manifest = Join-Path $script:Sandbox "Cargo-test.toml"
    [System.IO.File]::WriteAllText($manifest, "[workspace]`r`n`r`n[dependencies.foo]`r`nname = `"not-this`"`r`n`r`n[package] # the crate`r`nname = `"delegator`"`r`nversion = `"0.8.4`"`r`n")
    Assert-Equal "delegator" (@(Get-CargoPackageName $manifest) -join ",")
    [System.IO.File]::WriteAllText($manifest, "[workspace]`r`nmembers = [`"a`"]`r`n")
    Assert-Equal 0 @(Get-CargoPackageName $manifest).Count
}

Test-Case "installers are left alone when the one to keep is not this build's" {
    # build-installer.ps1 names its installer on one line and Inno Setup on another
    # (I5). If they disagree, the file named here is an OLD installer, and "every
    # other one" would put the installer just built in the Recycle Bin.
    $dist = Join-Path $script:Sandbox ("dist-" + [Guid]::NewGuid().ToString("n").Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $dist | Out-Null
    foreach ($name in @("DelegatorSetup-0.9.0.exe", "DelegatorSetup-0.9.1.exe")) {
        [System.IO.File]::WriteAllText((Join-Path $dist $name), "")
    }
    $keep = Join-Path $dist "DelegatorSetup-0.9.0.exe"
    [System.IO.File]::SetLastWriteTimeUtc($keep, $script:PruneNow.AddHours(-3))
    $stale = Invoke-InstallerPrune -DistDir $dist -KeepInstaller $keep -BuiltAfterUtc $script:PruneNow.AddMinutes(-10) -DryRun
    Assert-Equal "skipped" $stale.Status
    Assert-Equal 0 @($stale.Moved).Count
    $fresh = Invoke-InstallerPrune -DistDir $dist -KeepInstaller $keep -BuiltAfterUtc $script:PruneNow.AddHours(-4) -DryRun
    Assert-Equal "pruned" $fresh.Status
    Assert-Equal "DelegatorSetup-0.9.1.exe" (@($fresh.Moved) -join ",")
    Assert-True (Test-Path -LiteralPath (Join-Path $dist "DelegatorSetup-0.9.1.exe")) "a dry run moves nothing"
}

Test-Case "the Recycle Bin check answers for a real file without throwing" {
    # What it answers depends on this machine's settings; that it answers does not.
    $file = Join-Path $script:Sandbox "recycle-probe.bin"
    [System.IO.File]::WriteAllText($file, "x")
    $refusal = Get-RecycleBinRefusal ([System.IO.FileInfo]$file)
    Assert-True ($null -eq $refusal -or $refusal -is [string])
}

Test-Case "stale installers are every installer but the one just built" {
    $dist = Join-Path $script:Sandbox ("dist-" + [Guid]::NewGuid().ToString("n").Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $dist | Out-Null
    foreach ($name in @("DelegatorSetup-0.8.2.exe", "DelegatorSetup-0.8.3.exe", "DelegatorSetup-0.8.4.exe", "DelegatorSetup-0.9.0.exe", "notes.txt")) {
        [System.IO.File]::WriteAllText((Join-Path $dist $name), "")
    }
    $stale = @(Get-StaleInstallers -DistDir $dist -KeepInstaller (Join-Path $dist "DelegatorSetup-0.9.0.exe") | ForEach-Object { $_.Name } | Sort-Object)
    Assert-Equal "DelegatorSetup-0.8.2.exe,DelegatorSetup-0.8.3.exe,DelegatorSetup-0.8.4.exe" ($stale -join ",")
    Assert-Equal 0 @(Get-StaleInstallers -DistDir (Join-Path $dist "missing") -KeepInstaller (Join-Path $dist "DelegatorSetup-0.9.0.exe")).Count
}
