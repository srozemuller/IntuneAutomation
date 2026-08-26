# Intune Compliance Policy Coverage Analyzer

Explains **why** an Intune-managed Windows device does or does not have a
compliance policy assigned - an RSOP-style, evidence-based analysis, not a
Graph data dump.

## Why this exists

If your tenant has **"Mark devices with no compliance policy assigned as
Not compliant"** enabled, devices that fall outside every compliance
policy's assignment become noncompliant under a synthetic
`Default Device Compliance Policy` / `Has a compliance policy assigned`
rule. Intune can show you *which* devices have no compliance policy, but
not *why*. This tool reconstructs the expected assignment for a device -
which policies could target it, which assignment (include/exclude) was
evaluated, whether the device or its associated user matched, whether a
group exclusion or assignment filter matched - and states a final,
explained result.

**This script is strictly read-only.** Every Graph call is a `GET`, or a
`POST` that only reads (`checkMemberGroups`, the compliance-report export
job). It never creates, updates, or deletes an Intune policy, Entra group,
assignment, filter, or device.

## Prerequisites

- PowerShell 7+
- `Microsoft.Graph.Authentication` module
- An existing `Connect-MgGraph` session (or run with `-Connect` to have the
  script establish one with the scopes below)
- `Pester` 5.x to run the tests

## Required Microsoft Graph permissions

Least-privileged, verified against current Graph documentation (not
guessed):

| Permission | Why |
| --- | --- |
| `DeviceManagementManagedDevices.Read.All` | Read the managed device and the devices-without-compliance-policy report |
| `DeviceManagementConfiguration.Read.All` | Read compliance policies, their assignments, and assignment filters |
| `Device.Read.All` | Resolve the Entra device object and check its group membership (`checkMemberGroups`) |
| `User.ReadBasic.All` + `GroupMember.Read.All` | Check the device's associated user's group membership for *other users* (the least-privileged pair Graph documents for this scenario - `Directory.Read.All` also works but is broader than needed) |

**Optional, for auto-resolving duplicate Entra device objects:** `User.Read.All`
(or `Directory.Read.All`) additionally lets `Get-EntraDeviceContext` cross-check
`/users/{id}/registeredDevices` when a device's `deviceId` matches more than one
Entra device object (see "Duplicate Entra device objects" below). This is
strictly additive - without it, that cross-check fails and is caught
gracefully, falling back to the same `Ambiguous` behavior as before; nothing
else in the script is affected. Note this specific call is **delegated-only**
per Microsoft Graph's own documentation (Application permissions aren't
supported for it), so it never works under an app-only/managed-identity
`-AccessToken` session regardless of granted permissions - that's expected,
not a bug.

**Known limitation:** evaluating membership in a group with **hidden
membership** additionally requires the `Member.Read.Hidden` application
permission (or, for delegated auth, that the signed-in user is a member of
that group). Without it, Graph silently omits those group ids from the
`checkMemberGroups` response rather than erroring - this tool cannot always
detect that omission, so a hidden-membership group used in an assignment
you're troubleshooting is a real, documented blind spot. If in doubt,
Unknown results are the correct place to start looking.

## Usage

### Mode 1 - troubleshoot one device

```powershell
.\Test-IntuneCompliancePolicyCoverage.ps1 -ManagedDeviceId "1b2c3d4e-5f6a-7b8c-9d0e-1f2a3b4c5d6e"
```

```powershell
.\Test-IntuneCompliancePolicyCoverage.ps1 -DeviceName "WIN11-001"
```

If more than one device shares that name, the script reports an explicit
ambiguity error listing the candidates and stops - it never silently picks
one.

### Mode 2 - analyze every device Intune reports as having no compliance policy

```powershell
.\Test-IntuneCompliancePolicyCoverage.ps1 -AllDevicesWithoutCompliancePolicy
```

The devices-without-compliance-policy report spans **every** platform, not
just Windows (Windows, iOS/iPadOS, Android, macOS...). This script triages
on the report row's own OS column *before* spending a Graph call resolving
each device, so non-Windows rows never cost a wasted `managedDevice` fetch.
They are never silently dropped, though - every skipped row is counted by
platform and shown as its own breakdown, both on the console and (if
`-ExportHtml` is used) in the report:

```
Other platforms in this report (not evaluated - Windows only in this version):
   4  iOS/iPadOS
   2  macOS
   1  Android
```

### Reusing a report export you already have

