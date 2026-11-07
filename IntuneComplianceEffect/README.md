# Get-DevicesWithoutCompliancePolicy

A PowerShell script that shows, device by device, what **device compliance** means for
**Conditional Access**. It finds the devices that have no compliance policy, collects the
Conditional Access policies that relate to devices or compliance, and works out for each device
whether it is blocked, has access only because of a tenant setting, or gets through everything
unnoticed. The result is an interactive HTML report.

> **Why this matters:** when `secureByDefault` is `false`, Intune marks devices without a
> compliance policy as **compliant**. Those devices therefore pass every Conditional Access policy
> that requires "Require device to be marked as compliant". This script makes those devices visible.

---

## What it does

| Step | What | Graph endpoint (beta) |
|---|---|---|
| 1 | Reads the tenant setting `secureByDefault` | `GET /deviceManagement/settings` |
| 2 | Runs the *DevicesWithoutCompliancePolicyV3* report, waits until it is ready, then downloads and unzips the result | `POST /deviceManagement/reports/exportJobs` |
| 3 | Fetches all Conditional Access policies and selects the ones related to devices or compliance | `GET /identity/conditionalAccess/policies` |
| 4 | Checks each device (user, groups, roles, platform) against the policies that block | `GET /users/{id}/transitiveMemberOf` |
| 5 | Writes an HTML report, plus CSV files if you ask for them | `GET /organization` (tenant name) |

### Outcome per device

| Category | Meaning |
|---|---|
| 🔴 **Blocked** | Not compliant, and an enforced CA policy blocks access |
| 🟠 **AtRisk** | Compliant only because `secureByDefault = false`; it is blocked as soon as that setting is turned on |
| 🟣 **Unprotected** | Not compliant, but no enforced policy blocks this user or platform |
| 🟡 **ReportOnly** | Would be blocked, but the policy is in report-only mode |
| ⚪ **CompliantByDefault** | Compliant by default, but no policy would block it anyway |
| 🟢 **Compliant** | Meets the compliance requirement |
| ⚪ **NoUser** | Device without a user; check user-targeted policies manually |

### Effect per CA policy

| Colour | Meaning |
|---|---|
| 🔴 | Blocks non-compliant devices (compliantDevice with AND or as the only control, or a device filter with block) |
| 🟠 | Compliance is required, but with **OR** the user can get through another way, e.g. MFA, an authentication strength or hybrid join |
| 🟡 | Device filter on compliance that cannot be evaluated automatically: review manually |
| 🔵 | Device related (platform, hybrid join, app protection, filter), but compliance does not decide the outcome |
| ⚪ | Policy is disabled |

A policy is included when it contains any of the following: grant `compliantDevice`,
`domainJoinedDevice`, `approvedApplication` or `compliantApplication`, a device filter,
device states (legacy) or a platform condition. The **Why included** column says which.

---

## Requirements

- PowerShell 7+ (Windows PowerShell 5.1 also works)
- The `Microsoft.Graph.Authentication` module (for interactive sign-in only):
  ```powershell
  Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
  ```
- Graph permissions (delegated or application):

| Permission | Used for |
|---|---|
| `DeviceManagementServiceConfig.Read.All` | `deviceManagement/settings` |
| `DeviceManagementManagedDevices.Read.All` | Report export |
| `DeviceManagementConfiguration.Read.All` | Report export |
| `Policy.Read.All` | Conditional Access policies |
| `Directory.Read.All` | Group and role membership, tenant name |

For interactive sign-in, the *Microsoft Graph Command Line Tools* app must have been granted
these scopes (admin consent) in the tenant you sign in to.

---

## Usage

```powershell
# Interactive, in a specific tenant
.\Get-DevicesWithoutCompliancePolicy.ps1 -TenantId contoso.onmicrosoft.com

# Interactive, with the account picker (you land in the chosen account's home tenant)
.\Get-DevicesWithoutCompliancePolicy.ps1

# With an existing access token, no sign-in
.\Get-DevicesWithoutCompliancePolicy.ps1 -AccessToken $token

# Report plus CSV exports
.\Get-DevicesWithoutCompliancePolicy.ps1 -TenantId contoso.onmicrosoft.com `
    -HtmlReportPath .\report.html -OutputPath .\devices.csv -PolicyOutputPath .\ca-policies.csv

# Only the devices that currently have access just because of the default
.\Get-DevicesWithoutCompliancePolicy.ps1 -TenantId contoso.onmicrosoft.com |
    Where-Object CAOutcomeCategory -eq 'AtRisk'
