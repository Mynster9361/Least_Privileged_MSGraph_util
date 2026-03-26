param(
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
Connect-EntraService -AsAzAccount -Service "LogAnalytics", "GraphBeta"
"Connected to Entra ID and Log Analytics."
$Groups = Get-AppRoleAssignment
$Groups | Get-AppActivityData -WorkspaceId $WorkspaceId -Days $Days -ThrottleLimit 20 | Out-Null
$Groups | Get-AppThrottlingData -WorkspaceId $WorkspaceId -Days $Days | Out-Null
$CurrentData = $Groups | Get-PermissionAnalysis
"Analyzed $($CurrentData.Count) Service Principals."

$Summary = New-Object System.Text.StringBuilder
$Summary.AppendLine("## MS Graph Permission Audit")

if (Test-Path $CliXmlPath) {
    $OldData = Import-Clixml $CliXmlPath
    $Summary.AppendLine("### Changes since last run")
    
    $HasChanges = $false
    foreach ($App in $CurrentData) {
        $OldApp = $OldData | Where-Object { $_.PrincipalId -eq $App.PrincipalId }
        
        if (-not $OldApp) {
            $Summary.AppendLine("- **New App:** $($App.PrincipalName) (`$($App.PrincipalId)`)")
            $HasChanges = $true
            continue
        }

        # Compare Permissions
        $NewPerms = $App.CurrentPermissions | Where-Object { $_ -notin $OldApp.CurrentPermissions }
        $RemovedPerms = $OldApp.CurrentPermissions | Where-Object { $_ -notin $App.CurrentPermissions }

        if ($NewPerms -or $RemovedPerms) {
            $HasChanges = $true
            $Summary.AppendLine("#### $($App.PrincipalName)")
            if ($NewPerms) { $Summary.AppendLine("  - Added: ``$($NewPerms -join ', ')``") }
            if ($RemovedPerms) { $Summary.AppendLine("  - Removed: ``$($RemovedPerms -join ', ')``") }
        }
    }
    if (-not $HasChanges) { $Summary.AppendLine("No permission changes detected.") }
}
else {
    $Summary.AppendLine("Baseline established. No previous state found.")
}

if ($DoCommit -eq "true") {
    if (!(Test-Path $StateDir)) { New-Item -ItemType Directory $StateDir | Out-Null }

    $CurrentData | Export-Clixml -Path $CliXmlPath

    $CurrentData | Select-Object PrincipalId, PrincipalName, AppRoleCount, CurrentPermissions, ExcessPermissions, MatchedAllActivity | 
    ConvertTo-Json -Depth 10 | Out-File $JsonPath
}

$Summary.ToString() | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append
