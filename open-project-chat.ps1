param(
    [string]$WorkspaceRoot,
    [string]$BaseUrl = "http://127.0.0.1:1380/",
    [switch]$PrintUrl
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
    $WorkspaceRoot = (Get-Location).Path
}

if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
    throw "WorkspaceRoot is required."
}

$builder = [System.UriBuilder]::new($BaseUrl)
$encodedWorkspaceRoot = [System.Uri]::EscapeDataString($WorkspaceRoot)
$builder.Query = "workspace_root=$encodedWorkspaceRoot&resume=1"
$url = $builder.Uri.AbsoluteUri

if ($PrintUrl) {
    Write-Output $url
    exit 0
}

Start-Process $url | Out-Null