```

### Parameters

| Parameter | Description |
|---|---|
| `-TenantId` | Tenant for the interactive sign-in (ID or domain) |
| `-AccessToken` | Bearer token; skips the interactive sign-in |
| `-UseExistingSession` | Reuse the current `Connect-MgGraph` session. By default it is disconnected first, so you never work in the wrong tenant |
| `-HtmlReportPath` | Path for the HTML report (default `ComplianceImpactReport_<datetime>.html`) |
| `-NoHtmlReport` | Don't create the HTML report |
| `-OutputPath` | CSV with the devices and their outcome |
| `-PolicyOutputPath` | CSV with the CA overview |
| `-SkipDeviceEvaluation` | Skip the per-device evaluation (saves one Graph call per user) |
| `-PollIntervalSeconds` | Time between status checks of the export (default 5) |
| `-TimeoutMinutes` | Maximum wait for the export (default 10) |
| `-KeepDownload` | Keep the downloaded zip and the JSON |

---

## The HTML report

- Header with tenant name, date and a banner showing the `secureByDefault` status
- Clickable tiles per category that filter the device table
- Search box across devices, users and policies
- Device table: device, user, OS, ownership, compliance state, last contact, effect, blocking policies
- Policy table with *Why included*, state, grant controls (AND/OR), scope, platforms and effect
- A single file with no external dependencies, and it prints cleanly

---

## Limitations

- The per-device evaluation looks at **users, groups, roles and platform**. App, location,
  sign-in risk and client app conditions are not evaluated; they do appear in the policy overview.
- Device filters on compliance are only evaluated automatically for the standard patterns
  (`device.isCompliant -eq True/False` with include or exclude). Everything else is marked "Review manually".
- Guest and external user targeting is not evaluated.
- The script uses Microsoft Graph beta endpoints, which can change.

---

## The prompt

This script was built with AI. The prompt below rebuilds it in one go. For a demo, it works well
to give the chapters one at a time (1+2, then 3, then 4+5), so the audience sees the script grow.

````markdown
# Task
Write a PowerShell script `Get-DevicesWithoutCompliancePolicy.ps1` that shows, per device,
the effect of device compliance on Conditional Access, and delivers the result as an HTML report.

# Sign-in
- Interactive via `Connect-MgGraph` (module Microsoft.Graph.Authentication).
- Parameter `-TenantId` (ID or domain) to choose the tenant.
- Always run `Disconnect-MgGraph` first, so you never end up in the wrong tenant by accident.
  `-UseExistingSession` to reuse an existing session.
- `-ContextScope Process`.
- Optional `-AccessToken`: then no interactive sign-in, but `Invoke-RestMethod` with a Bearer header.
- After sign-in, show the account and tenant, and warn if any scopes are missing.
- Scopes: DeviceManagementServiceConfig.Read.All, DeviceManagementManagedDevices.Read.All,
  DeviceManagementConfiguration.Read.All, Policy.Read.All, Directory.Read.All
- Use the beta endpoints and support paging via `@odata.nextLink`.

# Chapter 1: Secure by default
- GET `/beta/deviceManagement/settings`, read `secureByDefault`.
- `false` means: devices without a compliance policy count as **compliant**. Show a warning.

# Chapter 2: Devices without a compliance policy
- POST `/beta/deviceManagement/reports/exportJobs` with:
  `{ "reportName": "DevicesWithoutCompliancePolicyV3", "localizationType": "LocalizedValuesAsAdditionalColumn", "format": "json" }`
- Poll `exportJobs('{id}')` until `status = completed`. Stop with an error on `failed` or after a timeout
  (parameters `-PollIntervalSeconds` and `-TimeoutMinutes`).
- Download the zip from `url` with `Invoke-WebRequest`, **without** an auth header (it is a SAS URL).
- Unzip into a temporary folder and read the JSON (`columns` + `values`).
  Clean up the folder afterwards, unless `-KeepDownload` is given.
- Flag `CompliantByDefault` per device: compliant only because `secureByDefault = false`
  (ComplianceState "1" = Compliant).

# Chapter 3: Conditional Access policies
- GET `/beta/identity/conditionalAccess/policies`.
- Include every policy that relates to devices or compliance, with a **"Why included"** column:
  grant compliantDevice / domainJoinedDevice / approvedApplication / compliantApplication,
  a device filter, device states (legacy) or a platform condition.
- Determine per policy the **effect on a non-compliant device**:
  - compliantDevice with AND, or as the only control → access denied
  - compliantDevice with **OR** and an alternative (MFA, authentication strength, terms of use,
    hybrid join) → **not blocked**, because the user can get through another way
  - device filter on `device.isCompliant` + block → recognise the standard patterns, mark the rest "Review manually"
  - device related but no compliance effect → describe what the policy does instead
  - report-only and disabled policies get a label, because they block nothing
- Also show: state, operator, scope (users/groups/roles incl. excludes), apps, platforms, client app types.

# Chapter 4: Effect per device
- Fetch each user's groups and roles via `/users/{id}/transitiveMemberOf` (cached).
- Check every blocking policy against the includes/excludes (users, groups, role template IDs) and the platform.
- Give every device one category and a plain-language explanation:
  - Blocked
  - AtRisk (compliant only by default; blocked as soon as secureByDefault is turned on)
  - Unprotected (not compliant, but not blocked anywhere)
  - ReportOnly
  - CompliantByDefault
  - Compliant
  - NoUser
- State that app, location, risk and client app conditions are not evaluated.

# Chapter 5: HTML report
- A single HTML file with no external dependencies (`-HtmlReportPath`, default with a timestamp; `-NoHtmlReport` to skip).
- Header with tenant name (`/organization`), date and a banner with the secureByDefault status.
- Clickable tiles per category (red/orange/purple/yellow/green/grey) that filter the device table, plus a search box.
- Device table: device, user, OS, ownership, compliance state, last contact, effect badge, blocking policies.
- Policy table with tags for "Why included" and a coloured dot for the effect, with a legend.
- HTML-encode all values. Print-friendly.

# Output and quality
- Optional CSV via `-OutputPath` (devices) and `-PolicyOutputPath` (policies). Devices are also sent to the pipeline.
- Full comment-based help: synopsis, parameters, required permissions, examples.
- ASCII only in the script (Windows PowerShell 5.1 reads a file without a BOM as ANSI).
- Use `${var}:` in strings where a colon directly follows a variable.
- `$ErrorActionPreference = 'Stop'` and clear error messages.
````