If you already ran the `DevicesWithoutCompliancePolicyV3` export yourself
(or kept one from a prior run), skip a new export job and analyze it
directly:

```powershell
.\Test-IntuneCompliancePolicyCoverage.ps1 -AllDevicesWithoutCompliancePolicy `
    -ReportJsonPath ".\DevicesWithoutCompliancePolicyV3_....json" -ExportHtml
```

This only replaces the "which devices lack a policy" input - live Graph
calls are still made to actually evaluate policies, assignments, group
membership, and filters per device, since the report itself only lists
devices, never *why* each one is missing a policy. `ConvertFrom-IntuneReportPayload`
(used internally, and exported for scripting) accepts every export shape
observed in practice: a bare array of row objects, a `Schema`/`Values`
matrix, or a `columns`/`values` envelope (the latter is what a real
`DevicesWithoutCompliancePolicyV3` export currently uses - `values` is
already an array of flat row objects there, not column-ordered arrays).

### Exporting results

```powershell
.\Test-IntuneCompliancePolicyCoverage.ps1 -AllDevicesWithoutCompliancePolicy -ExportJson -ExportCsv -ExportHtml -OutputPath C:\Reports
```

Export is optional; console output is useful on its own. `-ExportHtml`
writes a single self-contained HTML file (no external CSS/JS) with a
summary stat grid, the non-Windows platform breakdown in bulk mode, and one
collapsible section per device listing that device's hardware/enrollment
info (manufacturer, model, OS version, ownership, compliance state,
management agent, enrollment profile, last check-in - all already
retrieved, no extra Graph calls), the shared-device advisory when
relevant, and each policy's result and evidence. The console output shows
the same device info and advisory inline above the per-policy results.

### First-time connection

```powershell
.\Test-IntuneCompliancePolicyCoverage.ps1 -DeviceName "WIN11-001" -Connect
```

Without `-Connect`, the script checks `Get-MgContext` and stops with the
exact `Connect-MgGraph -Scopes ...` command to run if there's no session -
it never starts interactive sign-in on its own.

### Unattended automation with a pre-acquired access token

For a scheduled task, Azure Automation runbook, or Function where a token
was already acquired out-of-band (app-only/client-credentials, managed
identity, or a delegated token), pass it directly instead of relying on an
interactive session:

```powershell
$secureToken = ConvertTo-SecureString $env:GRAPH_TOKEN -AsPlainText -Force
.\Test-IntuneCompliancePolicyCoverage.ps1 -AccessToken $secureToken `
    -AllDevicesWithoutCompliancePolicy -ExportHtml -OutputPath 'C:\Reports'
```

`-AccessToken` calls `Connect-MgGraph -AccessToken` under the hood, so
`Invoke-MgGraphRequest` (and therefore every retrieval/retry/paging
function in this module) keeps working unchanged - there is no separate,
parallel HTTP path for token auth. The token must already carry the
permissions listed above; this script never requests consent or acquires a
token itself. Because app-only/managed-identity sessions don't always
expose a `Scopes` list the way an interactive one does, the scope-presence
warning is skipped for token-based sessions - a `403` on the first real
call is the reliable signal there instead.

## How the analysis works

```
Devices without a compliance policy (or a single named device)
        |
Get managed device -> determine platform (Windows only in v1)
        |  (userId placeholder handling: Intune uses the all-zero GUID for
        |   "no user" - misreading that as a real user id would break every
        |   downstream user-side group check, so it's normalized to
        |   UserContext = None here, before anything else runs)
        |
Resolve the Entra device object (/devices?$filter=deviceId eq '...')
        |  (managedDevice.azureADDeviceId is the Entra deviceId, NOT the
        |   directory object id checkMemberGroups needs - this resolution
        |   step exists specifically to keep those two ids from being
        |   conflated. If more than one Entra device object shares that
        |   deviceId - a common stale-object artifact - the device's own
        |   primary user's registeredDevices is cross-checked to try to
        |   resolve it with evidence before falling back to Ambiguous.)
        |
Get Windows compliance policies + assignments + assignment filters
Resolve display names for every assignment group, once for the whole run
        |
Collect every unique group id referenced by any assignment, once per device
        |
checkMemberGroups for the device and (if any) its user, chunked to <=20
group ids per request. A failed chunk is retried one id at a time so one
bad/stale group id can't poison every other group in the same batch.
        |
Evaluate each assignment independently: target match -> exclusion check
-> filter evaluation -> assignment-level result
        |
Roll all of one policy's assignment results into one policy-level result
        |
Print an RSOP-style explanation per policy (device hardware/enrollment
info, a shared-device advisory when relevant, group names not just ids,
and a WHY line)
```

