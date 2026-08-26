<#
    Get-ImproveVerdict + Test-ShouldReaskVerdict (DEV_CONTRACTS section 8).

    Why these cases: on this machine `improve` recorded 32 `verdict-unparsable`
    outcomes out of 228 runs (14 %). Each one is a review call that was paid for
    and thrown away - the caller gets exit 3 "keep your draft" and cannot tell it
    apart from a draft that genuinely passed. Every case below is a shape a real
    reviewer answer took.
#>

Test-Case "clean minified JSON parses" {
    $obj = Get-ImproveVerdict '{"verdict":"ok","defects":[],"confidence":90}'
    Assert-NotNull $obj
    Assert-Equal "ok" $obj.verdict
    Assert-Equal "json" $obj.parseMode
}

Test-Case "fenced json block parses" {
    # Built from char 0x60, never typed: a backtick inside a double-quoted
    # PowerShell string is the escape character, and "```json" silently becomes
    # "`json" (I4 - a literal that is not what it looks like).
    $fence = ([char]0x60).ToString() * 3
    $raw = $fence + "json`n" + '{"verdict":"major","defects":[],"confidence":70}' + "`n" + $fence
    $obj = Get-ImproveVerdict $raw
    Assert-NotNull $obj
    Assert-Equal "major" $obj.verdict
}

Test-Case "prose before the object parses" {
    $obj = Get-ImproveVerdict "Here is my review:`n{`"verdict`":`"minor`",`"defects`":[]}"
    Assert-NotNull $obj
    Assert-Equal "minor" $obj.verdict
}

Test-Case "prose AFTER the object that contains braces still parses" {
    # LastIndexOf('}') swallowed the trailing sentence and ConvertFrom-Json threw.
    $raw = '{"verdict":"ok","defects":[]}' + "`nNote: an empty dict {} would also be valid."
    $obj = Get-ImproveVerdict $raw
    Assert-NotNull $obj
    Assert-Equal "ok" $obj.verdict
}

Test-Case "an example object before the real one does not break the parse" {
    $raw = 'Schema reminder: {"verdict":"...","defects":[]}' + "`n" +
        '{"verdict":"wrong","defects":[{"defect":"off by one","failingCase":"n=0 returns -1"}]}'
    $obj = Get-ImproveVerdict $raw
    Assert-NotNull $obj
    Assert-Equal "wrong" $obj.verdict
    Assert-Equal 1 @($obj.defects).Count
}

Test-Case "braces inside a string value do not end the object" {
    $raw = '{"verdict":"major","defects":[{"defect":"prints a literal {","failingCase":"input } yields {"}]}'
    $obj = Get-ImproveVerdict $raw
    Assert-NotNull $obj
    Assert-Equal "major" $obj.verdict
    Assert-Equal 1 @($obj.defects).Count
}

Test-Case "an escaped quote inside a string does not end the string" {
    $raw = '{"verdict":"minor","defects":[{"defect":"quotes \" badly","failingCase":"echo \"x\" -> }"}]}'
    $obj = Get-ImproveVerdict $raw
    Assert-NotNull $obj
    Assert-Equal "minor" $obj.verdict
    # parseMode is the point of the case: without it the assertion above also
    # passes when the SCANNER failed and the regex salvage happened to find the
    # same word - and salvage silently drops every defect.
    Assert-Equal "json" $obj.parseMode
    Assert-Equal 1 @($obj.defects).Count
}

Test-Case "an unpaired quote in the prose still yields the object, with its defects" {
    # The scanner reads every `"` as a JSON delimiter, so one stray quote in the
    # preamble leaves it inside a string for the rest of the text and it finds
    # NOTHING. The old whole-slice parse read this shape correctly, so falling
    # straight through to salvage would be a regression: a demonstrated defect
    # would silently become keep-major with defects=0.
    $raw = 'The draft prints 5" without escaping.' + "`n" +
        '{"verdict":"major","defects":[{"defect":"unescaped quote","failingCase":"input 5 inch"}]}'
    $obj = Get-ImproveVerdict $raw
    Assert-NotNull $obj
    Assert-Equal "major" $obj.verdict
    Assert-Equal "json" $obj.parseMode
    Assert-Equal 1 @($obj.defects).Count
}

