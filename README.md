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