### Result states

| Result | Meaning |
| --- | --- |
| `ShouldApply` | A valid assignment targets the device, no exclusion applies, and any filter permits it. |
| `ShouldApplyButMissing` | Same as `ShouldApply`, but the device came from the "devices without compliance policy" report - i.e. Intune isn't applying a policy that, by this analysis, it should be. Stop looking at groups/filters and check device check-in, enrollment/identity state, or recent assignment changes instead. |
| `NotTargeted` | Neither the device nor its associated user is a member of any assigned group, and no `All Devices`/`All Users` assignment applies. |
| `Excluded` | An assignment matched, but a proven exclusion group membership overrides it. |
| `FilteredOut` | An assignment matched, but its assignment filter does not permit the device. |
| `Unknown` | Something needed to reach a verdict could not be proven - a `checkMemberGroups` call failed, an assignment target type isn't recognized, or a filter uses unsupported syntax/properties. **This is never silently downgraded to `NotTargeted`, `Excluded`, or `FilteredOut`.** When the specific cause is diagnosable, the badge/headline says so instead of a bare "Unknown" - currently only for a still-ambiguous Entra device object (`Unknown - Ambiguous Entra Device Object`), shown when *every* Unknown assignment on that policy (or, in the bulk summary, every Unknown policy on that device) traces back to that one cause. `Result` itself is still plain `Unknown` underneath; this is a presentation-layer detail, not a new confident answer. |

One matched include assignment always wins over other, independently
failed/unknown assignments on the same policy - a `FilteredOut` or
`Unknown` assignment never masks a real match from another assignment on
the same policy.

### Userless (shared/kiosk) device advisory

