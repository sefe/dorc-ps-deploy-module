$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module "$here\DOrcDeployModule.psm1" -Force -ErrorAction Stop

Describe "Enhanced Parameter Security Tests" {
    Context "Basic functionality" {
        It "Hides sensitive parameter names" {
            Format-ParameterForLogging "PASSWORD=secret123" | Should -Be "PASSWORD=***HIDDEN***"
        }
        
        It "Preserves non-sensitive parameters" {
            Format-ParameterForLogging "SERVER=localhost" | Should -Be "SERVER=localhost"
        }
        
        It "Is case insensitive" {
            Format-ParameterForLogging "my-Secret=test" | Should -Be "my-Secret=***HIDDEN***"
        }
    }
    
    Context "Real secure property examples" {
        It "Masks AccessKey in Azure SignalR connection string" {
            $testInput = "SIGNALR_CONN=Endpoint=https://app.service.signalr.net;AccessKey=secret123;Version=1.0"
            $result = Format-ParameterForLogging $testInput
            $result | Should -Match "AccessKey=\*\*\*HIDDEN\*\*\*"
            $result | Should -Match "Endpoint=https://app.service.signalr.net"
        }
        
        It "Masks Password in SQL connection string" {
            $testInput = "DB_CONN=Server=srv;Database=db;Password=secret123;Timeout=30"
            $result = Format-ParameterForLogging $testInput
            $result | Should -Match "Password=\*\*\*HIDDEN\*\*\*"
            $result | Should -Match "Server=srv"
        }
        
        It "Handles multiple secrets in one connection string" {
            $testInput = "CONN=Server=test;Password=secret;AccessKey=key123;Database=mydb"
            $result = Format-ParameterForLogging $testInput
            $result | Should -Match "Password=\*\*\*HIDDEN\*\*\*"
            $result | Should -Match "AccessKey=\*\*\*HIDDEN\*\*\*" 
            $result | Should -Match "Server=test"
        }

        It "Masks all examples of secret values" {
          $examples = @(
            "APPUSERPASSWORD", "ProdDeployPassword", "ApiAccessPassword", "SERVICE_SVCPASSWORD",
            "ClientSecret", "OAUTH_CLIENT_SECRET", "OAUTH2_CLIENTAPPID_SECRET", "CLIENT_PS_SECRET", "SqsSecretKey",
            "OPENAI_API_KEY", "SqsAccessKey", "ApiKey", "API_APIKEY", "PrivateKeyPassphrase", "_API_KEY_",
            "API_TOKEN", "VaultToken", "AccessTokenClientSecret", "EexToken",
            "BasicAuthHeader"
          )
          foreach ($example in $examples) {
            Format-ParameterForLogging "$example=somesecret" | Should -Match "$example=\*\*\*HIDDEN\*\*\*"
          }
        }
        
      }
}
