BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    Import-Module "$here\DOrcDeployModule.psm1" -Force -ErrorAction Stop
}

Describe "Apply-DatabasePermissions integration" {
    BeforeAll {
        InModuleScope DOrcDeployModule {
            function script:Get-DBPermissions {
                [CmdletBinding()]
                param($server, $database, $outputFilepath)
                throw "Tests must mock permission extraction."
            }
        }
    }

    BeforeEach {
        InModuleScope DOrcDeployModule {
            $script:IsProd = $false
            $script:EnvironmentName = 'BB Labs 01'
            $script:RefDataApiUrl = 'https://dorc.test:8443/'
            $script:ApplyPermissionsExePath = 'C:\Tools\Tools.ApplyPermissionsCLI.exe'
            $script:DBPermsOutput = 'C:\PermissionBackups'
            $script:DatabasePermissionsMode = $null
        }
        Mock -ModuleName DOrcDeployModule Get-Item {
            [pscustomobject]@{
                FullName = 'C:\Tools\Tools.ApplyPermissionsCLI.exe'
                DirectoryName = 'C:\Tools'
                VersionInfo = [pscustomobject]@{ Comments = 'DOrc.DatabaseAccess/1' }
            }
        }
        Mock -ModuleName DOrcDeployModule GetDBStatus { 'Normal' }
        Mock -ModuleName DOrcDeployModule GetDateReverse { 'test-date' }
        Mock -ModuleName DOrcDeployModule Get-DBPermissions { }
        Mock -ModuleName DOrcDeployModule Test-Path { $true }
        Mock -ModuleName DOrcDeployModule Get-ChildItem { [pscustomobject]@{ Name = 'permissions.sql' } }
        Mock -ModuleName DOrcDeployModule Start-Process { [pscustomobject]@{ ExitCode = 0 } }
    }

    It "keeps existing callers on legacy mode and checks the process result" {
        Apply-DatabasePermissions -instance 'SQL\DEV' -database 'App DB'
        Should -Invoke -ModuleName DOrcDeployModule Start-Process -Times 1 -Exactly -ParameterFilter {
            $ArgumentList -eq '"/instance:SQL\DEV" "/database:App DB" "/prod:False"' -and
            $PassThru -and $Wait -and $WorkingDirectory -eq 'C:\Tools' -and
            $RedirectStandardOutput -and $RedirectStandardError
        }
        Should -Invoke -ModuleName DOrcDeployModule Get-DBPermissions -Times 1 -Exactly
    }

    It "passes the deployment environment and API to preview without a legacy reset or extraction" {
        Apply-DatabasePermissions -instance 'SQL\DEV' -database 'App DB' -permissionSource DatabaseAccess -previewOnly
        Should -Invoke -ModuleName DOrcDeployModule Start-Process -Times 1 -Exactly -ParameterFilter {
            ($ArgumentList -join ' ').Contains('"/permissions:DatabaseAccess"') -and
            ($ArgumentList -join ' ').Contains('"/environment:BB Labs 01"') -and
            ($ArgumentList -join ' ').Contains('"/apiurl:https://dorc.test:8443/"') -and
            ($ArgumentList -join ' ').Contains('"/preview:True"')
        }
        Should -Invoke -ModuleName DOrcDeployModule GetDBStatus -Times 0 -Exactly
        Should -Invoke -ModuleName DOrcDeployModule Get-DBPermissions -Times 0 -Exactly
    }

    It "honours the environment deployment property for existing callers" {
        InModuleScope DOrcDeployModule { $script:DatabasePermissionsMode = 'DatabaseAccess' }
        Apply-DatabasePermissions -instance 'SQL\DEV' -database 'App DB' -previewOnly
        Should -Invoke -ModuleName DOrcDeployModule Start-Process -Times 1 -Exactly -ParameterFilter {
            ($ArgumentList -join ' ').Contains('"/permissions:DatabaseAccess"')
        }
    }

    It "rejects old and application-specific executables before starting them" {
        Mock -ModuleName DOrcDeployModule Get-Item {
            [pscustomobject]@{ VersionInfo = [pscustomobject]@{ Comments = '' } }
        }
        { Apply-DatabasePermissions 'SQL' 'App' -permissionSource DatabaseAccess } |
            Should -Throw '*does not support its protocol*'
        Should -Invoke -ModuleName DOrcDeployModule Start-Process -Times 0 -Exactly
        Should -Invoke -ModuleName DOrcDeployModule GetDBStatus -Times 0 -Exactly
    }

    It "fails the deployment on a nonzero CLI exit code without retrying legacy" {
        Mock -ModuleName DOrcDeployModule Start-Process { [pscustomobject]@{ ExitCode = 1 } }
        { Apply-DatabasePermissions 'SQL' 'App' -permissionSource DatabaseAccess -previewOnly } |
            Should -Throw '*exit code 1*'
        Should -Invoke -ModuleName DOrcDeployModule Start-Process -Times 1 -Exactly
    }

    It "does not run either permission implementation when the backup fails" {
        Mock -ModuleName DOrcDeployModule Get-ChildItem { }
        { Apply-DatabasePermissions 'SQL' 'App' } | Should -Throw '*Permissions extract failed*'
        Should -Invoke -ModuleName DOrcDeployModule Start-Process -Times 0 -Exactly
    }

    It "rejects a same-minute <Mode> retry without a fresh backup" -TestCases @(
        @{ Mode = 'Legacy' }
        @{ Mode = 'DatabaseAccess' }
    ) {
        param($Mode)

        InModuleScope DOrcDeployModule -Parameters @{ BackupRoot = (Join-Path $TestDrive $Mode) } {
            param($BackupRoot)
            $script:DBPermsOutput = $BackupRoot
        }
        $script:ExtractionFolders = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName DOrcDeployModule Get-DBPermissions {
            param($server, $database, $outputFilepath)
            $script:ExtractionFolders.Add($outputFilepath)
            [System.IO.Directory]::CreateDirectory($outputFilepath) | Out-Null
            if ($script:ExtractionFolders.Count -eq 1) {
                [System.IO.File]::WriteAllText(
                    (Join-Path $outputFilepath 'permissions.sql'), '-- first attempt backup'
                )
            }
        }
        Mock -ModuleName DOrcDeployModule Test-Path {
            param($LiteralPath)
            [System.IO.Directory]::Exists($LiteralPath)
        }
        Mock -ModuleName DOrcDeployModule Get-ChildItem {
            param($LiteralPath)
            [System.IO.Directory]::GetFiles($LiteralPath, '*.sql', [System.IO.SearchOption]::AllDirectories)
        }

        Apply-DatabasePermissions 'SQL\DEV' 'App DB' -permissionSource $Mode
        { Apply-DatabasePermissions 'SQL\DEV' 'App DB' -permissionSource $Mode } |
            Should -Throw '*Permissions extract failed*'

        Should -Invoke -ModuleName DOrcDeployModule Start-Process -Times 1 -Exactly
        Should -Invoke -ModuleName DOrcDeployModule Get-DBPermissions -Times 2 -Exactly
        $script:ExtractionFolders[1] | Should -Not -Be $script:ExtractionFolders[0]
        [System.IO.File]::Exists((Join-Path $script:ExtractionFolders[0] 'permissions.sql')) |
            Should -BeTrue
    }

    It "does not turn a preview request into a legacy apply" {
        { Apply-DatabasePermissions 'SQL' 'App' -previewOnly } | Should -Throw '*only with DatabaseAccess*'
        Should -Invoke -ModuleName DOrcDeployModule Start-Process -Times 0 -Exactly
    }
}