When a device has no primary user *and* doesn't currently have a
compliance policy applying, the console and HTML output both print an
explicit advisory: a user-group-based assignment can never match a device
with no associated user, so if this is intentionally a shared device, it
needs to be covered by a group containing the device itself (or "All
Devices"), not a user group. This is advice only, printed alongside the
normal evidence-based result - it never changes what `Result` is reported
as, since "this is probably a shared device" is a suggestion for a human,
not something the tool can prove.

## Supported assignment targets

- `#microsoft.graph.allDevicesAssignmentTarget`
- `#microsoft.graph.allLicensedUsersAssignmentTarget`
- `#microsoft.graph.groupAssignmentTarget`
- `#microsoft.graph.exclusionGroupAssignmentTarget`

A `groupAssignmentTarget` is evaluated against **both** the device's own
group membership and its associated user's group membership - Intune
groups aren't inherently "device groups" or "user groups," so both are
checked and the evidence records which one (`MatchedVia: Device` or
`MatchedVia: User`) produced the match.

Any other/future target type produces `Unknown` with
`Reason = "Unsupported assignment target type: <odata type>"` - it is never
silently ignored.

## Supported assignment filter syntax

Grammar and property list verified against Microsoft's [assignment filter
properties and operators
reference](https://learn.microsoft.com/en-us/intune/fundamentals/filters/ref-device-properties)
rather than guessed.

Form: `(entity.property operator value)`, combined with `and`/`or` and
parentheses (mixed `and`/`or` without full parenthesization is evaluated
left-to-right rather than applying and-before-or precedence - fully
parenthesize mixed rules for guaranteed-correct evaluation).

Operators: `-eq`, `-ne`, `-contains`, `-notContains`, `-startsWith`, `-in`,
`-notIn`, `-and`/`and`, `-or`/`or` (the leading dash is optional, per the
Intune rule syntax editor).

Properties supported in v1 (all reliably mappable to fields this script
already retrieves on `managedDevice`):

| Filter property | Mapped from |
| --- | --- |
| `device.deviceOwnership` | `managedDeviceOwnerType` (`company`/`personal`/`unknown` normalized to `Corporate`/`Personal`/`Unknown`) |
| `device.manufacturer` | `manufacturer` |
| `device.model` | `model` |
| `device.osVersion` | `osVersion` |
| `device.enrollmentProfileName` | `enrollmentProfileName` |
| `device.deviceName` | `deviceName` |
| `device.deviceCategory` | `deviceCategoryDisplayName` |

**Not supported in v1** (returns `Unknown` with an explicit reason - never
guessed or silently skipped): `cpuArchitecture`, `deviceTrustType`,
`operatingSystemSKU`, `operatingSystemVersion` (and its `-gt`/`-lt`/`-ge`/
`-le` numeric operators), `isRooted`, `deviceManagementType`, and any
property not in the table above. `FilterMode = none` (no filter attached)
always permits the device.

## v1.0 vs beta - and why

**This build uses `/beta` for every Graph call, by explicit tenant-owner
decision.** That was not the original design. The tool was built and
validated with v1.0 as the default and beta isolated to three functions
that have no v1.0 alternative at all - the same design tradeoff Microsoft
itself documents: *"APIs under the `/beta` version in Microsoft Graph are
subject to change. Use of these APIs in production applications is not
supported."* Switching everything to beta was a deliberate choice made
after that tradeoff was raised explicitly, not an oversight or a fix for a
bug - the bugs found during development (see git history / conversation
that produced this tool) were an accidentally-beta'd `checkMemberGroups`
call and an unrelated batching issue, both fixed independently of API
version. If you want to move back to the original v1.0-by-default design,
every `Invoke-Graph(Paged)Request -Uri` in `CoverageAnalyzer.psm1` uses a
literal `"/beta/..."` prefix - three of them (below) must stay on beta
regardless; the rest can be changed back to `"/v1.0/..."` (each one was
verified to have a working v1.0 equivalent before this change).

Three functions have **no v1.0 equivalent at all**, independent of the
beta-everywhere choice above:

- **`Get-IntuneComplianceAssignments`** - the `deviceAndAppManagementAssignmentFilterId`
  / `...FilterType` properties on assignment targets are documented only on
  the **beta** `groupAssignmentTarget` resource, not on its v1.0 page, and
  filter id/mode is essential to correct evaluation.
- **`Get-IntuneAssignmentFilters`** - `deviceManagement/assignmentFilters`
  has no v1.0 surface at all.
- **`Get-DevicesWithoutCompliancePolicy`** (and its private helpers
  `Start-`/`Wait-`/`Receive-IntuneReportExportJob`) - the current
  `DevicesWithoutCompliancePolicyV3` report definition is only available
  through the `reports/exportJobs` async-export pattern, not through the
  inline v1.0 `getDevicesWithoutCompliancePolicyReport` action. The
  downloaded blob is then unzipped and parsed - the export job itself is a
  transient report artifact, not an Intune object, so this remains
  read-only.

**Permissions note:** the permission table above was verified against
v1.0 documentation specifically. Spot-checked beta equivalents (e.g.
`checkMemberGroups`) require the same scopes, but every endpoint's beta
permission requirements were not independently re-verified one by one -
if you see a 403 that didn't happen before switching to beta, that's the
first thing to check.

## Known limitations / assumptions

- **Windows only in v1.** Non-Windows devices are reported as unsupported,
  not silently skipped or mis-evaluated. The platform mapping lives in one
  function (`Get-CompliancePolicyPlatform`) specifically so other
  platforms can be added later without restructuring the rest of the tool.
- **"All Licensed Users" is treated as matching any device with an
  associated user**, without verifying the user actually holds a license.
  Checking license assignment would add a Graph call per unique user for
  a case that's rare in practice; this is a deliberate scope decision.
- **Mixed `and`/`or` without parentheses** in a filter rule is evaluated
  left-to-right rather than with and-before-or precedence.
- **Hidden group membership** (see Permissions above) is a real blind
  spot that can't always be detected as such.
- **Duplicate Entra device objects** (multiple directory objects sharing one
  `deviceId` - a common artifact of re-imaging/re-enrollment, especially for
  hybrid Azure AD join) are handled in two stages, anchored on the managed
  device rather than guessed at the Entra layer alone:
  1. `Get-EntraDeviceContext` first tries to disambiguate using the managed
     device's own primary user: if exactly one of the duplicate objects is
     in that user's `registeredDevices`, that one is used (`Status =
     Resolved`, `ResolvedVia = RegisteredDevicesCrossCheck`), and the other,
     presumed-stale objects are still reported as a warning with enough
     detail (`accountEnabled`, `registrationDateTime`,
     `approximateLastSignInDateTime`) to clean them up in Entra ID.
  2. If that cross-check doesn't narrow it to exactly one candidate (no
     primary user, the cross-check itself fails or isn't permitted - see
     the optional permission note above - or more than one candidate
     matches), the device stays `Status = Ambiguous` and every downstream
     group check for it reports `Unknown`, exactly as before. Nothing here
     ever silently picks a "most likely" object without that evidence.
  - **This cross-check structurally cannot help userless (shared/kiosk)
    devices** - it only works by matching against a *user's*
    `registeredDevices`, and a userless device has no user to check
    against. If such a device also has duplicate Entra objects, it will
    stay `Ambiguous` regardless of how many of the other fixes in this
    tool apply. A weaker heuristic (e.g. correlating Entra
    `approximateLastSignInDateTime`/`accountEnabled` against the managed
    device's own `lastSyncDateTime`) could narrow this further, but wasn't
    added - it's a guess rather than an authoritative relationship, and
    would need an explicit decision to accept that tradeoff before adding it.
  - In practice this has shown up as a widespread, tenant-wide pattern
    (multiple unrelated devices, both with and without a primary user, all
    hitting duplicate Entra objects) rather than isolated bad data - if you
    see this often, it's worth treating as its own Entra ID cleanup project
    rather than resolving device by device.
- The devices-without-compliance-policy report's row-to-managedDevice
  correlation is done defensively: it first tries an id-like column
  (`IntuneDeviceId`/`DeviceId`), and falls back to a name lookup (with the
  same ambiguity guard as `-DeviceName`) if that id doesn't resolve to a
  managedDevice. Rows that resolve to neither are reported and skipped,
  never silently dropped.

## Architecture

- **`CoverageAnalyzer.psm1`** - all logic. Graph transport
  (`Invoke-GraphRequest`, `Invoke-GraphPagedRequest`) and retrieval
  functions at the top (`Get-IntuneManagedDeviceContext`,
  `Get-EntraDeviceContext`, `Get-IntuneCompliancePolicies`,
  `Get-IntuneComplianceAssignments`, `Get-IntuneAssignmentFilters`,
  `Get-GroupDisplayNames`, `Get-DirectoryObjectGroupMembership`,
  `Get-DevicesWithoutCompliancePolicy` and its export-job helpers,
  `ConvertFrom-IntuneReportPayload`); pure decision-logic functions (no
  Graph calls) in the middle - `Test-IntuneAssignmentFilter`,
  `Test-CompliancePolicyAssignment`, `Test-CompliancePolicyCoverage`,
  `Get-CompliancePolicyPlatform`, `Get-ReportRowPlatform`,
  `Get-DeviceCoverageRollup` - so Pester can exercise the actual decision
  logic without mocking Graph; per-device orchestration
  (`Get-CompliancePolicyCoverageForDevice`) and presentation
  (`Format-ComplianceCoverageResult`, `Format-ComplianceCoverageSummary`,
  `Export-ComplianceCoverageHtml`) at the bottom.
- **`Test-IntuneCompliancePolicyCoverage.ps1`** - thin entry point: param
  block, session check, mode dispatch, export.
- **`Tests/CoverageAnalyzer.Tests.ps1`** - Pester 5 tests against the pure
  decision functions.

## Performance / scale

- Compliance policies, their assignments, assignment filters, and every
  assignment group's display name are each retrieved **once per run** (not
  once per device), with `@odata.nextLink` pagination handled throughout.
- Per device, every assignment group id used by any Windows compliance
  policy is collected once, then checked with `checkMemberGroups` in
  batches of at most 20 group ids - never one request per group, never one
  request per policy.
- `checkMemberGroups` evaluates its whole `groupIds` list as a single
  request - Graph itself documents that one invalid id fails the entire
  batch. `Get-DirectoryObjectGroupMembership` retries a failed batch one id
  at a time, so a single stale/bad group id can only mark *that* id as
  unresolved rather than every group in the same batch - this was a real
  bug found and fixed during development, not a hypothetical.
- `Invoke-GraphRequest` retries `429`/`503`/`504` with a bounded retry
  count, honoring `Retry-After` when the SDK surfaces it and falling back
  to capped exponential backoff otherwise.
- A group whose membership couldn't be checked ends up in that call's
  `Unresolved` set (never silently matched or unmatched), and a device
  whose Entra object couldn't be resolved at all skips the check entirely
  (`$null`) - both cases evaluate as `Unknown`, never as "not a member."
- Bulk mode (`-AllDevicesWithoutCompliancePolicy`) prints visible progress
  for the report export job itself (scheduled -> polling status -> download
  -> unpack), not just the per-device analysis that follows it - useful
  since the export can take anywhere from a few seconds to a few minutes.

## Running the tests

```powershell
Invoke-Pester -Path .\Tests\CoverageAnalyzer.Tests.ps1
```
