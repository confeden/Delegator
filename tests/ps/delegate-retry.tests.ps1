# Exercise the dispatcher with failed providers and no model-rankings.json.
# The implicit strength floor must not pin an automatic request to one model.

Test-Case "automatic OpenCode failure tries another enabled model" {
    $Model = ""
    $script:RetryCalls = @()
    function Invoke-Delegate {
        param($ChosenBackend, $Text, $ChosenModel, $EffectiveComplexity)
        $script:RetryCalls += "$ChosenBackend/$ChosenModel"
        if ($ChosenModel -eq "opencode/a") {
            return [pscustomobject]@{ exitCode = 1; output = "All opencode models failed." }
        }
        return [pscustomobject]@{ exitCode = 0; output = "A useful answer." }
    }
    function Get-NextRankedModel { return "" }
    function Get-StrongEnabledModel {
        param([string[]]$Exclude)
        return @("opencode/a", "opencode/b", "opencode/c" | Where-Object { $Exclude -notcontains $_ } | Select-Object -First 1)
    }
    function Start-Sleep {}
    $result = Invoke-DelegateWithRetry -ChosenBackend "opencode" -Text "Solve the task" -ChosenModel "opencode/a"
    Assert-Equal 0 $result.exitCode
    Assert-Equal "opencode" $result.backend
    Assert-Equal "opencode/b" $result.model
    Assert-Equal "opencode/opencode/a,opencode/opencode/b" ($script:RetryCalls -join ",")
}

Test-Case "automatic retries are bounded and never revisit a failed model" {
    $Model = ""
    $script:RetryCalls = @()
    function Invoke-Delegate {
        param($ChosenBackend, $Text, $ChosenModel, $EffectiveComplexity)
        $script:RetryCalls += $ChosenModel
        return [pscustomobject]@{ exitCode = 1; output = "All opencode models failed." }
    }
    function Get-NextRankedModel { return "" }
    function Get-StrongEnabledModel {
        param([string[]]$Exclude)
        return @("opencode/a", "opencode/b", "opencode/c", "opencode/d" | Where-Object { $Exclude -notcontains $_ } | Select-Object -First 1)
    }
    function Start-Sleep {}
    $result = Invoke-DelegateWithRetry -ChosenBackend "opencode" -Text "Solve the task" -ChosenModel "opencode/a"
    Assert-Equal 1 $result.exitCode
    Assert-Equal "opencode/a,opencode/b,opencode/c" ($script:RetryCalls -join ",")
}

Test-Case "an explicit model is kept when its provider fails" {
    $Model = "opencode/a"
    $script:RetryCalls = @()
    function Invoke-Delegate {
        param($ChosenBackend, $Text, $ChosenModel, $EffectiveComplexity)
        $script:RetryCalls += $ChosenModel
        return [pscustomobject]@{ exitCode = 1; output = "All opencode models failed." }
    }
    function Get-NextRankedModel { return "opencode/b" }
    function Get-StrongEnabledModel { throw "Must honor the explicit model" }
    function Start-Sleep {}
    $result = Invoke-DelegateWithRetry -ChosenBackend "opencode" -Text "Solve the task" -ChosenModel "opencode/a"
    Assert-Equal 1 $result.exitCode
    Assert-Equal "opencode/a" ($script:RetryCalls -join ",")
}