Test-Case "an echoed schema is not salvaged into a verdict the reviewer never gave" {
    # The check prompt prints {"verdict":"ok|minor|major|wrong",...}. A reviewer
    # that echoes it and is then cut off leaves no parseable object, and a salvage
    # that matched the schema would report `ok` - suppressing the one re-ask built
    # for exactly this case and telling the caller its draft passed review.
    $raw = 'Using the schema {"verdict":"ok|minor|major|wrong","defects":[]}' + "`n" +
        'My review: {"verdict":"wrong","defects":[{"defect":"loop never terminates","failingCase":"n=0 hangs"'
    $obj = Get-ImproveVerdict $raw
    Assert-True (Test-ShouldReaskVerdict -RawText $raw -Parsed $obj) "a truncated review must still buy its one re-ask"
}

Test-Case "a lone truncated schema echo salvages to nothing at all" {
    $raw = 'The schema you gave me was {"verdict":"ok|minor|major|wrong","defects":['
    $obj = Get-ImproveVerdict $raw
    Assert-Null $obj
    Assert-True (Test-ShouldReaskVerdict -RawText $raw -Parsed $obj)
}

Test-Case "prose with no JSON at all returns null" {
    Assert-Null (Get-ImproveVerdict "The draft looks correct to me.")
}

Test-Case "empty input returns null" {
    Assert-Null (Get-ImproveVerdict "")
    Assert-Null (Get-ImproveVerdict "   ")
    Assert-Null (Get-ImproveVerdict $null)
}

Test-Case "a trailing comma is salvaged, and says so" {
    # PS 5.1 ConvertFrom-Json rejects it outright. The verdict word is still
    # unambiguous, and `ok`/`minor` there means KEEP - the cheapest correct answer.
    $obj = Get-ImproveVerdict '{"verdict":"ok","defects":[],}'
    Assert-NotNull $obj
    Assert-Equal "ok" $obj.verdict
    Assert-Equal "salvaged" $obj.parseMode
}

Test-Case "salvage keeps demonstrated defects out of a broken object" {
    # Salvage must never invent support for a rewrite: no parsed defects means
    # no defects, and Run-Improve then keeps the draft (section 11a).
    $obj = Get-ImproveVerdict "verdict: major, but the JSON never closed {"
    Assert-NotNull $obj
    Assert-Equal "major" $obj.verdict
    Assert-Equal "salvaged" $obj.parseMode
    Assert-Equal 0 @($obj.defects).Count
}

Test-Case "a verdict word in prose alone is NOT a verdict" {
    # "the draft is ok" must not become verdict=ok by accident; salvage needs the
    # reviewer to have named the field.
    Assert-Null (Get-ImproveVerdict "Honestly the draft is ok and I would ship it.")
}

Test-Case "an unknown verdict value is not salvaged into a valid one" {
    $obj = Get-ImproveVerdict '{"verdict":"perfect","defects":[]}'
    Assert-NotNull $obj
    Assert-Equal "perfect" $obj.verdict
}

# ── Test-ShouldReaskVerdict: when one bounded re-ask is worth its cost ──

Test-Case "re-ask when the reviewer answered but nothing parsed" {
    Assert-True (Test-ShouldReaskVerdict -RawText "I think the draft is fine, honestly." -Parsed $null)
}

Test-Case "no re-ask when the reviewer said nothing at all" {
    # Empty output is a backend failure, not a formatting failure: a second call
    # to the same silent model buys nothing.
    Assert-False (Test-ShouldReaskVerdict -RawText "" -Parsed $null)
    Assert-False (Test-ShouldReaskVerdict -RawText "   " -Parsed $null)
}

Test-Case "no re-ask once a usable verdict exists" {
    $obj = Get-ImproveVerdict '{"verdict":"ok","defects":[]}'
    Assert-False (Test-ShouldReaskVerdict -RawText "irrelevant" -Parsed $obj)
}

Test-Case "re-ask when the object parsed but the verdict is not one of the four" {
    $obj = Get-ImproveVerdict '{"verdict":"perfect","defects":[]}'
    Assert-True (Test-ShouldReaskVerdict -RawText "some text" -Parsed $obj)
}

Test-Case "a salvaged verdict is good enough - never pay for a second call" {
    $obj = Get-ImproveVerdict '{"verdict":"ok","defects":[],}'
    Assert-False (Test-ShouldReaskVerdict -RawText "some text" -Parsed $obj)
}