Describe "DeleteRabbit Mode Parameter Tests" {
    Context "Valid mode parameter" {
        BeforeAll {
            Mock -ModuleName DOrcDeployModule -CommandName Invoke-RestMethod -MockWith { return @() }
            Mock -ModuleName DOrcDeployModule -CommandName ConvertTo-SecureString -MockWith {
                $securePassword = [System.Security.SecureString]::new()
                "SecurePassword".ToCharArray() | ForEach-Object { $securePassword.AppendChar($_) }
                $securePassword.MakeReadOnly()
                return $securePassword
            }
            Mock -ModuleName DOrcDeployModule -CommandName Add-Type -MockWith { }
        }
        
        It "Should handle 'exchange' mode correctly" {
            { DeleteRabbit -mode 'exchange' -deleteStrings @('test') -RabbitUserName 'user' -RabbitPassword 'pass' -RabbitAPIPort '15672' -Server 'localhost' } | Should -Not -Throw
        }
        
        It "Should handle 'queue' mode correctly" {
            { DeleteRabbit -mode 'queue' -deleteStrings @('test') -RabbitUserName 'user' -RabbitPassword 'pass' -RabbitAPIPort '15672' -Server 'localhost' } | Should -Not -Throw
        }
    }
    
    Context "Invalid mode parameter" {
        BeforeAll {
            Mock -ModuleName DOrcDeployModule -CommandName Invoke-RestMethod -MockWith { return @() }
            Mock -ModuleName DOrcDeployModule -CommandName ConvertTo-SecureString -MockWith {
                $securePassword = [System.Security.SecureString]::new()
                "SecurePassword".ToCharArray() | ForEach-Object { $securePassword.AppendChar($_) }
                $securePassword.MakeReadOnly()
                return $securePassword
            }
            Mock -ModuleName DOrcDeployModule -CommandName Add-Type -MockWith { }
        }
        
        It "Should warn and skip REST calls for an invalid mode" {
            $warnings = @(DeleteRabbit -mode 'invalid' -deleteStrings @('test') -RabbitUserName 'user' -RabbitPassword 'pass' -RabbitAPIPort '15672' -Server 'localhost' 3>&1)

            $warnings | Should -HaveCount 1
            $warnings[0].Message | Should -Be "Invalid mode specified: invalid. Valid values are 'exchange' or 'queue'."
            Should -Invoke -ModuleName DOrcDeployModule -CommandName Invoke-RestMethod -Times 0 -Exactly
        }
    }
}

