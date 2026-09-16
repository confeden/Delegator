<#
    opencode-delegate.ps1: user-added OpenAI-compatible providers (config v13)
    and the DPR lookup they depend on.

    Two things are guarded here.

    The ROUTING half: a provider owns the prefix of `<provider>/<model>`, the
    split is on the FIRST slash only (`tokenrouter/z-ai/glm-5.3-free` is one
    model of one provider), and a model whose prefix belongs to nobody must not
    silently fall through to the OpenCode CLI, which has never heard of it.

    The RATING half, which is the reason a b.ai key is not free to add: the
    ratings table is matched by longest substring, and `glm-5.3-flash` contains
    `glm-5.3`. Before the `unrated` rows were kept, the flash variant inherited
    150, landed in the DEEP tier and was handed exactly the work §13 says it
    must never get.
#>

# ── Get-CustomProviderForModel ────────────────────────────────────────────────
# The registry is injected instead of read: Get-DelegatorCustomProviders parses
# the owner's real config.json, and a test must never depend on which providers
# they happen to have configured today.
$script:DelegatorCustomProviders = @(
    [pscustomobject]@{
        id = "bai"
        label = "B.AI"
        baseUrl = "https://api.b.ai/v1"
        accounts = @([pscustomobject]@{ id = "a1"; label = "Ключ 1"; key = "sk-test" })
        models = @("hy3", "glm-5.3-flash")
    },
    [pscustomobject]@{
        id = "tokenrouter"
        label = "TokenRouter"
        baseUrl = "https://api.tokenrouter.com/v1"
        accounts = @([pscustomobject]@{ id = "a2"; label = "Ключ 2"; key = "sk-test-2" })
        models = @("z-ai/glm-5.3-free")
    }
)

Test-Case "a model id resolves to the provider that owns its prefix" {
    Assert-Equal "bai" (Get-CustomProviderForModel "bai/hy3").id
    Assert-Equal "tokenrouter" (Get-CustomProviderForModel "tokenrouter/z-ai/glm-5.3-free").id
}

Test-Case "the split is on the FIRST slash, so a slashed model id stays intact" {
    # The remainder is what the upstream is asked for verbatim: asking
    # TokenRouter for `glm-5.3-free` instead of `z-ai/glm-5.3-free` is a 404.
    $provider = Get-CustomProviderForModel "tokenrouter/z-ai/glm-5.3-free"
    Assert-Equal "z-ai/glm-5.3-free" "tokenrouter/z-ai/glm-5.3-free".Substring($provider.id.Length + 1)
}

Test-Case "an id belonging to no provider resolves to nothing" {
    # `opencode/*` and `openrouter/*` MUST fall through here: they have their own
    # execution paths, and capturing them would send Zen traffic to a third party.
    Assert-Null (Get-CustomProviderForModel "opencode/mimo-v2.5-free")
    Assert-Null (Get-CustomProviderForModel "openrouter/openrouter/free")
    Assert-Null (Get-CustomProviderForModel "gemini-3.7-flash")
    Assert-Null (Get-CustomProviderForModel "bai/")
    Assert-Null (Get-CustomProviderForModel "/hy3")
    Assert-Null (Get-CustomProviderForModel "")
}

Test-Case "the pool ids are prefixed, one per enabled model" {
    $ids = @(Get-CustomProviderModelIds)
    Assert-Equal 3 $ids.Count
    Assert-True ($ids -contains "bai/hy3")
    Assert-True ($ids -contains "bai/glm-5.3-flash")
    Assert-True ($ids -contains "tokenrouter/z-ai/glm-5.3-free")
}

# ── Invoke-OpenAICompatModel: the refusals that never touch the network ───────

