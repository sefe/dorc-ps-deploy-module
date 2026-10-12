BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    Import-Module "$here\DOrcDeployModule.psm1" -Force -ErrorAction Stop

    function script:New-FakeRegKey {
        param([hashtable] $SubKeys = @{}, [hashtable] $Values = @{})
        $obj = [PSCustomObject]@{ _SubKeys = $SubKeys; _Values = $Values }
        $obj | Add-Member -MemberType ScriptMethod -Name 'GetSubKeyNames' -Value {
            return @($this._SubKeys.Keys)
        }
        $obj | Add-Member -MemberType ScriptMethod -Name 'OpenSubKey' -Value {
            param($name)
            $child = $this._SubKeys[$name]
            if ($null -eq $child) { return $null }
            $childSubs = if ($child.ContainsKey('SubKeys')) { $child['SubKeys'] } else { @{} }
            $childVals = if ($child.ContainsKey('Values'))  { $child['Values']  } else { @{} }
            return (script:New-FakeRegKey -SubKeys $childSubs -Values $childVals)
        }
        $obj | Add-Member -MemberType ScriptMethod -Name 'GetValue' -Value {
            param($name)
            return $this._Values[$name]
        }
        return $obj
    }

    $script:WOW6432 = 'SOFTWARE\\Wow6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall'
    $script:NATIVE  = 'SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall'
}

Describe "Find-RemoteNSIS" {

    It "Returns 'None' when no subkey contains the product string" {
        $fake = script:New-FakeRegKey -SubKeys @{
            $script:WOW6432 = @{ SubKeys = @{ 'Microsoft .NET' = @{ Values = @{ UninstallString = 'msiexec /X{123}' } } } }
            $script:NATIVE  = @{ SubKeys = @{} }
        }
        Mock -ModuleName DOrcDeployModule Open-RemoteRegistryHive ({ return $fake }.GetNewClosure())

        Find-RemoteNSIS 'server' 'Erlang' | Should -Be 'None'
    }

    It "Returns 'None' when the matching key has a null UninstallString value" {
        $fake = script:New-FakeRegKey -SubKeys @{
            $script:WOW6432 = @{ SubKeys = @{ 'Erlang OTP' = @{ Values = @{} } } }
            $script:NATIVE  = @{ SubKeys = @{} }
        }
        Mock -ModuleName DOrcDeployModule Open-RemoteRegistryHive ({ return $fake }.GetNewClosure())

        { Find-RemoteNSIS 'server' 'Erlang' } | Should -Not -Throw
        Find-RemoteNSIS 'server' 'Erlang' | Should -Be 'None'
    }

    It "Strips the NSIS convention wrapping double-quotes from the returned UninstallString" {
        $fake = script:New-FakeRegKey -SubKeys @{
            $script:WOW6432 = @{ SubKeys = @{
                'Erlang OTP 26.2.5' = @{ Values = @{
                    UninstallString = '"C:\Program Files\Erlang OTP\Uninstall.exe"'
                }}
            }}
            $script:NATIVE  = @{ SubKeys = @{} }
        }
        Mock -ModuleName DOrcDeployModule Open-RemoteRegistryHive ({ return $fake }.GetNewClosure())

        Find-RemoteNSIS 'server' 'Erlang' | Should -Be 'C:\Program Files\Erlang OTP\Uninstall.exe'
    }

    It "Returns the value unmodified when it is not wrapped in quotes" {
        $fake = script:New-FakeRegKey -SubKeys @{
            $script:NATIVE  = @{ SubKeys = @{
                'Erlang OTP' = @{ Values = @{ UninstallString = 'C:\X\uninst.exe' } }
            }}
            $script:WOW6432 = @{ SubKeys = @{} }
        }
        Mock -ModuleName DOrcDeployModule Open-RemoteRegistryHive ({ return $fake }.GetNewClosure())

        Find-RemoteNSIS 'server' 'Erlang' | Should -Be 'C:\X\uninst.exe'
    }

    It "Finds a match in the 64-bit hive when it is not in the Wow6432 hive" {
        $fake = script:New-FakeRegKey -SubKeys @{
            $script:WOW6432 = @{ SubKeys = @{} }
            $script:NATIVE  = @{ SubKeys = @{
                'RabbitMQ Server 3.12' = @{ Values = @{
                    UninstallString = '"C:\Program Files\RabbitMQ\Uninstall.exe"'
                }}
            }}
        }
        Mock -ModuleName DOrcDeployModule Open-RemoteRegistryHive ({ return $fake }.GetNewClosure())

        Find-RemoteNSIS 'server' 'RabbitMQ' | Should -Be 'C:\Program Files\RabbitMQ\Uninstall.exe'
    }
}

Describe "Remove-NSISErlang attempt cap" {

    It "Throws after 5 attempts when the uninstaller never clears the registry entry" {
        Mock -ModuleName DOrcDeployModule Find-RemoteNSIS { return 'C:\Program Files\Erlang OTP\Uninstall.exe' }
        Mock -ModuleName DOrcDeployModule Invoke-RemoteProcess { return @($true) }
        Mock -ModuleName DOrcDeployModule Test-Path { return $false }

        { Remove-NSISErlang 'server' } | Should -Throw -ExpectedMessage '*exceeded*'
        Should -Invoke -ModuleName DOrcDeployModule -CommandName Invoke-RemoteProcess -Times 5 -Exactly
    }

    It "Exits cleanly after one successful uninstall pass" {
        $script:callCount = 0
        Mock -ModuleName DOrcDeployModule Find-RemoteNSIS {
            $script:callCount++
            if ($script:callCount -eq 1) {
                return 'C:\Program Files\Erlang OTP\Uninstall.exe'
            }
            return 'None'
        }
        Mock -ModuleName DOrcDeployModule Invoke-RemoteProcess { return @($true) }
        Mock -ModuleName DOrcDeployModule Test-Path { return $false }

        { Remove-NSISErlang 'server' } | Should -Not -Throw
        Should -Invoke -ModuleName DOrcDeployModule -CommandName Invoke-RemoteProcess -Times 1 -Exactly
    }
}

Describe "Remove-NSISRabbitMQ attempt cap" {

    It "Throws after 5 attempts when the uninstaller never clears the registry entry" {
        Mock -ModuleName DOrcDeployModule Find-RemoteNSIS { return 'C:\Program Files\RabbitMQ Server\Uninstall.exe' }
        Mock -ModuleName DOrcDeployModule Invoke-RemoteProcess { return @($true) }
        Mock -ModuleName DOrcDeployModule Test-Path { return $false }

        { Remove-NSISRabbitMQ 'server' } | Should -Throw -ExpectedMessage '*exceeded*'
        Should -Invoke -ModuleName DOrcDeployModule -CommandName Invoke-RemoteProcess -Times 5 -Exactly
    }
}
