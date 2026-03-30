# LeastPrivilegedMSGraph Audit Action

> **Audit Microsoft Graph permissions against real usage** — automatically, on a schedule, with full Git history and change-detection between runs.

---

## How it works

Each run of this action performs a deep-dive security audit of your Entra ID tenant:

1.  **Inventory:** Collects every service principal and its assigned Graph permissions via `Get-AppRoleAssignment`.
2.  **Enrichment:** Pulls real activity telemetry from your Azure Log Analytics workspace (`Get-AppActivityData`) to see what permissions are actually being used.
3.  **Throtling data:** Pulls activity metrics for throttling for the applications `Get-AppThrottlingData` 
4.  **Analysis:** Identifies "Excess Permissions"—API scopes that are assigned but haven't been touched in weeks (`Get-PermissionAnalysis`).
5.  **Diffing:** Compares the results against the previous run's state to surface newly added apps or modified permissions.
6.  **Reporting:** Writes a clean Markdown table to the GitHub Step Summary.
7.  **Persistence:** Commits the updated `inventory.json` and `state.clixml` back to your repository so every change is tracked in your Git history.

---

## Prerequisites

### 1. Configure OIDC (Federated credentials so no secrets) 
This action uses **Workload Identity Federation**. You never need to store a Client Secret in GitHub.

1.  **Create an App Registration** in Entra ID (e.g., `GitHub-LPM-Auditor`).
2.  **Add a Federated Identity Credential**:
    * **Issuer**: `https://token.actions.githubusercontent.com`
    * **Subject Identifier**: `repo:<ORG>/<REPO>:ref:refs/heads/main` (Adjust for your branch).
    * **Audience**: `api://AzureADTokenExchange`

### 2. Assign Required Permissions
The Auditor app needs the following access:

| Provider            | Permission                               | Why                                              |
| :------------------ | :--------------------------------------- | :----------------------------------------------- |
| **Microsoft Graph** | `Application.Read.All`                   | To read service principals and their roles.      |
| **Microsoft Graph** | `Directory.Read.All`                   | To read /oauth2PermissionGrants and their roles. If you do not care about delegated permissions change the permissionType parameter to "Application" |
| **Azure IAM**       | `Log Analytics Reader` (RBAC permission) | To query the `MicrosoftGraphActivityLogs` table. |

---

## Usage

### Minimal Workflow
Create a file at `.github/workflows/` give it a name like `lpm-audit.yml`:

```yaml
name: "LPM Permission Audit"

on:
  schedule:
    - cron: "0 6 * * 1"  # Every Monday at 06:00 UTC
  workflow_dispatch:     # Allow manual runs

permissions:
  id-token: write      # Required for OIDC
  contents: write      # Required to commit state files

jobs:
  audit:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout Code
        uses: actions/checkout@v6
        with:
          fetch-depth: 0

      - name: Run LeastPrivilegedMSGraph Audit
        uses: Mynster9361/Least_Privileged_MSGraph@latest
        with:
          tenantId: ${{ secrets.AZURE_TENANT_ID }}
          clientId: ${{ secrets.AZURE_CLIENT_ID }}
          logAnalyticsWorkspaceId: ${{ secrets.LOG_ANALYTICS_WORKSPACE_ID }}
          daysToQuery: 7
          enableGitCommit: true
```

## Understanding the Outputs

After a successful run, the action updates/creates the `.lpm-audit/` folder in your repository:

* **`inventory.json`**: A human-readable snapshot. This is the best way to track history; simply click on the file in GitHub to see the "Diff" between the current and previous audit.
* **`state.clixml`**: A full-fidelity PowerShell serialization used by the action's logic to remember objects between runs. 
* >NOTE: This clixml can also be imported into powershell and create a report by doing something like this:
  ```powershell
  Import-module LeastPrivilegedMSGraph
  $appData = import-clixml -Path .\.lpm-audit\state.clixml
  $appData | Export-PermissionAnalysisReport
  ```
* **Step Summary**: Check the **Summary** tab of your GitHub Action run to see a high-level table of **Added** vs **Removed** permissions without leaving the browser.