Test-Case "no usable key is exit 2, a LOCAL problem and never a model verdict" {
    # Exit 2 is what keeps Test-AttemptIsModelFailure from demoting the model:
    # every model of a keyless provider fails identically, so recording it would
    # demote the whole provider at once, and health has no expiry (I21).
    $result = Invoke-OpenAICompatModel -Text "hi" -BaseUrl "https://api.b.ai/v1" -ModelId "hy3" -Accounts @() -Seconds 5
    Assert-Equal 2 $result.exitCode
    Assert-Match "API keys" $result.output
}

Test-Case "a provider with no base url is exit 2, not a request to nowhere" {
    $accounts = @([pscustomobject]@{ id = "a1"; label = "K"; key = "sk-test" })
    Assert-Equal 2 (Invoke-OpenAICompatModel -Text "hi" -BaseUrl "" -ModelId "hy3" -Accounts $accounts -Seconds 5).exitCode
    Assert-Equal 2 (Invoke-OpenAICompatModel -Text "hi" -BaseUrl "https://api.b.ai/v1" -ModelId "" -Accounts $accounts -Seconds 5).exitCode
}

Test-Case "a model outside every configured provider is exit 2" {
    $result = Invoke-CustomProviderModel -Text "hi" -OpenCodeModel "nosuch/model" -Seconds 5
    Assert-Equal 2 $result.exitCode
}

# ── The DPR lookup underneath ────────────────────────────────────────────────

Test-Case "an unrated row shadows the shorter rated row it contains" {
    # This is the whole reason the row exists. `glm-5.3` is measured at 150;
    # `glm-5.3-flash` is a different, much weaker model with no published index,
    # and the honest answer is "no number", not its sibling's.
    Assert-Equal 150 (Get-DelegatorModelRating "glm-5.3")
    Assert-Null (Get-DelegatorModelRating "glm-5.3-flash")
    Assert-Null (Get-DelegatorModelRating "bai/glm-5.3-flash")
}

Test-Case "an unrated model is normal tier, not deep and not zero" {
    # DelegateUnratedDpr keeps it reachable while §13 refuses to trust it with
    # hard work. 150 would have put it in the deep pool.
    Assert-Equal ([int]$script:DelegateUnratedDpr) (Get-ModelStrength "bai/glm-5.3-flash")
    Assert-True ((Get-ModelStrength "bai/glm-5.3-flash") -lt [int]$script:DelegateDprDeep)
}

Test-Case "a rated model still resolves through its own row" {
    # The shadowing fix must not cost the ordinary case: these are the other
    # three models a deposit-free b.ai key actually serves.
    Assert-Equal 118 (Get-ModelStrength "bai/hy3")
    Assert-Equal 110 (Get-ModelStrength "bai/mimo-v2.5")
    Assert-Equal ([int]$script:DelegateUnratedDpr) (Get-ModelStrength "bai/qwen3.8-flash")
}

# -- Provider verdicts: the file may only ever REMOVE a model ------------------
# The store is injected the same way the registry is; the real file belongs to
# the GUI's daily refresh and to the owner's own traffic.

Test-Case "no verdict file at all removes nothing" {
    $script:DelegatorProviderVerdicts = @{}
    Assert-False (Test-ModelRefusedByProvider "bai/hy3")
    Assert-False (Test-ModelRefusedByProvider "bai/anything")
    Assert-False (Test-ModelRefusedByProvider "")
}

Test-Case "only the provider's own refusal takes a model out" {
    # `free` is a confirmation, not a permission - the tick in the GUI is what
    # permits (I8). Everything else the provider said is a refusal.
    $script:DelegatorProviderVerdicts = @{
        "bai/hy3" = "free"
        "bai/glm-5.3" = "paid"
        "bai/withdrawn" = "absent"
    }
    Assert-False (Test-ModelRefusedByProvider "bai/hy3")
    Assert-True (Test-ModelRefusedByProvider "bai/glm-5.3")
    Assert-True (Test-ModelRefusedByProvider "bai/withdrawn")
    # A model nobody asked about stays in: silence is not a refusal.
    Assert-False (Test-ModelRefusedByProvider "bai/never-probed")
}
