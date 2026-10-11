# DOrc PowerShell Deploy Module

## Description

`DOrcDeployModule` is a PowerShell module used by DOrc (DevOps Deployment Orchestrator) deployment scripts.
It provides helper functions for:

- Windows server and service orchestration
- MSI/software installation and removal
- SQL Server and DACPAC deployment operations
- RabbitMQ configuration and cleanup
- CredSSP validation and enablement
- Secure logging of deployment parameters
- Azure SQL deployment with Azure access tokens

The module implementation is in:

- `./DOrcDeployModule.psm1`
- `./DOrcDeployModule.psd1`

## Key functions

Examples of commonly used functions include:

- `Format-ParameterForLogging`
- `Get-DorcCredSSPStatus`
- `Enable-DorcCredSSP`
- `DeployDACPAC`
- `DeployDACPACToAzureSQL`
- `Get-AzAccessTokenToResource`
- `Get-DorcToken`

## Database permission modes

`Apply-DatabasePermissions` defaults to the existing legacy CLI behavior. For a
migrated SQL-only database, deploy the updated generic `Tools.ApplyPermissionsCLI`
from `dorc-cli`, then opt in explicitly:

```powershell
Apply-DatabasePermissions -instance 'SQL-SERVER\DEV' -database 'ApplicationDB' `
    -permissionSource DatabaseAccess -environment 'BB Labs 01' -previewOnly
```

Remove `-previewOnly` to apply a fresh API preview. Set the environment deployment
property `DatabasePermissionsMode=DatabaseAccess` to opt existing callers (including
post-restore calls) into this mode without editing each script. Leave it unset or
`Legacy` for legacy deployments. Do not use the legacy reset on migrated databases.

The module forwards `EnvironmentName`, `RefDataApiUrl` and `IsProd`, quotes arguments,
checks the CLI's embedded `DOrc.DatabaseAccess/1` capability marker before running
it, captures stdout/stderr and throws on nonzero exit codes. An older or
Endur/Arc/ComOps-specific executable is rejected in DatabaseAccess mode; those
tools also manage application accounts, which the new SQL-only API does not.
There is no fallback from DatabaseAccess to legacy.

Both apply modes still require a successful permissions backup and a database in
the normal state. Each extraction uses a unique backup folder so retries cannot
reuse stale SQL files; earlier backups are retained. Preview skips the backup/legacy
SQL connection and never applies.
Backup failure, an abnormal database state, or a failed CLI now stops the deployment
rather than allowing subsequent restore steps to continue.

The DatabaseAccess schema/API (including machine-to-machine audit identity support)
must be deployed first. The API database allowlist and independent execution switch
remain authoritative. The CLI authenticates using its configured OAuth client or
Windows identity; target SQL operations use the **API service identity**. Configure
API service-account SQL permissions and trusted certificates before enabling apply.
Production applies remain additive-only. Review/import desired state before moving
an environment to the new mode; no automatic legacy import is performed.

## Build and publish workflows

The repository includes GitHub Actions workflows:

- **Build** (`.github/workflows/build.yml`)
  - Runs on pushes to `main` and `feature/*`, pull requests, and manual dispatch
  - Updates module version (`UpdateVersion.ps1`)
  - Packages `.psm1` and `.psd1` files as artifacts
- **Publish** (`.github/workflows/publish.yml`)
  - Manual workflow that publishes `DOrcDeployModule` to the PowerShell Gallery
  - Uses a successful build artifact and the `PSGALLERY_API_KEY` secret

## Testing

Pester tests are available in this repository:

- `./DorcDeployModule.unit.tests.ps1`
- `./DOrcDeployModule.tests.ps1`

Run tests with:

```powershell
Invoke-Pester -Path ./DorcDeployModule.unit.tests.ps1 -CI
```

## Contributions

SEFE welcomes contributions to this solution.

## Authors

The solution is designed and built by SEFE Securing Energy for Europe GmbH.

SEFE - [Visit us online](https://www.sefe.eu/)

## License

This project is licensed under the Apache 2.0 License. See [LICENSE.md](./LICENSE.md) for details.
