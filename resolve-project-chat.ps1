param(
    [string]$WorkspaceRoot,
    [string]$BaseUrl = "http://127.0.0.1:1380"
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
    $WorkspaceRoot = (Get-Location).Path
}

if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
    throw "WorkspaceRoot is required."
}

$encodedWorkspaceRoot = [System.Uri]::EscapeDataString($WorkspaceRoot)
$uri = "$BaseUrl/api/workspaces/preferred?workspace_root=$encodedWorkspaceRoot"
Invoke-RestMethod -Uri $uri -Method Get | ConvertTo-Json -Depth 6