Describe "CheckBackup RestoreMode Parameter Tests" {
    Context "Invalid RestoreMode value" {
        It "Should throw for invalid RestoreMode" {
            { CheckBackup -SourceInstance 'localhost' -SourceDB 'TestDB' -RestoreMode 'invalid' } | Should -Throw "wrong RestoreMode*"
        }
    }
}

Describe "Get-DorcCredSSPStatus tests" {
    Context "Computer reachable" {

        Context "Returns an object with all the expected properties" {
            BeforeAll {
                $script:TestCred = New-Object System.Management.Automation.PSCredential(
                    'nwtraders\administrator',
                    ('mypassword' | ConvertTo-SecureString -AsPlainText -Force))

                Mock -ModuleName DOrcDeployModule Test-IsRunningAsAdministrator { return $true }

                Mock -ModuleName DOrcDeployModule Get-WSManCredSSP {
                    "The machine is configured to allow delegating fresh credentials to the following target(s): SERVER1`nThis computer is not configured to receive credentials from a remote client computer."
                }
                Mock -ModuleName DOrcDeployModule Get-ServerOSVersion { '10.0.17134' }
                Mock -ModuleName DOrcDeployModule Invoke-Command {
                    "The machine is configured to allow delegating fresh credentials to the following target(s): SERVER1`nThis computer is configured to receive credentials from a remote client computer."
                }
                Mock -ModuleName DOrcDeployModule Get-MSHotfix {
                    New-Object psobject -Property @{ HotFixID = 'KB12345678' }
                }
            }

            It "Returns an object with all the expected properties" {
                $result = Get-DorcCredSSPStatus -ComputerName Server1 -Credential $script:TestCred -Test
                $result.LocalComputerName | Should -Be $Env:COMPUTERNAME
                $result.RemoteComputerName | Should -Be "SERVER1"
                $result.LocalOS | Should -Be "10.0.17134"
                $result.RemoteOS | Should -Be "10.0.17134"
                $result.LocalCredSSPEnabled | Should -Match "true|false"
                $result.RemoteCredSSPEnabled | Should -Match "true|false"
                $result.LocalPatchInstalled | Should -Match "true|false"
                $result.RemotePatchInstalled | Should -Match "true|false"
                $result.LocalHotFixWorkaroundInPlace | Should -Match "true|false"
                $result.RemoteHotFixWorkaroundInPlace | Should -Match "true|false"
                $result.CredSSPWorks | Should -Match "true|false"
            }
        }

        Context "Credential Delegation Enabled on Client and on Server" {
            BeforeAll {
                $script:TestCred = New-Object System.Management.Automation.PSCredential(
                    'nwtraders\administrator',
                    ('mypassword' | ConvertTo-SecureString -AsPlainText -Force))

                Mock -ModuleName DOrcDeployModule Test-IsRunningAsAdministrator { return $true }

                Mock -ModuleName DOrcDeployModule Get-WSManCredSSP {
                    "The machine is configured to allow delegating fresh credentials to the following target(s): SERVER1`nThis computer is not configured to receive credentials from a remote client computer."
                }
                Mock -ModuleName DOrcDeployModule Get-WmiObject {
                    New-Object psobject -Property @{ Version = '10.0.17134'; AllowEncryptionOracle = 0 }
                }
                Mock -ModuleName DOrcDeployModule Invoke-Command {
                    "The machine is configured to allow delegating fresh credentials to the following target(s): SERVER1`nThis computer is configured to receive credentials from a remote client computer."
                }
                Mock -ModuleName DOrcDeployModule Get-MSHotfix {
                    New-Object psobject -Property @{ HotFixID = 'KB12345678' }
                }
            }

            It "Returns LocalCredSSPEnabled and RemoteCredSSPEnabled as True" {
                $result = Get-DorcCredSSPStatus -ComputerName Server1 -Credential $script:TestCred
                $result.LocalCredSSPEnabled | Should -Be $true
                $result.RemoteCredSSPEnabled | Should -Be $true
            }
        }

        Context "Credential Delegation NOT enabled on Client" {
            BeforeAll {
                $script:TestCred = New-Object System.Management.Automation.PSCredential(
                    'nwtraders\administrator',
                    ('mypassword' | ConvertTo-SecureString -AsPlainText -Force))

                Mock -ModuleName DOrcDeployModule Test-IsRunningAsAdministrator { return $true }

                Mock -ModuleName DOrcDeployModule Get-WSManCredSSP {
                    "The machine is not configured to allow delegating fresh credentials.`nThis computer is not configured to receive credentials from a remote client computer."
                }
                Mock -ModuleName DOrcDeployModule Get-WmiObject {
                    New-Object psobject -Property @{ Version = '10.0.17134'; AllowEncryptionOracle = 0 }
                }
                Mock -ModuleName DOrcDeployModule Invoke-Command {
                    "The machine is configured to allow delegating fresh credentials to the following target(s): SERVER1`nThis computer is configured to receive credentials from a remote client computer."
                }
                Mock -ModuleName DOrcDeployModule Get-MSHotfix {
                    New-Object psobject -Property @{ HotFixID = 'KB12345678' }
                }
            }

            It "Returns LocalCredSSPEnabled as False" {
                $result = Get-DorcCredSSPStatus -ComputerName Server1 -Credential $script:TestCred
                $result.LocalCredSSPEnabled | Should -Be $false
            }
        }

        Context "Credential Delegation enabled on Client but delegated computer doesn't match remote computer's name" {
            BeforeAll {
                $script:TestCred = New-Object System.Management.Automation.PSCredential(
                    'nwtraders\administrator',
                    ('mypassword' | ConvertTo-SecureString -AsPlainText -Force))

                Mock -ModuleName DOrcDeployModule Test-IsRunningAsAdministrator { return $true }

                Mock -ModuleName DOrcDeployModule Get-WSManCredSSP {
                    "The machine is configured to allow delegating fresh credentials to the following target(s): SERVER2`nThis computer is not configured to receive credentials from a remote client computer."
                }
                Mock -ModuleName DOrcDeployModule Get-WmiObject {
                    New-Object psobject -Property @{ Version = '10.0.17134'; AllowEncryptionOracle = 0 }
                }
                Mock -ModuleName DOrcDeployModule Invoke-Command {
                    "The machine is configured to allow delegating fresh credentials to the following target(s): SERVER1`nThis computer is configured to receive credentials from a remote client computer."
                }
                Mock -ModuleName DOrcDeployModule Get-MSHotfix {
                    New-Object psobject -Property @{ HotFixID = 'KB12345678' }
                }
            }

            It "Returns LocalCredSSPEnabled as False (delegated computer mismatch)" {
                $result = Get-DorcCredSSPStatus -ComputerName Server1 -Credential $script:TestCred
                $result.LocalCredSSPEnabled | Should -Be $false
            }
        }

        Context "Credential Delegation not enabled on Server" {
            BeforeAll {
                $script:TestCred = New-Object System.Management.Automation.PSCredential(
                    'nwtraders\administrator',
                    ('mypassword' | ConvertTo-SecureString -AsPlainText -Force))

                Mock -ModuleName DOrcDeployModule Test-IsRunningAsAdministrator { return $true }

                Mock -ModuleName DOrcDeployModule Get-WSManCredSSP {
                    "The machine is configured to allow delegating fresh credentials to the following target(s): SERVER1`nThis computer is not configured to receive credentials from a remote client computer."
                }
                Mock -ModuleName DOrcDeployModule Get-WmiObject {
                    New-Object psobject -Property @{ Version = '10.0.17134'; AllowEncryptionOracle = 0 }
                }
                Mock -ModuleName DOrcDeployModule Invoke-Command {
                    "The machine is configured to allow delegating fresh credentials to the following target(s): SERVER1`nThis computer is not configured to receive credentials from a remote client computer."
                }
                Mock -ModuleName DOrcDeployModule Get-MSHotfix {
                    New-Object psobject -Property @{ HotFixID = 'KB12345678' }
                }
            }

            It "Returns RemoteCredSSPEnabled as False" {
                $result = Get-DorcCredSSPStatus -ComputerName Server1 -Credential $script:TestCred
                $result.RemoteCredSSPEnabled | Should -Be $false
            }
        }
    }

    Context "Computer not reachable" {
        BeforeAll {
            $script:TestCred = New-Object System.Management.Automation.PSCredential(
                'nwtraders\administrator',
                ('mypassword' | ConvertTo-SecureString -AsPlainText -Force))

            Mock -ModuleName DOrcDeployModule Test-IsRunningAsAdministrator { return $true }
            Mock -ModuleName DOrcDeployModule Get-WSManCredSSP {
                "The machine is configured to allow delegating fresh credentials to the following target(s): SERVER1`nThis computer is not configured to receive credentials from a remote client computer."
            }
            Mock -ModuleName DOrcDeployModule Get-ServerOSVersion { '10.0.17134' }
            Mock -ModuleName DOrcDeployModule Invoke-Command {
                throw [System.Management.Automation.RemoteException]::new('Connection refused')
            }
        }

        It "Fails" {
            { Get-DorcCredSSPStatus -ComputerName Server1 -Credential $script:TestCred } | Should -Throw "*Failed to connect*"
        }
    }
}

