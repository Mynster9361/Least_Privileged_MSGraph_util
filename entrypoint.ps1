param(
    [string]$tenantId,
    [string]$clientId,
    [string]$WorkspaceId,
    [int]$Days,
    [string]$DoCommit
)

$ErrorActionPreference = 'Stop'
$StateDir = ".lpm-audit"
$CliXmlPath = "$StateDir/state.clixml"
$JsonPath = "$StateDir/inventory.json"

Install-Module -Name LeastPrivilegedMSGraph -Force -AllowClobber -Scope CurrentUser > $null

Initialize-LogAnalyticsApi
Connect-EntraService -Federated -Service "LogAnalytics", "GraphBeta" -ClientID $clientId -TenantID $tenantId
"Connected to Entra ID and Log Analytics."
$Groups = Get-AppRoleAssignment
$Groups | Get-AppActivityData -WorkspaceId $WorkspaceId -Days $Days -ThrottleLimit 20 | Out-Null
$Groups | Get-AppThrottlingData -WorkspaceId $WorkspaceId -Days $Days | Out-Null
$CurrentData = $Groups | Get-PermissionAnalysis
"Analyzed $($CurrentData.Count) Service Principals."

$Summary = New-Object System.Text.StringBuilder
$Summary.AppendLine("## MS Graph Permission Audit")
$Summary.AppendLine("> Analysis timeframe: Last $Days days")

if (Test-Path $CliXmlPath) {
    $OldData = Import-Clixml $CliXmlPath
    $Summary.AppendLine("### Changes since last run")
    $Summary.AppendLine("<details><summary>Click to expand change details</summary>")
    $Summary.AppendLine("")

    $HasChanges = $false
    foreach ($App in $CurrentData) {
        $OldApp = $OldData | Where-Object { $_.PrincipalId -eq $App.PrincipalId }
        
        if (-not $OldApp) {
            $Summary.AppendLine("- **New App Detected:** $($App.PrincipalName) (`$($App.PrincipalId)`)")
            $HasChanges = $true
            continue
        }

        $CurrentPermStrings = @($App.CurrentPermissions.Permission | Where-Object { $_ })
        $OldPermStrings = @($OldApp.CurrentPermissions.Permission | Where-Object { $_ })

        $NewPerms = $CurrentPermStrings | Where-Object { $_ -notin $OldPermStrings }
        $RemovedPerms = $OldPermStrings | Where-Object { $_ -notin $CurrentPermStrings }

        if ($NewPerms -or $RemovedPerms) {
            $HasChanges = $true
            $Summary.AppendLine("#### $($App.PrincipalName)")
            if ($NewPerms) { $Summary.AppendLine("  - **Added:** ``$($NewPerms -join ', ')``") }
            if ($RemovedPerms) { $Summary.AppendLine("  - **Removed:** ``$($RemovedPerms -join ', ')``") }
        }
    }

    if (-not $HasChanges) { 
        $Summary.AppendLine("No permission changes detected since the last audit.") 
    }
    
    $Summary.AppendLine("")
    $Summary.AppendLine("</details>")
}
else {
    $Summary.AppendLine("### Baseline Established")
    $Summary.AppendLine("No previous state file found. This run has been saved as the new baseline.")
}

if ($DoCommit -eq "true") {
    if (!(Test-Path $StateDir)) { 
        New-Item -ItemType Directory $StateDir -Force | Out-Null 
    }

    $CurrentData | Export-Clixml -Path $CliXmlPath
    $CurrentData | Select-Object PrincipalId, PrincipalName, AppRoleCount, CurrentPermissions, ExcessPermissions, MatchedAllActivity | 
        ConvertTo-Json -Depth 10 | Out-File $JsonPath

    # Git Operations
    git config user.name "github-actions[bot]"
    git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

    git add "$StateDir/*"

    $status = git status --porcelain
    if ($status) {
        git commit -m "Automated MS Graph Audit update [skip ci]"
        git push
        "Changes successfully pushed to repository."
    }
    else {
        "No file changes detected, skipping git push."
    }
}

$Summary.ToString() | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append
"Job summary generated."