Describe "Enable-DorcCredSSP tests" {
    Context "Computer reachable" {

        Context "Already enabled" {
            BeforeAll {
                $script:TestCred = New-Object System.Management.Automation.PSCredential(
                    'nwtraders\administrator',
                    ('mypassword' | ConvertTo-SecureString -AsPlainText -Force))

                Mock -ModuleName DOrcDeployModule Test-IsRunningAsAdministrator { return $true }

                Mock -ModuleName DOrcDeployModule Get-DorcCredSSPStatus {
                    New-Object psobject -Property @{
                        LocalComputerName             = $Env:COMPUTERNAME
                        RemoteComputerName            = "SERVER1"
                        LocalOS                       = "10.0.17134"
                        RemoteOS                      = "10.0.14393"
                        LocalCredSSPEnabled           = "True"
                        RemoteCredSSPEnabled          = "True"
                        LocalPatchInstalled           = "False"
                        RemotePatchInstalled          = "False"
                        LocalHotFixWorkaroundInPlace  = "False"
                        RemoteHotFixWorkaroundInPlace = "False"
                        CredSSPWorks                  = "True"
                    }
                }
            }

            It "Nothing to do" {
                $result = Enable-DorcCredSSP -ComputerName SERVER1 -Credential $script:TestCred
                $result | Should -Be "[INFO] CredSSP has already been enabled between [$Env:COMPUTERNAME] and [SERVER1]"
            }
        }

        Context "Not yet enabled - Get-DorcCredSSPStatus returns False then True across successive calls" {
            BeforeAll {
                $script:TestCred = New-Object System.Management.Automation.PSCredential(
                    'nwtraders\administrator',
                    ('mypassword' | ConvertTo-SecureString -AsPlainText -Force))

                Mock -ModuleName DOrcDeployModule Test-IsRunningAsAdministrator { return $true }
                Mock -ModuleName DOrcDeployModule Enable-WSManCredSSP { }

                $script:mockCalled = 0
                Mock -ModuleName DOrcDeployModule Get-DorcCredSSPStatus {
                    $script:mockCalled++
                    if ($script:mockCalled % 2 -eq 1) {
                        return (New-Object psobject -Property @{
                            LocalComputerName             = $Env:COMPUTERNAME
                            RemoteComputerName            = "SERVER1"
                            LocalOS                       = "10.0.17134"
                            RemoteOS                      = "10.0.14393"
                            LocalCredSSPEnabled           = "False"
                            RemoteCredSSPEnabled          = "False"
                            LocalPatchInstalled           = "False"
                            RemotePatchInstalled          = "False"
                            LocalHotFixWorkaroundInPlace  = "False"
                            RemoteHotFixWorkaroundInPlace = "False"
                            CredSSPWorks                  = "False"
                        })
                    }
                    return (New-Object psobject -Property @{
                        LocalComputerName             = $Env:COMPUTERNAME
                        RemoteComputerName            = "SERVER1"
                        LocalOS                       = "10.0.17134"
                        RemoteOS                      = "10.0.14393"
                        LocalCredSSPEnabled           = "True"
                        RemoteCredSSPEnabled          = "True"
                        LocalPatchInstalled           = "True"
                        RemotePatchInstalled          = "True"
                        LocalHotFixWorkaroundInPlace  = "True"
                        RemoteHotFixWorkaroundInPlace = "True"
                        CredSSPWorks                  = "True"
                    })
                }
                Mock -ModuleName DOrcDeployModule Invoke-Command `
                    -ParameterFilter { $ScriptBlock -and $ScriptBlock.ToString() -match 'Enable-WSManCredSSP' } `
                    -MockWith { }  # emit nothing — real Enable-WSManCredSSP returns no output
                Mock -ModuleName DOrcDeployModule Invoke-Command {
                    "The machine is configured to allow delegating fresh credentials to the following target(s): SERVER1`nThis computer is configured to receive credentials from a remote client computer."
                }
                Mock -ModuleName DOrcDeployModule Get-MSHotfix {
                    New-Object psobject -Property @{ HotFixID = 'KB12345678' }
                }
            }

            It "Enables CredSSP successfully" {
                $result = Enable-DorcCredSSP -ComputerName SERVER1 -Credential $script:TestCred
                $result | Should -Be "[INFO] CredSSP Successfully enabled between [$Env:COMPUTERNAME] and [SERVER1]"
            }
        }
    }

    Context "Computer not reachable" {
        BeforeAll {
            $script:TestCred = New-Object System.Management.Automation.PSCredential(
                'nwtraders\administrator',
                ('mypassword' | ConvertTo-SecureString -AsPlainText -Force))

            Mock -ModuleName DOrcDeployModule Test-IsRunningAsAdministrator { return $true }
            Mock -ModuleName DOrcDeployModule Get-DorcCredSSPStatus {
                New-Object psobject -Property @{
                    LocalComputerName             = $Env:COMPUTERNAME
                    RemoteComputerName            = "SERVER1"
                    LocalOS                       = "10.0.17134"
                    RemoteOS                      = "10.0.14393"
                    LocalCredSSPEnabled           = "True"
                    RemoteCredSSPEnabled          = "False"
                    LocalPatchInstalled           = "False"
                    RemotePatchInstalled          = "False"
                    LocalHotFixWorkaroundInPlace  = "False"
                    RemoteHotFixWorkaroundInPlace = "False"
                    CredSSPWorks                  = "False"
                }
            }
        }

        It "Throws" {
            { Enable-DorcCredSSP -ComputerName nonexistentcomputer -Credential $script:TestCred } |
                Should -Throw '*Failed*'
        }
    }
}
