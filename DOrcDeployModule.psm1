#region Helper Functions

<#
.SYNOPSIS
    Safely formats a parameter for logging, hiding sensitive values.
.PARAMETER Parameter
    The parameter string in format "Name=Value"
.OUTPUTS
    Formatted string safe for logging
#>
function Format-ParameterForLogging {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [string]$Parameter,
        [string]$MaskString = "***HIDDEN***"
    )
    
    process {
        if ($Parameter -notmatch '^([^=]+)=(.*)$') {
            Write-Warning "Invalid format: 'paramName=paramValue' expected"
            return $Parameter
        }
        
        $paramName = $Matches[1].Trim()
        $paramValue = $Matches[2].Trim()
        
        # Check if the parameter name itself indicates it's a secret
        $secretParams = 'password', 'pwd', 'secret', 'key', 'token', 'credential', 'api(key|secret)', 'accesskey', 'auth(header|token)'
        if ($paramName -match ($secretParams -join '|')) {
            return "$paramName=$MaskString"
        }
        
        # Mask secrets within connection-string style values
        $maskedValue = $paramValue -replace '(?i)(password|pwd|key|secret|token|accesskey|accountkey)\s*=\s*[^;]+', "`$1=$MaskString"
        
        return "$paramName=$maskedValue"
    }
}

<#
.SYNOPSIS
    TEMPORARY FIX: retries Invoke-Command against a single computer to work around
    intermittent WSMan "could not launch a host process" errors until root cause is found.
#>
function Invoke-CommandWithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $ComputerName,
        [Parameter(Mandatory = $true)]
        [scriptblock] $ScriptBlock,
        [object[]] $ArgumentList,
        [int] $RetryCount = 5,
        [int] $RetryDelaySeconds = 5
    )
    $invokeParams = @{
        ComputerName = $ComputerName
        ScriptBlock  = $ScriptBlock
        ErrorAction  = 'Stop'
    }
    # Invoke-Command rejects an explicit $null for -ArgumentList, so only pass it when supplied
    if ($PSBoundParameters.ContainsKey('ArgumentList')) { $invokeParams.ArgumentList = $ArgumentList }
    for ($attempt = 1; $attempt -le $RetryCount; $attempt++) {
        try {
            $result = Invoke-Command @invokeParams
            Write-Host "    Invoke-Command to $ComputerName is successfull"
            return $result
        }
        catch {
            Write-Host "    Invoke-Command to $ComputerName failed (attempt $attempt of $RetryCount): $($_.Exception.Message)"
            if ($attempt -eq $RetryCount) { throw }
            Start-Sleep -Seconds $RetryDelaySeconds
        }
    }
}
#endregion


function Invoke-VsDbCmd {
    Param
    (
        [Parameter(Mandatory = $true, Position = 0)]
        [string] $ManifestFile,
        
        [Parameter(Mandatory = $true, Position = 1)]
        [string] $ConnectionString,
        
        [Parameter(Mandatory = $false)]
        [string] $TargetDatabase,
		
        [Parameter(Mandatory = $false)]
        [string] $OutputFile,
		
        [Parameter(Mandatory = $false)]
        [switch] $RecreateDatabase,
		
        [Parameter(Mandatory = $false)]
        [switch] $Deploy,
		
        [Parameter()]
        [hashtable] $Properties
    )
    Process {
        $builder = New-Object -TypeName System.Text.StringBuilder
        $builder.AppendFormat("/a:Deploy /Manifest:`"{0}`" /cs:`"{1}`" /dsp:SQL", $ManifestFile, $ConnectionString) | Out-Null
		
        if ($OutputFile -ne $null -and $OutputFile.Length -gt 0) { $builder.AppendFormat(" /script:`"{0}`"", $OutputFile) | Out-Null }
		
        if ($TargetDatabase -ne $null) { $builder.AppendFormat(" /p:TargetDatabase=`"{0}`"", $TargetDatabase) | Out-Null }
		
        if ($RecreateDatabase) { $builder.Append(" /p:AlwaysCreateNewDatabase=True") | Out-Null }
				
        if ($Deploy) { $builder.Append(" /dd:+") | Out-Null }
		
        if ($Properties -ne $null) {
            foreach ($property in $Properties.GetEnumerator()) {
                $builder.AppendFormat(" /p:{0}", $property.Key) | Out-Null
                if ($property.Value -ne $null) { $builder.AppendFormat("={0}", $property.Value) | Out-Null }
            }
        }
		
        $builder.ToString()
        
        Start-Process vsdbcmd.exe $builder.ToString() -Wait
    }
}

function SendEmailToDOrcSupport([string] $StrSubject) {
    $Msg = New-Object Net.Mail.MailMessage
    $Smtp = New-Object Net.Mail.SmtpClient($DOrcSupportEmailSMTPServer)
    $Msg.From = $DOrcSupportEmailFrom
    $Msg.To.Add($DOrcSupportEmailTo)
    $Msg.Subject = $StrSubject
    $Smtp.Send($Msg)
    $Smtp = $null
    $Msg = $null
}

function GetDateReverse() {
    $dtNow = Get-Date
    return $dtNow.Year.ToString() + "-" + $dtNow.Month.ToString().PadLeft(2, '0') + "-" + $dtNow.Day.ToString().PadLeft(2, '0') + "_" + $dtNow.TimeOfDay.Hours.ToString().PadLeft(2, '0') + "-" + $dtNow.TimeOfDay.Minutes.ToString().PadLeft(2, '0')
}

function CheckDiskSpace([string[]] $servers, [int] $minMB = 100) {
    $bolSpaceCheckOK = $true
    Write-Host "  Checking disk space..."
    foreach ($server in $servers) {
        $serv = "[" + $server.Trim() + "]"
        $ntfsVolumes = Get-CimInstance -ClassName Win32_Volume -ComputerName $server | Where-Object {($_.FileSystem -eq "NTFS") -and ($_.driveletter)}
        foreach ($ntfsVolume in $ntfsVolumes) {
            #Considered checking for the existance of the pagefile file but it could be on C: which we care about (either orphaned or current)
            if ($ntfsVolume.DriveLetter -eq "P:") { write-host "     " $ntfsVolume.DriveLetter "Skipped..."}
            else {
                $freeSpace = [math]::Round($ntfsVolume.freespace / 1000000)
                if ($freeSpace -gt $minMB) {
                    Write-Host "    " $serv $ntfsVolume.DriveLetter $freeSpace"MB free - OK"
                }
                else {
                    $strMsgSubject = "     " + $serv + " " + $ntfsVolume.DriveLetter + " " + $freeSpace + "MB free - TOO LOW!"
                    Write-Host $strMsgSubject
                    SendEmailToDOrcSupport $strMsgSubject
                    $strMsgSubject = $null
                    $bolSpaceCheckOK = $false
                }
            }
        }
    }
    return $bolSpaceCheckOK
} 

function Get-InstalledMsiProducts([string] $strComputerName) {
    # Fast, registry-based replacement for the notoriously slow Win32_Product WMI/CIM class.
    # Enumerating Win32_Product forces the Windows Installer to run a consistency check
    # (self-repair validation) against EVERY installed MSI on the target, which routinely
    # takes 30-90+ seconds and spams MsiInstaller reconfiguration events into the event log.
    # Reading the Uninstall registry hives is sub-second and side-effect free.
    $results = New-Object System.Collections.ArrayList
    $uninstallKeys = @(
        "SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
    )
    $reg = [Microsoft.Win32.RegistryKey]::OpenRemoteBaseKey("LocalMachine", $strComputerName)
    try {
        foreach ($uninstallKey in $uninstallKeys) {
            $subkey = $reg.OpenSubKey($uninstallKey)
            if ($null -eq $subkey) { continue }
            foreach ($keyName in $subkey.GetSubKeyNames()) {
                $prodKey = $reg.OpenSubKey($uninstallKey + "\" + $keyName)
                if ($null -eq $prodKey) { continue }
                $dispName = $prodKey.GetValue("DisplayName")
                # Match Win32_Product's MSI-only scope: require the WindowsInstaller flag AND a
                # well-formed ProductCode GUID key name. This avoids matching non-MSI products
                # that happen to use GUID-like uninstall keys.
                $isMsi = ($prodKey.GetValue("WindowsInstaller") -eq 1) -and `
                         ($keyName -match '^\{[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}\}$')
                if ((![String]::IsNullOrEmpty($dispName)) -and $isMsi) {
                    [void]$results.Add([PSCustomObject]@{
                        Name            = $dispName
                        Version         = $prodKey.GetValue("DisplayVersion")
                        ProductCode     = $keyName
                        UninstallString = $prodKey.GetValue("UninstallString")
                        IsMsi           = $true
                    })
                }
                $prodKey.Close()
            }
            $subkey.Close()
        }
    }
    finally {
        $reg.Close()
    }
    return $results
}

function Remove-MsiProductByCode([string] $strComputerName, $Product) {
    if ((-not $Product.IsMsi) -or [String]::IsNullOrEmpty($Product.ProductCode)) {
        Write-Host "          No MSI ProductCode found in registry for" $Product.Name "- cannot uninstall via msiexec"
        return $false
    }
    try {
        $exitCode = Invoke-CommandWithRetry -ComputerName $strComputerName -ScriptBlock {
            param($code)
            $ErrorActionPreference = 'Stop'
            $p = Start-Process -FilePath "msiexec.exe" -ArgumentList "/x", $code, "/qn", "/norestart" -Wait -PassThru
            return $p.ExitCode
        } -ArgumentList $Product.ProductCode
    }
    catch {
        Write-Host "          Remote uninstall failed for" $Product.Name "-" $_.Exception.Message
        return $false
    }
    # 0 = success, 3010 = success but a reboot is required
    if ($exitCode -eq 0 -or $exitCode -eq 3010) {
        return $true
    }
    Write-Host "          msiexec returned exit code" $exitCode "for" $Product.Name
    return $false
}

function UnInstallProducts([string] $strComputerName, $ProductsToRemove) {
    $bolReturn = $true
    if (CheckDiskSpace $strComputerName) {
        try {
            $Products = Get-InstalledMsiProducts $strComputerName
        }
        catch {
            Write-Host "Failed to enumerate installed products on $strComputerName - $($_.Exception.Message)"
            return $false
        }
        foreach ($Product in $Products) {
            foreach ($strProductName in $ProductsToRemove) {
                if ($Product.Name -ne $null) {
                    if (($strProductName.Contains("*") -and $Product.Name.Contains($strProductName.Replace("*", ""))) -or ($strProductName -eq $Product.Name)) {
                        Write-Host "Removing:" $Product.Name " Version:" $Product.Version " GUID:" $Product.ProductCode " from" $strComputerName
                        if ((Remove-MsiProductByCode $strComputerName $Product) -eq $true) {
                            Write-Host "          Success..."
                        }
                        else {
                            $bolReturn = $false
                            Write-Host "FAILED to remove" $Product.Name
                        }
                    }
                }
            }
        }
    }
    else {
        Write-Host "Disk space check failed..."
        $bolReturn = $false
    }
    $Products = $null
    return $bolReturn
}

function RemoveMSI([string] $strComputerName, [string] $strMSIFullName, $ProductsToRemove) {
    $bolReturn = $true
    if (CheckDiskSpace $strComputerName) {
        Write-Host "Attempting to remove using msi ProductCode"
        $bolReturn = UninstallProduct -strComputerName $strComputerName -strMSIFullName $strMSIFullName

        try {
            $Products = Get-InstalledMsiProducts $strComputerName
        }
        catch {
            Write-Host "Failed to enumerate installed products on $strComputerName - $($_.Exception.Message)"
            return $false
        }
        foreach ($Product in $Products) {
            foreach ($strProductName in $ProductsToRemove) {
                if ($Product.Name -ne $null) {
                    if (($strProductName.Contains("*") -and $Product.Name.Contains($strProductName.Replace("*", ""))) -or ($strProductName -eq $Product.Name)) {
                        Write-Host "Removing:" $Product.Name " Version:" $Product.Version " GUID:" $Product.ProductCode " from" $strComputerName
                        Write-Host "Unable to uninstall based on Product Code, reverting to registry-based msiexec"
                        if ((Remove-MsiProductByCode $strComputerName $Product) -eq $true) {
                            Write-Host "          Success..."
                        }
                        else {
                            $bolReturn = $false
                            Write-Host "FAILED to remove" $Product.Name
                        }
                    }
                }
            }
        }
    }
    else {
        Write-Host "Disk space check failed..."
        $bolReturn = $false
    }
    $Products = $null
    return $bolReturn
}

function UninstallProduct([string] $strComputerName, [string] $strMSIFullName) {
    # Read property from MSI database
    $WindowsInstaller = New-Object -ComObject WindowsInstaller.Installer
    $MSIDatabase = $WindowsInstaller.GetType().InvokeMember("OpenDatabase", "InvokeMethod", $null, $WindowsInstaller, @($strMSIFullName, 0))
    $Query = "SELECT Value FROM Property WHERE Property = 'ProductCode'"
    $View = $MSIDatabase.GetType().InvokeMember("OpenView", "InvokeMethod", $null, $MSIDatabase, ($Query))
    $View.GetType().InvokeMember("Execute", "InvokeMethod", $null, $View, $null)
    $Record = $View.GetType().InvokeMember("Fetch", "InvokeMethod", $null, $View, $null)
    $Value = $Record.GetType().InvokeMember("StringData", "GetProperty", $null, $Record, 1)
 
    # Commit database and close view
    $MSIDatabase.GetType().InvokeMember("Commit", "InvokeMethod", $null, $MSIDatabase, $null)
    $View.GetType().InvokeMember("Close", "InvokeMethod", $null, $View, $null)           
    $MSIDatabase = $null
    $View = $null
 
    $bolReturn = $false
    $strMSIName = $strMSIFullName.SubString(($strMSIFullName.LastIndexOf("\") + 1), ($strMSIFullName.Length - ($strMSIFullName.LastIndexOf("\") + 1)))
    $DestFolderCollection = Invoke-CommandWithRetry -ComputerName $strComputerName -ScriptBlock { Get-Item env:TEMP }
    $LocalMSI = Join-Path $DestFolderCollection.Value $strMSIName
    $DestFolder = Join-Path \\$strComputerName $DestFolderCollection.Value
    $DestFolder = $DestFolder -replace ":", "$"
    $strLogFile = $DestFolderCollection.Value + "\" + $strMSIName.Replace(".msi", ".uninstall.log")
    $strUNCInstallScript	= $DestFolder + "\" + $strMSIName.Replace(".msi", ".cmd")
    $strLocalInstallScript	= $DestFolderCollection.Value + "\" + $strMSIName.Replace(".msi", ".cmd")
    $strAllParameters = "/qn /lvx " + [char]34 + $strLogFile + [char]34
    $strUNCLogFileName = $DestFolder + "\" + $strMSIName.Replace(".msi", ".uninstall.log")
    $strUNCMSIName = Join-Path $DestFolder $strMSIName

    if (Test-Path $strUNCInstallScript) {
        Write-Host "Removing:  " $strUNCInstallScript
        Remove-Item $strUNCInstallScript -force
    }
    if (Test-Path $strUNCLogFileName) {
        Write-Host "Removing:  " $strUNCLogFileName
        Remove-Item $strUNCLogFileName -force
    }
    if (Test-Path $strUNCMSIName) {
        Write-Host "Removing:  " $strUNCMSIName
        Remove-Item $strUNCMSIName -force
    }
    if ((Test-Path $strUNCInstallScript) -or (Test-Path $strUNCLogFileName) -or (Test-Path $strUNCMSIName)) {
        Write-Host "ERROR: Temporary installation script exists..."
    }
    else {
        Copy-Item "$strMSIFullName" "$DestFolder" -Verbose | Out-Host
        Write-Host "Uninstalling:" $strMSIFullName
        Write-Host "msiexec /x " $Value " " $strAllParameters
        $Stream = [System.IO.StreamWriter] $strUNCInstallScript
        $Stream.WriteLine("msiexec /x " + $Value + " " + $strAllParameters)
        $Stream.Close()
        $Script = "&$strLocalInstallScript"
        $ScriptBlock = $executioncontext.invokecommand.NewScriptBlock($Script)
        $Result = Invoke-Command -ComputerName $strComputerName -ScriptBlock $ScriptBlock
        Start-Sleep -Seconds 10
        if (Test-Path $strUNCLogFileName) {
            $bolExtraAnalysis = $false
            $WiLogUtl = $WiLogUtlPath
            if (Test-Path $WiLogUtl) {
                $bolExtraAnalysis = $true
                Write-Host "[WiLogUtl] WiLogUtl has been detected, additional analysis of the MSI log will be performed..."
                $dateRev = GetDateReverse
                $outputFolder = $MSILogsRoot + "\" + $dateRev + "_" + $EnvironmentName + "_" + $strMSIName.Replace(".msi", "") + "_Remove"
                write-host "[WiLogUtl] Output folder:" $outputFolder
                $capture = New-Item -ItemType directory -Path $outputFolder | Out-Null
                . $WiLogUtl /q /l $strUNCLogFileName /o $outputFolder
                Start-Sleep -Seconds 10
            }
            Write-Host "Checking:  " $strUNCLogFileName
            $LogContent = Get-Content $strUNCLogFileName
            $bolLogCheck01 = $false
            $bolLogCheck02 = $false
            foreach ($strLine in $LogContent) {
                if ($strLine.Contains("-- Removal completed successfully.") -or $strLine.Contains("-- Removal operation completed successfully.")) {
                    Write-Host "Detected:  " $strLine
                    $bolLogCheck01 = $true
                }
                if ($strLine.Contains("Windows Installer removed the product.") -and $strLine.Contains("success or error status: 0.")) {
                    Write-Host "Detected:  " $strLine
                    $bolLogCheck02 = $true
                }
            }
            if ($bolLogCheck01 -and $bolLogCheck02) {
                Write-Host "Apparently the MSI has been removed, cleaning up temp files..."
                $bolReturn = $true
                Remove-Item $strUNCInstallScript -force
                Remove-Item $strUNCMSIName -force
                if ((Test-Path $strUNCInstallScript) -or (Test-Path $strUNCMSIName)) {
                    Write-Host "ERROR: Error during the tidy up stage..."
                }
            }
            else {
                Write-Host "Success criteria couldn't be found in the MSI log file..."
                if ($bolExtraAnalysis) {
                    $oErrorsFile = Get-ChildItem -Path $outputFolder -Filter "*_Errors.txt"
                    write-host "[WiLogUtl] Importing" $oErrorsFile.FullName
                    $errors = Get-Content $oErrorsFile.FullName
                    foreach ($strLine in $errors) {
                        if ($strLine.Trim().Length -gt 0) {
                            Write-Host "          " $strLine
                        }
                    }
                    $errors = $null
                }
            }
        }
        else {
            Write-Host "ERROR: Can't find log file to check..."
        }
    }

    return $bolReturn
}

	
function InstallMSI([string] $strComputerName, [string] $strMSIFullName, $arrParameters) {
    $bolReturn = $false
    $strMSIName = $strMSIFullName.SubString(($strMSIFullName.LastIndexOf("\") + 1), ($strMSIFullName.Length - ($strMSIFullName.LastIndexOf("\") + 1)))
    $DestFolderCollection = Invoke-CommandWithRetry -ComputerName $strComputerName -ScriptBlock { Get-Item env:TEMP }
    $LocalMSI = Join-Path $DestFolderCollection.Value $strMSIName
    $DestFolder = Join-Path \\$strComputerName $DestFolderCollection.Value
    $DestFolder = $DestFolder -replace ":", "$"
    $strLogFile = $DestFolderCollection.Value + "\" + $strMSIName.Replace(".msi", ".log")
    $strUNCInstallScript	= $DestFolder + "\" + $strMSIName.Replace(".msi", ".cmd")
    $strLocalInstallScript	= $DestFolderCollection.Value + "\" + $strMSIName.Replace(".msi", ".cmd")
    $strAllParameters = "/qn /lvx " + [char]34 + $strLogFile + [char]34
    $strUNCLogFileName = $DestFolder + "\" + $strMSIName.Replace(".msi", ".log")
    $strUNCMSIName = Join-Path $DestFolder $strMSIName
    if ($arrParameters.Count -gt 0) {
        Write-Host "[InstallMSI] Attempting to install:" $strMSIFullName "on:" $strComputerName "with the following parameters:"
        
        foreach ($strParameter in $arrParameters) {
            Write-Host "    " (Format-ParameterForLogging -Parameter $strParameter)
            $strAllParameters = $strAllParameters + " " + $strParameter.replace('%','%%')
        }
    }
    else {
        Write-Host "[InstallMSI] Attempting to install:" $strMSIFullName "on:" $strComputerName
    }
    $cmdLine = "msiexec /i " + $LocalMSI + " " + $strAllParameters
    if (Test-Path $strUNCInstallScript) {
        Write-Host "[InstallMSI] Removing:  " $strUNCInstallScript
        Remove-Item $strUNCInstallScript -force
    }
    if (Test-Path $strUNCLogFileName) {
        Write-Host "[InstallMSI] Removing:  " $strUNCLogFileName
        Remove-Item $strUNCLogFileName -force
    }
    if (Test-Path $strUNCMSIName) {
        Write-Host "[InstallMSI] Removing:  " $strUNCMSIName
        Remove-Item $strUNCMSIName -force
    }
    if ((Test-Path $strUNCInstallScript) -or (Test-Path $strUNCLogFileName) -or (Test-Path $strUNCMSIName)) {
        Write-Host "[InstallMSI] ERROR: Temporary installation script exists..."
    }
    elseif ($cmdLine.Length -gt 8191) { 
        write-host "[InstallMSI] ERROR: Command line is too long:" $cmdLine.Length
    }
    else {
        Write-Host "[InstallMSI] command line length:" $cmdLine.Length
        Write-Host "[InstallMSI] Copying installer..."
        Copy-Item "$strMSIFullName" "$DestFolder" | Out-Host
        Write-Host "[InstallMSI] Installing:" $strMSIFullName
        $isCitrix = (Check-IsCitrixServer -compName $strComputerName)
        if ($isCitrix) { Write-Host "[InstallMSI] Adding Citrix parameters..." }
        $Stream = [System.IO.StreamWriter] $strUNCInstallScript
        if ($isCitrix) { $Stream.WriteLine("change user /install") }
        $Stream.WriteLine($cmdLine)
        if ($isCitrix) { $Stream.WriteLine("change user /execute") }
        $Stream.Close()
        
        $Result = [System.Object]
        
        Write-Host "[InstallMSI] Checking CredSSP Status..."
        $Password = $DeploymentServiceAccountPassword | ConvertTo-SecureString -asPlainText -Force 
        $Credential = New-Object System.Management.Automation.PSCredential($DeploymentServiceAccount,$Password)

        try {
            $CredSSPEnabled = (Get-DorcCredSSPStatus -ComputerName $strComputerName -Credential $Credential -Test -ErrorAction Stop).CredSSPWorks
        }
        catch {
            Write-Warning -Message "Failed to determine CredSSP status of [$strComputerName] - this is expected on hosts with PowerShell 2.0; full exception:`n$_"
            $CredSSPEnabled = $false
        }
        
        if ($CredSSPEnabled -eq $true) {
            Write-Host "[InstallMSI] Performing CredSSP authentication installation..."
            try {
                 $Result = Invoke-Command -ComputerName $strComputerName -ScriptBlock { Start-Process -FilePath $using:strLocalInstallScript -Verb runAs -Wait } -Authentication CredSSP -Credential $Credential -ErrorAction Stop
            }
            catch {
                Throw "[InstallMSI] Failed to establish remote PS session to $strComputerName using CredSSP authentication."
            }
        }
        else {
            Write-Host "[InstallMSI] Performing double hop authentication installation..."
            $Script = "&$strLocalInstallScript"
            $ScriptBlock = $executioncontext.invokecommand.NewScriptBlock($Script)

            $Result = Invoke-Command -ComputerName $strComputerName -ScriptBlock $ScriptBlock
        }

        Start-Sleep -Seconds 10
        if (Test-Path $strUNCLogFileName) {
            $bolExtraAnalysis = $false
            $WiLogUtl = $WiLogUtlPath
            if (Test-Path $WiLogUtl) {
                $bolExtraAnalysis = $true
                Write-Host "[WiLogUtl] WiLogUtl has been detected, additional analysis of the MSI log will be performed..."
                $dateRev = GetDateReverse
                $outputFolder = $MSILogsRoot + "\" + $(get-date -Format "yyyy-MM-dd_HH-mm-ss-ms") + "_" + $EnvironmentName + "_" + $strMSIName.Replace(".msi", "")
                write-host "[WiLogUtl] Output folder:" $outputFolder
                $capture = New-Item -ItemType directory -Path $outputFolder | Out-Null
                . $WiLogUtl /q /l $strUNCLogFileName /o $outputFolder
                Start-Sleep -Seconds 10
            }
            Write-Host "[InstallMSI] Checking:  " $strUNCLogFileName
            $LogContent = Get-Content $strUNCLogFileName
            $bolLogCheck01 = $false
            $bolLogCheck02 = $false
            foreach ($strLine in $LogContent) {
                if ($strLine.Contains("-- Installation completed successfully.") -or $strLine.Contains("-- Installation operation completed successfully.") -or $strLine.Contains("-- Configuration completed successfully") ) {
                    Write-Host "[InstallMSI] Detected:  " $strLine
                    $bolLogCheck01 = $true
                }
                if (($strLine.Contains("Windows Installer installed the product.") -and $strLine.Contains("Installation success or error status: 0."))`
                -or ($strLine.Contains("Windows Installer reconfigured the product.") -and $strLine.Contains("Reconfiguration success or error status: 0."))) {
                    Write-Host "[InstallMSI] Detected:  " $strLine
                    $bolLogCheck02 = $true
                }
            }
            if ($bolLogCheck01 -and $bolLogCheck02) {
                Write-Host "[InstallMSI] Apparently the MSI has installed, cleaning up temp files..."
                $bolReturn = $true
                Remove-Item $strUNCInstallScript -force
                Remove-Item $strUNCMSIName -force
                if ((Test-Path $strUNCInstallScript) -or (Test-Path $strUNCMSIName)) {
                    Write-Host "[InstallMSI] ERROR: Error during the tidy up stage..."
                }
            }
            else {
                Write-Host "[InstallMSI] Success criteria couldn't be found in the MSI log file..."
                if ($bolExtraAnalysis) {
                    $oErrorsFile = Get-ChildItem -Path $outputFolder -Filter "*_Errors.txt"
                    write-host "[WiLogUtl] Importing" $oErrorsFile.FullName
                    $errors = Get-Content $oErrorsFile.FullName
                    foreach ($strLine in $errors) {
                        if ($strLine.Trim().Length -gt 0) {
                            Write-Host "          " $strLine
                        }
                    }
                    $errors = $null
                }
            }
        }
        else {
            Write-Host "[InstallMSI] ERROR: Can't find log file to check..."
        }
    }
    return $bolReturn
}

function GACAdder([string] $strAction, [string] $strServer, [string] $strLibrary) {
    $strGACFunction = $null
    switch ($strAction) {
        "Install" { $strGACFunction = "GacInstall" }
        "Remove" { $strGACFunction = "GacRemove" }
    }
    $Script = @"
    Add-Type -AssemblyName "System.EnterpriseServices";
    [System.EnterpriseServices.Internal.Publish];
    `$publish = New-Object System.EnterpriseServices.Internal.Publish;
    `$publish.$strGACFunction('$strLibrary')
"@
    $ScriptBlock = $executioncontext.invokecommand.NewScriptBlock($Script)
    $Result = Invoke-Command -ComputerName $strServer -ScriptBlock $ScriptBlock | Out-Host
    Write-Host $Result
}

function GetDbInfoByTypeForEnv([string] $strEnvironment, [string] $strType) {
    $DOrcToken = Get-DorcToken 
    $DorcAPIHeaders = @{
        "Authorization" = "Bearer $DOrcToken" 
    }
    $uri=$RefDataApiUrl + 'RefDataEnvironments?env=' + $strEnvironment
    $EnvId=(Invoke-RestMethod -Uri $uri -method Get -Headers $DorcAPIHeaders -ContentType 'application/json').EnvironmentId
    $uri=$RefDataApiUrl + 'RefDataEnvironmentsDetails/' + $EnvId
    $table=Invoke-RestMethod -Uri $uri -method Get -Headers $DorcAPIHeaders -ContentType 'application/json'
    $table=$table.DbServers | where {$_.Type -eq $strType} | Select Name, ServerName
    $strResult="Invalid"
    if ($table.Name.count -eq 0) {
        Write-Host "No entries returned for $strEnvironment $strType"
    }
    elseif ($table.Name.Count -eq 1) {
            $strResult = $table.ServerName + ":" + $table.Name
    }
    else {
        throw "Too many entries for $strEnvironment $strType"
    }
    return $strResult
}

function GetLatestBackupForDb([string] $strInstance, [string] $strDatabase) {
    $strResult = "Invalid"
    $connection = New-Object System.Data.SqlClient.SqlConnection
    $connection.ConnectionString = "Server=$strInstance;Database=master;Integrated Security=true"
    $connection.Open()
    $command = $connection.CreateCommand()
    
    $command.CommandText = @"
    USE master 
    SELECT TOP 1 
        msdb.dbo.backupset.database_name,
        msdb.dbo.backupset.backup_start_date,
        msdb.dbo.backupset.backup_finish_date,
        msdb.dbo.backupset.expiration_date,
        CASE msdb.dbo.backupset.type 
            WHEN 'D' THEN 'Database' 
            WHEN 'I' THEN 'Differential' 
            WHEN 'L' THEN 'Log' 
        END AS backup_type,
        msdb.dbo.backupset.backup_size,
        msdb.dbo.backupmediafamily.logical_device_name,
        msdb.dbo.backupmediafamily.physical_device_name,
        msdb.dbo.backupset.name AS backupset_name,
        msdb.dbo.backupset.description,
        msdb.dbo.backupset.differential_base_guid
    FROM 
        msdb.dbo.backupmediafamily
    INNER JOIN 
        msdb.dbo.backupset 
    ON 
        msdb.dbo.backupmediafamily.media_set_id = msdb.dbo.backupset.media_set_id 
    WHERE 
        msdb.dbo.backupset.database_name = @DatabaseName
    AND 
        (CONVERT(datetime, msdb.dbo.backupset.backup_start_date, 102) >= GETDATE() - 21)
    AND 
        (msdb.dbo.backupset.type = 'D' OR msdb.dbo.backupset.type = 'I')
    ORDER BY 
        msdb.dbo.backupset.database_name, 
        msdb.dbo.backupset.backup_finish_date DESC
"@
    $command.Parameters.AddWithValue("@DatabaseName", $strDatabase)

    $table = new-object "System.Data.DataTable"
    $table.Load($command.ExecuteReader())
    $connection.Close()
    if ($table.Rows.Count -eq 0) {
        Write-Host "No entries returned for $strInstance $strDatabase"
    }
    else {
        foreach ($Row in $table.Rows) {
            $strResult = $Row.Item("physical_device_name")
        }
    }
    return $strResult
}

function SsasRemoveDatabase([string] $strInstance, [string] $strDatabase, [bool] $bolPartialNameMatch) {
    [Void][System.reflection.Assembly]::LoadWithPartialName("Microsoft.AnalysisServices")
    $svr = new-Object Microsoft.AnalysisServices.Server
    $svr.Connect($strInstance)
    $arrDbsToDrop = New-Object System.Collections.ArrayList($null) 
    foreach ($db in $svr.Databases) {	
        if ($bolPartialNameMatch -eq $false -and $db.Name -eq $strDatabase) {
            [Void]$arrDbsToDrop.add($db.Name)
        }
        if ($bolPartialNameMatch -eq $true -and $db.Name.Contains($strDatabase)) {
            [Void]$arrDbsToDrop.add($db.Name)
        }
    }
    $svr.Disconnect()
    foreach ($strDb in $arrDbsToDrop) {
        $svr.Connect($strInstance)
        $db = $svr.Databases[$strDb]
        Write-Host "Dropping:" $db.Name
        $db.drop()
        $svr.Disconnect()
    }
}

function SsasPermissionDatabase([string] $strInstance, [string] $strDatabase, [bool] $bolPartialNameMatch, [string] $strRole, [string] $strAccount) {
    [Void][System.reflection.Assembly]::LoadWithPartialName("Microsoft.AnalysisServices")
    $svr = new-Object Microsoft.AnalysisServices.Server
    [Microsoft.AnalysisServices.Role] $SSASRole = new-Object([Microsoft.AnalysisServices.Role])($strRole)
    $svr.Connect($strInstance)
    $arrDbsToPermission = New-Object System.Collections.ArrayList($null) 
    foreach ($db in $svr.Databases) {	
        if ($bolPartialNameMatch -eq $false -and $db.Name -eq $strDatabase) {
            [Void]$arrDbsToPermission.add($db.Name)
        }
        if ($bolPartialNameMatch -eq $true -and $db.Name.Contains($strDatabase)) {
            [Void]$arrDbsToPermission.add($db.Name)
        }
    }
    $svr.Disconnect()
    foreach ($strDb in $arrDbsToPermission) {
        $svr.Connect($strInstance)
        $db = $svr.Databases[$strDb]
        Write-Host "Setting roles on:" $strInstance":"$db.Name
        foreach ($DatabaseRole in $db.Roles) {
            if ($DatabaseRole.Name -eq $strRole) {
                Write-Host "Setting up role:" $DatabaseRole.Name
                Write-Host "         Adding:" $strAccount
                $newRole = New-Object Microsoft.AnalysisServices.RoleMember($strAccount)
                if ($DatabaseRole.Members.Name) {
                    if ($DatabaseRole.Members.Name.Contains($strAccount.ToUpper())) {
                        Write-Host "Account" $strAccount "already exists in role Process"
                    }				
                    else {
                        $DatabaseRole.Members.Add($newRole)
                        $DatabaseRole.Update()
                        $dbperm = $db.DatabasePermissions.FindByRole($DatabaseRole.ID)
                        $dbperm.ReadDefinition = [Microsoft.AnalysisServices.ReadDefinitionAccess]::Allowed
                        $dbperm.Update()
                        $db.Update()
                    }
                }
                else {
                    $DatabaseRole.Members.Add($newRole)
                    $DatabaseRole.Update()
                    $dbperm = $db.DatabasePermissions.FindByRole($DatabaseRole.ID)
                    $dbperm.ReadDefinition = [Microsoft.AnalysisServices.ReadDefinitionAccess]::Allowed
                    $dbperm.Update()
                    $db.Update()
                }
            }
        }
        $svr.Disconnect()
    }
}

function GetDBStatus([string] $strInstance, [string] $strDatabase) {	
    [Void][System.Reflection.Assembly]::LoadWithPartialName('Microsoft.SqlServer.SMO')
    $serverInstance = New-Object ('Microsoft.SqlServer.Management.Smo.Server') $strInstance
    try {
        $strStatus = $serverInstance.Databases[$strDatabase].Status
    }
    Catch { [system.exception] }
    return $strStatus
}

function Get-TSSessions([string] $strComputerName) {
    qwinsta /server:$strComputerName |
        #Parse output
    ForEach-Object {
        $_.Trim() -replace "\s+", ","
    } |
        #Convert to objects
    ConvertFrom-Csv
}

function LogOffUsers([string] $strComputerName) {
    $Sessions = Get-TSSessions $strComputerName
    foreach ($Session in $Sessions|where {$_.SESSIONNAME.ToString().StartsWith("rdp-tcp") -and ($_.STATE -eq "Active")}) {
        Write-Host "Logging off user:" $Session.username
        rwinsta $Session.ID /server:$strComputerName
    }
}

function DeleteRabbit([string]$mode, [string[]]$deleteStrings, [string]$RabbitUserName, [string]$RabbitPassword, [string]$RabbitAPIPort, [string] $Server, [bool]$discardMessages = $false) {
    $exitCode = 0

    trap {
        $e = $error[0].Exception
        $e.Message
        $e.StackTrace
    }
    $protocol = "http"
    $UnEscapeDotsAndSlashes = 0x2000000
	 
    # GetSyntax method, which is static internal, gets registered parsers for given protocol
    $getSyntax = [System.UriParser].GetMethod("GetSyntax", 40)
    # field m_Flags contains information about Uri parsing behaviour
    $flags = [System.UriParser].GetField("m_Flags", 36)
	 
    $parser = $getSyntax.Invoke($null, $protocol)
    $currentValue = $flags.GetValue($parser)
    # check if un-escaping enabled
    if (($currentValue -band $UnEscapeDotsAndSlashes) -eq $UnEscapeDotsAndSlashes) {
        $newValue = $currentValue -bxor $UnEscapeDotsAndSlashes
        # disable unescaping by removing UnEscapeDotsAndSlashes flag
        $flags.SetValue($parser, $newValue)
    }

    $secpasswd = ConvertTo-SecureString $RabbitPassword -AsPlainText -Force
    $Credentials = New-Object System.Management.Automation.PSCredential ($RabbitUserName, $secpasswd)

    Add-Type -AssemblyName System.Web   

    foreach ($deleteString in $deleteStrings) {
        if ($mode -eq 'exchange') {
            $url = "http://$([System.Web.HttpUtility]::UrlEncode($Server)):$([System.Web.HttpUtility]::UrlEncode($RabbitAPIPort))/api/exchanges/%2f/"

            $exchanges = Invoke-RestMethod $url -Credential $Credentials -DisableKeepAlive -ErrorAction Continue -Method Get
            $deleteExchanges = @()

            foreach ($exchange in $exchanges | where {-not ($_.name.Contains('amq.'))}) {	
                if ($deleteString.Length -gt 0) {
                    if ($exchange.name.Contains($deleteString)) {
                        $deleteExchanges += $exchange
                    }
                }
                else {
                    if ($exchange.name.Length -gt 0) {
                        $deleteExchanges += $exchange
                    }
                }
            }

            foreach ($deleteExchange in $deleteExchanges) {
                Write-Host "Deleting exchange: " $deleteExchange.name
                $url = "http://$([System.Web.HttpUtility]::UrlEncode($Server)):$([System.Web.HttpUtility]::UrlEncode($RabbitAPIPort))/api/exchanges/%2f/$([System.Web.HttpUtility]::UrlEncode($deleteExchange.name))"
                Write-Host "Invoking Rest api URL: " $url
                $result = Invoke-RestMethod $url -Credential $Credentials -DisableKeepAlive -ErrorAction Continue -Method Delete -ContentType "application/json" -Body $bodyJson
                Write-Host "Deleted exchange: " $deleteExchange.name
            }
        }
        elseif ($mode = 'queue') {
            $url = "http://$([System.Web.HttpUtility]::UrlEncode($Server)):$([System.Web.HttpUtility]::UrlEncode($RabbitAPIPort))/api/queues/%2f/"

            $queues = Invoke-RestMethod $url -Credential $Credentials -DisableKeepAlive -ErrorAction Continue -Method Get
            $deleteQueues = @()
			
            foreach ($queue in $queues) {
                if ($deleteString.Length -gt 0) {
                    if ($queue.name.Contains($deleteString)) {
                        $deleteQueues += $queue
                    }
                }
                else {
                    $deleteQueues += $queue
                }
            }
			
            foreach ($deleteQueue in $deleteQueues) {
                Write-Host "Deleting queue: " $deleteQueue.name
				
                $url = "http://$([System.Web.HttpUtility]::UrlEncode($Server)):$([System.Web.HttpUtility]::UrlEncode($RabbitAPIPort))/api/queues/%2f/$([System.Web.HttpUtility]::UrlEncode($deleteQueue.name))"
                Write-Host "Invoking Rest api URL: " $url
				
                $queueDetails = Invoke-RestMethod $url -Credential $Credentials -DisableKeepAlive -ErrorAction Continue -Method Get
				
                if (($queueDetails.messages -gt 0) -and $discardMessages) {
                    Write-Host "Warning: Messages found on " $deleteQueue.name " but discard messages set, messages will be deleted"
                    $result = Invoke-RestMethod $url -Credential $Credentials -DisableKeepAlive -ErrorAction Continue -Method Delete -ContentType "application/json" -Body $bodyJson
                    Write-Host "Deleted queue: " $deleteQueue.name		
                }
                elseif (($queueDetails.messages -gt 0) -and -not($discardMessages)) {
                    Write-Host "Warning: cannot delete " $deleteQueue.name " as it has messages on it"
                }
                else {
                    $result = Invoke-RestMethod $url -Credential $Credentials -DisableKeepAlive -ErrorAction Continue -Method Delete -ContentType "application/json" -Body $bodyJson	
                    Write-Host "Deleted queue: " $deleteQueue.name		
                }
            }
        }
    }
}

function ConfigureRabbit([string] $XMLConfigFile, [string] $RabbitUserName, [string] $RabbitPassword, [string] $RabbitAPIPort, [string] $Server, [bool] $discardMessages) {
    $exitCode = 0
    trap {
        $e = $error[0].Exception
        $e.Message
        $e.StackTrace
    }
    $protocol = "http"
    $UnEscapeDotsAndSlashes = 0x2000000

    # GetSyntax method, which is static internal, gets registered parsers for given protocol
    $getSyntax = [System.UriParser].GetMethod("GetSyntax", 40)
    # field m_Flags contains information about Uri parsing behaviour
    $flags = [System.UriParser].GetField("m_Flags", 36)
  
    $parser = $getSyntax.Invoke($null, $protocol)
    $currentValue = $flags.GetValue($parser)
    
    # check if un-escaping enabled
    if (($currentValue -band $UnEscapeDotsAndSlashes) -eq $UnEscapeDotsAndSlashes) {
        $newValue = $currentValue -bxor $UnEscapeDotsAndSlashes
        # disable unescaping by removing UnEscapeDotsAndSlashes flag
        $flags.SetValue($parser, $newValue)
    }

    $secpasswd = ConvertTo-SecureString $RabbitPassword -AsPlainText -Force
    $Credentials = New-Object System.Management.Automation.PSCredential ($RabbitUserName, $secpasswd)
    
    [xml]$config = Get-Content $XMLConfigFile
    $excahnges = $config.FirstChild.Exchanges
    $queues = $config.FirstChild.Queues
    $bindings = $config.FirstChild.Bindings

    Add-Type -AssemblyName System.Web   

    # Exchange section
    foreach ($exchange in $excahnges.ChildNodes) {
        $name = $exchange.name
        
        $body = @{
            type = $exchange.type
        }

        if ($exchange.durable -eq "true") { $body.Add("durable", $true) }      
        if ($exchange.auto_delete -eq "true") { $body.Add("auto_delete", $true) }
        if ($exchange.internal -eq "true") { $body.Add("internal", $true) }    
        
        $bodyJson = $body | ConvertTo-Json
        
        # Check for existing exchanges
        $exchangeCheckUrl = "http://$([System.Web.HttpUtility]::UrlEncode($Server)):$([System.Web.HttpUtility]::UrlEncode($RabbitAPIPort))/api/exchanges/%2f/"
        $existingExchanges = Invoke-RestMethod $exchangeCheckUrl -Credential $Credentials -DisableKeepAlive -ErrorAction Continue -Method Get
        
        $url = "http://$([System.Web.HttpUtility]::UrlEncode($Server)):$([System.Web.HttpUtility]::UrlEncode($RabbitAPIPort))/api/exchanges/%2f/$([System.Web.HttpUtility]::UrlEncode($name))"
        
        Write-Host "Invoking REST API: $url"
        
        # Delete existing exchange if exists
        foreach ($existingExchange in $existingExchanges | where {$_.name -eq $exchange.name}) {
            Write-Host "Warning: Exchange " $exchange.name " already exists. Deleting"
            $result = Invoke-RestMethod $url -Credential $Credentials -DisableKeepAlive -ErrorAction Continue -Method Delete -ContentType "application/json" -Body $bodyJson
        }

        # Create or update exchange
        $result = Invoke-RestMethod $url -Credential $Credentials -DisableKeepAlive -ErrorAction Continue -Method Put -ContentType "application/json" -Body $bodyJson

        Write-Host 'Created exchange: ' $exchange.name
    }

    # Queues section
    foreach ($queue in $queues.ChildNodes) {
        $name = $queue.name
        
        $body = @{}
        $arguments = @{}
        
        [Long]$ttl = 0
        $ttl = $queue.message_ttl

        if ($queue.durable -eq "true") { $body.Add("durable", $true) }      
        if ($queue.auto_delete -eq "true") { $body.Add("auto_delete", $true) }
        if ($ttl -gt 0) { 
            $arguments.Add("x-message-ttl", $ttl)
            $body.Add("arguments", $arguments)
        }
        
        $bodyJson = $body | ConvertTo-Json -Compress
        
        # URL for queue
        $url = "http://$([System.Web.HttpUtility]::UrlEncode($Server)):$([System.Web.HttpUtility]::UrlEncode($RabbitAPIPort))/api/queues/%2f/$([System.Web.HttpUtility]::UrlEncode($name))"
        
        Write-Host "Invoking REST API: $url"
        
        # Check for existing queues
        $queueCheckUrl = "http://$([System.Web.HttpUtility]::UrlEncode($Server)):$([System.Web.HttpUtility]::UrlEncode($RabbitAPIPort))/api/queues/%2f/"
        $existingQueues = Invoke-RestMethod $queueCheckUrl -Credential $Credentials -DisableKeepAlive -ErrorAction Continue -Method Get

        $queueExists = $existingQueues | Where-Object { $_.name -eq $queue.name }
        
        if ($queueExists) {
            $queueDetails = Invoke-RestMethod $url -Credential $Credentials -DisableKeepAlive -ErrorAction Continue -Method Get
            
            # Check if queue has messages
            if (($queueDetails.messages -gt 0) -and $discardMessages) {
                Write-Host "Warning: Messages found on $name, but discard messages set. Messages will be deleted."
                $result = Invoke-RestMethod $url -Credential $Credentials -DisableKeepAlive -ErrorAction Continue -Method Delete -ContentType "application/json" -Body $bodyJson
                Write-Host "Deleted queue: $name"
            }
            elseif (($queueDetails.messages -gt 0) -and -not($discardMessages)) {
                Write-Host "Warning: cannot delete $name as it has messages."
                Write-Host "Warning: Will not attempt to create queue $name"
                continue
            }
            else {
                $result = Invoke-RestMethod $url -Credential $Credentials -DisableKeepAlive -ErrorAction Continue -Method Delete -ContentType "application/json" -Body $bodyJson	
                Write-Host "Deleted queue: $name"
            }
        }

        # Create or update queue
        $result = Invoke-RestMethod $url -Credential $Credentials -DisableKeepAlive -ErrorAction Continue -Method Put -ContentType "application/json" -Body $bodyJson
        
        Write-Host 'Created queue:' $name
    }

    # Bindings section
    foreach ($binding in $bindings.ChildNodes) {
        $name = $binding.destination
        $exchangeName = $binding.source
        $url = "http://$([System.Web.HttpUtility]::UrlEncode($Server)):$([System.Web.HttpUtility]::UrlEncode($RabbitAPIPort))/api/bindings/%2f/e/$([System.Web.HttpUtility]::UrlEncode($exchangeName))/q/$([System.Web.HttpUtility]::UrlEncode($name))"
        
        $body = @{
            "routing_key" = $binding.routingKey
        }

        $bodyJson = $body | ConvertTo-Json -Compress

        Write-Host "Invoking REST API: $url"
		
        $result = Invoke-RestMethod $url -Credential $Credentials -DisableKeepAlive -ErrorAction Continue -Method Post -ContentType "application/json" -Body $bodyJson
        
        Write-Host 'Created binding: ' $binding.source --- $binding.destination
    }
}

function Stop-Services {
    [CmdLetBinding()]
    param (
        $arrServiceList, 
        [string] $strComputer, 
        [int] $retryCount = 10,
		[int] $retryTime = 10
    )
    foreach ($strService in $arrServiceList) { 
        $strRemServiceName = $null
        $strRemServiceStatus = $null
        $strServiceNameGen = $strService + "*"
        $oService = Invoke-Command -ComputerName $strComputer -ScriptBlock { param($svc) Get-Service $svc } -ArgumentList $strServiceNameGen | Select-Object -First 1 #ensure only 1 service processed at a time
        $strRemServiceName = $oService.Name
        $strRemServiceStatus = $oService.Status
        $oService = $null
        
        if ($strRemServiceName -eq $strService) {
            if ($strRemServiceStatus -eq "Running") {
                Write-Host "    Stopping" $strService "on" $strComputer
                for ($i = 0; $i -le $retryCount; $i++) {
                    write-host "      Attempt to stop number:" ($i + 1)
                    Invoke-Command -ComputerName $strComputer { param($strService) Stop-Service $strService -Force} -Args $strService
                    Start-Sleep $retryTime
                    $oService = Invoke-Command -ComputerName $strComputer -ScriptBlock { param($svc) Get-Service $svc } -ArgumentList $strRemServiceName
                    $strRemServiceStatus = $oService.Status
                    if ($strRemServiceStatus -eq "Stopped") {break}
                    if ($i -eq $retryCount) {
                        $ServicePID = $null
                        $ServicePID = (Get-CimInstance -ClassName Win32_Service -ComputerName $strComputer -Filter "Name='$strService'").ProcessId
                        write-host "      Killing PID:" $ServicePID
                        Invoke-Command -ComputerName $strComputer {param($ServicePID) Stop-Process $ServicePID -Force} -Args $ServicePID -ErrorAction SilentlyContinue
                    }
                }
                $oService = Invoke-Command -ComputerName $strComputer -ScriptBlock { param($svc) Get-Service $svc } -ArgumentList $strRemServiceName
                $strRemServiceStatus = $oService.Status
                if ($strRemServiceStatus -ne "Stopped") {throw "    " + $strRemServiceName + "is still" + $oService.Status}
                else {write-host "   "$strRemServiceName "has been stopped"}
            }
            else {
                Write-Host "   "$strService "on" $strComputer "is" $strRemServiceStatus", nothing to do..."
            }
        }
        else {
            Write-Host "    WARNING:" $strService "is not installed on" $strComputer
        }
    }
}

function StartServices($arrServiceList, [string] $strComputer) {
    foreach ($strService in $arrServiceList) {
        $strRemServiceName = $null
        $strRemServiceStatus = $null
        $strServiceNameGen = $strService + "*"
        $oService = Invoke-Command -ComputerName $strComputer -ScriptBlock { param($svc) Get-Service $svc } -ArgumentList $strServiceNameGen
        $strRemServiceName = $oService.Name
        $strRemServiceStatus = $oService.Status
        $oService = $null
        if ($strRemServiceName -eq $strService) {
            if ($strRemServiceStatus -eq "Stopped") {
                Write-Host "    Starting" $strService "on" $strComputer
                Invoke-Command -ComputerName $strComputer -ScriptBlock { param($svc) Start-Service $svc } -ArgumentList $strService -ErrorAction Stop
                start-sleep -Seconds 5
                For ($i=0; $i -le 10; $i++) {
                    $oService = Invoke-Command -ComputerName $strComputer -ScriptBlock { param($svc) Get-Service $svc } -ArgumentList $strServiceNameGen
                    $strRemServiceStatus = $oService.Status
                    If ($strRemServiceStatus -eq "Running") {write-host "Running";break}
                    Write-Host "    wait 10 seconds"
                    start-sleep -Seconds 10
                    if ($i -eq 9) {throw " $strService can't be Started"}
                }
                write-host "    $strService is Started"
            }
            else {
                Write-Host "   "$strService "on" $strComputer "is" $strRemServiceStatus", won't attempt to start..."
            }
        }
        else {
            throw "    ERROR: $strService is not installed on $strComputer"
        }
    }
}

function RunMTMTests($arrParameters) {
    $bolReturn = $false
    if ($arrParameters.Count -gt 0) {
        foreach ($strParameter in $arrParameters) {
            $parameterName = $strParameter.Split("=")[0]
            $parameterValue = $strParameter.Split("=")[1]
            
            $safeDisplay = Format-ParameterForLogging -Parameter $strParameter
            Write-Host "Setting $safeDisplay"
            
            Set-Variable -Name $parameterName -Value $parameterValue
        }
        ## Sync
        $UpdateParams = " testcase /import /collection:" + $TFSInstance + " /teamproject:" + $TFSTeamProject + " /storage:" + $TestDll + " /syncsuite:" + $TestSuite
        $ProcessInfo = New-Object System.Diagnostics.ProcessStartInfo
        $ProcessInfo.FileName = $TCM2013ToolPath
        $ProcessInfo.RedirectStandardError = $true
        $ProcessInfo.RedirectStandardOutput = $true
        $ProcessInfo.UseShellExecute = $false
        $ProcessInfo.Arguments = $UpdateParams
        $Process = New-Object System.Diagnostics.Process
        $Process.StartInfo = $ProcessInfo
        $Process.Start()
        $stdout = $Process.StandardOutput.ReadToEnd()
        $stderr = $Process.StandardError.ReadToEnd()
        Write-Host "stdout: $stdout"
        Write-Host "stderr: $stderr"
        Write-Host "exit code: " $Process.ExitCode
        $syncErrorCode = $Process.ExitCode
        $ProcessInfo = $null
        $Process = $null
        $stdout = $null
        $stderr = $null
		
        if ($syncErrorCode -eq 0) {
            ## Invoke
            $RunParams = " run /create /title:" + $TestEnvironment + ":" + $BuildFolder + " /planid:" + $AcceptanceTestPlanID + " /suiteid:" + $TestSuite + " /configid:" + $TestConfigId + " /settingsname:" + $TestSettingsName + " /testenvironment:" + $TestEnvironment + " /collection:" + $TFSInstance + " /teamproject:" + $TFSTeamProject + " /builddir:" + $TestTempFolder + " /include"
            $ProcessInfo = New-Object System.Diagnostics.ProcessStartInfo
            $ProcessInfo.FileName = $TCM2013ToolPath
            $ProcessInfo.RedirectStandardError = $true
            $ProcessInfo.RedirectStandardOutput = $true
            $ProcessInfo.UseShellExecute = $false
            $ProcessInfo.Arguments = $RunParams
            $Process = New-Object System.Diagnostics.Process
            $Process.StartInfo = $ProcessInfo
            $Process.Start()
            $stdout = $Process.StandardOutput.ReadToEnd()
            $stderr = $Process.StandardError.ReadToEnd()
            Write-Host "stdout: $stdout"
            Write-Host "stderr: $stderr"
            Write-Host "exit code: " $Process.ExitCode
            $ProcessInfo = $null
            $Process = $null
            $stdout = $null
            $stderr = $null	

            ## Check
            ## TODO
        }
        else {
            write-host "Error during the sync stage..."
        }
    }
    else {
        throw "Cannot continue, parameters zero parameters passed to RunMTMTests..."
    }
    return $bolReturn
}

function Start-Services {
    [CmdLetBinding()]
    param (
        $arrServiceList, 
        [string] $strComputer, 
        [int] $retryCount = 10,
		[int] $retryTime = 10
    )
    foreach ($strService in $arrServiceList) { 
        $oService = $null
        $oService = Invoke-Command -ComputerName $strComputer -ScriptBlock { param($svc) Get-Service $svc -ErrorAction SilentlyContinue } -ArgumentList $strService
        if ($oService) {
            if ($oService.Status -eq "Running") {Write-Host "   "$strService "on" $strComputer "is" $oService.Status", nothing to do..."}
            else {
                Write-Host "    Starting" $strService "on" $strComputer
                for ($i = 0; $i -le $retryCount; $i++) {
                     Write-host "      Attempt to start number:" ($i + 1)
                     Invoke-Command -ComputerName $strComputer { param($strService) Start-Service $strService -ErrorAction SilentlyContinue} -Args $strService          
                     Start-Sleep $retryTime
                     $oService = Invoke-Command -ComputerName $strComputer -ScriptBlock { param($svc) Get-Service $svc } -ArgumentList $strService
                     if ($oService.Status -eq "Running") {break}            
                }
                $oService = Invoke-Command -ComputerName $strComputer -ScriptBlock { param($svc) Get-Service $svc } -ArgumentList $strService
                if ($oService.Status -ne "Running") {throw "    " + $strService + "is still " + $oService.Status}
                else {Write-host "   "$strService "has been started"}
            }            
         }
         else {Write-Host "    WARNING:" $strService "is not installed on" $strComputer}
    }
}

function IsMSIx64([string] $strWiXToolsDir, [string] $strMSIFullName) {
    $bolIsMSIx64 = $false
    $strDarkEXE = $strWiXToolsDir + "\dark.exe"
    if (Test-Path $strDarkEXE) {
        Write-Host "    Using:   " $strDarkEXE
        if (Test-Path $strMSIFullName) {
            $strQuotedMSIFullName = [char]34 + $strMSIFullName + [char]34
            Write-Host "    Checking:" $strQuotedMSIFullName
            $oTEMP = Get-Item env:TEMP
            $strTempFile = $oTEMP.Value + "\" + [System.IO.Path]::GetRandomFileName().Replace(".", "") + ".xml"
            #Write-Host "Tempfile:" $strTempFile
            . $strDarkEXE -nologo $strQuotedMSIFullName $strTempFile
            [xml]$xTemp = Get-Content $strTempFile
            if ($xTemp.Wix.Product.Package.Platform -contains "x64") {
                $bolIsMSIx64 = $true
            }
            $xTemp = $null
            Remove-Item $strTempFile -force
            $strTempFile = $null
            $strQuotedMSIFullName = $null
        }
        else {
            Write-Host $strMSIFullName "not found..."
            throw " "
        }
    }
    else {
        Write-Host $strDarkEXE "not found..."
        throw " "
    }
    return $bolIsMSIx64
}

function GetRemPSCompName([string] $strServerName) {
    $Result = ""
    $Result = icm -ComputerName $strServerName {Get-Content env:computername} -erroraction SilentlyContinue
    return $Result
}

function Restart-Servers {
    [CmdLetBinding()]
    param (
        $TargetServers
    )
    foreach	($TargetServer in $TargetServers) {
        $LastBootUpTime = $null
        try {
            $wmi = Get-CimInstance -ClassName Win32_OperatingSystem -ComputerName $TargetServer -ErrorAction Stop
            $LastBootUpTime = $wmi.LastBootUpTime
        }
        catch {
            Write-Error $_ | out-string
        }
        if ([String]::IsNullOrEmpty($LastBootUpTime)){
            Write-Host "Unable to retrieve LastBootUpTime for:" $TargetServer "won't reboot this server..."
            continue
        }
        
        Write-Host "Restarting: $TargetServer"
        try {
            #reboot computer using WMI reboot method is more reliable than Restart-Computer
            Write-host "Rebooting $TargetServer using WMI"
            Invoke-CimMethod -ClassName Win32_OperatingSystem -ComputerName $TargetServer -MethodName reboot -ErrorAction Stop | Out-Null
        }
        catch {
            #last resort - use shutdown.exe
            Write-Host "Reboot via WMI reboot method failed. Tying Shutdown.exe..."
            Invoke-Command -ScriptBlock {
                shutdown.exe /r /f /m \\$TargetServer /d p:4:2 /t 0 /c "Reboot initiated by DOrc" 2>$null
                if ($LastExitCode -ne 0) {
                    Write-Error "Shutdown.exe failed: ExitCode [$LastExitCode]"
                }
            }
        }
    }
    
    #Verify PS Remoting works - separate foreach loop to save time
    foreach	($TargetServer in $TargetServers) {
        $attempt = 1
        do {
            $WSMan = $null
            #sleep for 30 secs to allow some time to shutdown
            Start-Sleep 30
            
            #Test WSMan connection
            $WSMan = Test-WSMan -ComputerName $TargetServer -Authentication Kerberos -ErrorAction SilentlyContinue
            
            #Check uptime
            $10min = New-TimeSpan -Minutes 10
            try {
                $wmi = Get-CimInstance -ClassName Win32_OperatingSystem -ComputerName $TargetServer -ErrorAction Stop
                $LastBootUpTime = $wmi.LastBootUpTime
            }
            catch {
                Write-verbose "CIM not yet available on server [$TargetServer]"
                $LastBootUpTime = Get-Date 01/01/1900 #set way in past to fail the condition inside "until"
            }
                
            #increment attempt up to 50 
            $attempt ++
        }
        #Fail the loop if either timeout is reached or both WSMAN listener is up and Uptime is within the last 10 minutes
        until (($attempt -eq 50) -or (($WSMan.wsmid -match "http://") -and (($(get-date) - $LastBootUpTime) -lt $10min)))
        #fail after 50 attempts (50*30sec = 25min)
        if ($attempt -eq 50) {	
            Throw "Server $TargetServer failed to come up in a timely manner."
        }
        else {
            Write-Host "$TargetServer successfully rebooted at $LastBootUpTime"
        }
    }
}

function GetServersOfType([string] $strEnvironment, [string] $strType = "") {	
    $DOrcToken = Get-DorcToken 
    $DorcAPIHeaders = @{
        "Authorization" = "Bearer $DOrcToken" 
    }
    
    $uri=$RefDataApiUrl + 'RefDataEnvironments?env=' + $strEnvironment	
    $EnvInfo = Invoke-RestMethod -Uri $uri -method Get -Headers $DorcAPIHeaders -ContentType 'application/json'
    $EnvId = $EnvInfo.EnvironmentId
    $uri = $RefDataApiUrl + 'RefDataEnvironmentsDetails/' + $EnvId	
    $EnvDetailsInfo = Invoke-RestMethod -Uri $uri -method Get -Headers $DorcAPIHeaders -ContentType 'application/json'
    $Servers=$EnvDetailsInfo.AppServers.Name
    $table=new-object "System.Data.DataTable"
    $ColumnNames='Env_ID','Env_Name','Owner','Thin_Client_Server','Restored_From_Backup','Last_Update','File_Share','Env_Note','Description','Build_ID','Locked','Env_ID1','Server_ID','Server_ID1','Server_Name','OS_Version','Application_Server_Name'
    foreach ($ColumnName in $ColumnNames) {
        $Col = New-Object system.Data.DataColumn $ColumnName, ([string])
        $table.columns.add($col)
        }
    Foreach ($server in $Servers) {
        $Row = $table.NewRow()
        $Row.Env_ID = $EnvInfo.EnvironmentId
        $Row.Env_Name = $EnvInfo.EnvironmentName
        $Row.Owner = $EnvInfo.Details.EnvironmentOwner
        $Row.Thin_Client_Server = $EnvInfo.Details.ThinClient
        $Row.Restored_From_Backup = $EnvInfo.Details.RestoredFromSourceDb
        $Row.Last_Update = $EnvInfo.Details.LastUpdated
        $Row.File_Share = $EnvInfo.Details.FileShare
        $Row.Env_Note = $EnvInfo.Details.Notes
        $Row.Description = $EnvInfo.Details.Description
        $Row.Build_ID = $NULL
        $Row.Locked = $NULL
        $Row.Env_ID1 = $EnvId
        $Row.Server_ID = ($EnvDetailsInfo.AppServers | Where {$_.Name -eq $Server}).ServerId
        $Row.Server_ID1 = ($EnvDetailsInfo.AppServers | Where {$_.Name -eq $Server}).ServerId
        $Row.Server_Name = $server
        $Row.OS_Version = ($EnvDetailsInfo.AppServers | Where {$_.Name -eq $Server}).OsName
        $Row.Application_Server_Name = ($EnvDetailsInfo.AppServers | Where {$_.Name -eq $Server}).ApplicationTags
        If ($strType -and ($Row.Application_Server_Name.Split(";") -notcontains $strType) -and ($strType -ne ';') -and ($strType -ne '%')) {}
        Else {
            $table.Rows.Add($Row) 
             } 
        }
    return @(, $table)
}

function GetServersOfType_V2 ([string] $strType = "") {
    $Servers=$AllServers	
	$AllServerVariables= Get-Variable -Name ServerNames_*
    $table=new-object "System.Data.DataTable"
    $ColumnNames='Server_Name','Application_Server_Name'
    foreach ($ColumnName in $ColumnNames) {
    $Col = New-Object system.Data.DataColumn $ColumnName, ([string])
    $table.columns.add($col)
    }
    foreach ($Server in $Servers) {
        $ServerTags = $NULL
        Foreach ($ServerVariable in $AllServerVariables) {						
			If ($ServerVariable.Value -like $Server) {				
                $ServerTags+=$ServerVariable.name.Replace('ServerNames_','')+';'
            }
        }
        If ($ServerTags) {$ServerTags=$ServerTags.Substring(0, $ServerTags.Length - 1)}
        $Row = $table.NewRow()
        $Row.Server_Name = $server
        $Row.Application_Server_Name = $ServerTags
        If ($strType) {$strTypeNoSpaces=$strType.Replace(' ','_')}
        If ($ServerTags) {} Else {$ServerTags=';'}
        If ($strType -and ($ServerTags.Split(";") -notcontains $strTypeNoSpaces) -and ($strType -ne ';') -and ($strType -ne '%')) {}
        Else {
            $table.Rows.Add($Row) 
        }       
    }
    return @(, $table)
}

function BuildServersOfType([string] $strEnvironment, [string] $strServers, [string] $strType) {
    $ServerInfoCheck = new-object "System.Data.DataTable"
    $ServerInfoCheck = GetServersOfType $EnvironmentName ""
    $ServerInfoResult = new-object "System.Data.DataTable"
    $Col1 = New-Object system.Data.DataColumn Server_Name, ([string])
    $Col2 = New-Object system.Data.DataColumn Application_Server_Name, ([string])
    $ServerInfoResult.columns.add($col1)
    $ServerInfoResult.columns.add($col2)
    foreach ($server in $strServers.Split("`;")) {
        $bolServerBelongsToEnv = $false		
        foreach ($Row in $ServerInfoCheck) {
            if ($server.ToLower() -eq $Row.Server_Name.Trim().ToLower()) {
                $bolServerBelongsToEnv = $true
            }
        }
        if ($bolServerBelongsToEnv) {
            $Row = $ServerInfoResult.NewRow()
            $Row.Server_Name = $server
            $Row.Application_Server_Name = $strType
            $ServerInfoResult.Rows.Add($Row)
        }
        else {
            Write-Host $Server "does not exist in" $strEnvironment
            throw ""
        }
    }
    return @(, $ServerInfoResult)
}

function DeployDACPAC([string] $sqlPackagePath, [string] $strInstance, [string] $strDatabase, [string] $strDACPAC, [string] $strPublishProfile, [array] $arrVariables, [string] $strBlackList, [string] $strRollbackMode = "None",[string] $EnvironmentPostScript="", [int] $QueryTimeout = 0) {
    Import-Module SqlServer -DisableNameChecking
    #TODO If database doesn't exist skip check for alter
    #TODO Database.WhiteList.xml in DevTools

    # Resolve the SQL query timeout used for the pre/post custom SQL scripts.
    # Precedence: explicit $QueryTimeout param > DACPACQueryTimeout DOrc property > code default (3600s).
    if ($QueryTimeout -le 0) {
        $QueryTimeout = 3600
        $propQueryTimeout = Get-Variable -Name 'DACPACQueryTimeout' -ValueOnly -ErrorAction SilentlyContinue
        if (-not [string]::IsNullOrWhiteSpace($propQueryTimeout)) {
            $parsedQueryTimeout = 0
            if ([int]::TryParse([string]$propQueryTimeout, [ref]$parsedQueryTimeout) -and $parsedQueryTimeout -gt 0) {
                $QueryTimeout = $parsedQueryTimeout
            }
            else {
                Write-Host "****WARNING: DACPACQueryTimeout value '$propQueryTimeout' is not a positive integer. Using default $QueryTimeout.****"
            }
        }
    }
    Write-Host "SQL query timeout: $QueryTimeout seconds (pre/post custom SQL scripts)"
	
    Write-Host "Variables:       " $arrVariables.Count
    $strVariables = ""
    if ($arrVariables.Count -gt 0) {
        foreach ($strVariable in $arrVariables) {
            Write-Host "                 " $strVariable
            $strVariables = $strVariables + " /v:" + $strVariable
        }
    }
    Write-Host ""

    if (Test-Path $strDACPAC) {
		$strEnvironmentPostSQLFile = $strDACPAC.Replace(".dacpac", ".$EnvironmentPostScript.sql")
        $strApplyDataSQLFile = $strDACPAC.Replace(".dacpac", ".ApplyDataChanges.sql")
        $strRollbackDataSQLFile = $strDACPAC.Replace(".dacpac", ".RollbackDataChanges.sql")
        $strPreSQLFile = $strDACPAC.Replace(".dacpac", ".PreSQL.sql")
        $strPostSQLFile = $strDACPAC.Replace(".dacpac", ".PostSQL.sql")
        $bolBlackStatements = $false
		
        #If Running as Data Rollback then apply script then return
	    if ($strRollbackMode -eq "Data") {
            # If Present check and process PreSQL
            if (Test-Path $strRollbackDataSQLFile) {
                Write-Host "Checking:        " $strRollbackDataSQLFile
                $preResult = CheckAndApplySQL $strInstance $strDatabase $strRollbackDataSQLFile $strBlackList $QueryTimeout
                if (!$preResult) {
                    throw "Error applying Rollback sql"
                }
            } 
            else {
                Write-Host "No Rollback SQL:       " $strRollbackDataSQLFile
            }
            Write-Host ""
            return;
        }

        if ($strRollbackMode -eq "None" -Or $strRollbackMode -eq "Schema") {
            # If Present check and process PreSQL
            if (Test-Path $strPreSQLFile) {
                Write-Host "Checking:        " $strPreSQLFile
                $preResult = CheckAndApplySQL $strInstance $strDatabase $strPreSQLFile $strBlackList $QueryTimeout
                if (!$preResult) {
                    throw "Error applying pre-sql"
                }
            } 
            else {
                Write-Host "No PreSQL:       " $strPreSQLFile
            }
		
            # Script & Apply DACPAC
            $resScript = ActionDACPAC "Script" $sqlPackagePath $strInstance $strDatabase $strDACPAC $strPublishProfile $strVariables $strBlackList
            if ($resScript) {
                $resDeployReport = ActionDACPAC "DeployReport" $sqlPackagePath $strInstance $strDatabase $strDACPAC $strPublishProfile $strVariables $strBlackList
                if ($resDeployReport) {
                    $resPublish = ActionDACPAC "Publish" $sqlPackagePath $strInstance $strDatabase $strDACPAC $strPublishProfile $strVariables $strBlackList
                    if ($resPublish) {
                        Write-Host ""
                        Write-Host "                  *** Sucessfully Deployed the DACPAC ***"
                        Write-Host ""
                    }
                    else {
                        throw "Aborting..."
                    }
                }
                else {
                    throw "Aborting..."
                }
            }
            else {
                throw "Aborting..."
            }
		 
            # If Present check and process PostSQL
            Write-Host ""
            if (Test-Path $strPostSQLFile) {
                Write-Host "Checking:        " $strPostSQLFile
                $preResult = CheckAndApplySQL $strInstance $strDatabase $strPostSQLFile $strBlackList $QueryTimeout
                if (!$preResult) {
                    throw "Error applying post-sql"
                }
            }
            else {
                Write-Host "No PostSQL:      " $strPostSQLFile
            }

            # If Running as Rollback Mode None then apply Data script
            if ($strRollbackMode -eq "None") {
                # If Present check and process ApplyDataChangeSql
                if (Test-Path $strApplyDataSQLFile) {
                    Write-Host "Checking:        " $strApplyDataSQLFile
                    $preResult = CheckAndApplySQL $strInstance $strDatabase $strApplyDataSQLFile $strBlackList $QueryTimeout
                    if (!$preResult) {
                        throw "Error applying Data Changes-sql"
                    }
                } 
                else {
                    Write-Host "No Apply Data Changes:       " $strApplyDataSQLFile
                }
                Write-Host ""

			  # If Present check and process ApplyDataChangeSql
					 if (Test-Path $strEnvironmentPostSQLFile)
					 {
						 Write-Host "Checking:        " $strEnvironmentPostSQLFile
						 $preResult = CheckAndApplySQL $strInstance $strDatabase $strEnvironmentPostSQLFile $strBlackList $QueryTimeout
						 if (!$preResult)
						 {
							 throw "Error applying $strEnvironmentPostSQLFile-sql"
						 }
					 } 
					 else
					 {
						 Write-Host "No Environment Specific SQL Changes:       " $strEnvironmentPostSQLFile
					 }
					 Write-Host ""
            }
        }
    }
    else {
        Write-Host $strDACPAC "not found!"
        throw ""
    }
}

function ActionDACPAC([string] $strAction, [string] $sqlPackagePath, [string] $strInstance, [string] $strDatabase, [string] $strDACPAC, [string] $strPublishProfile, [string] $strVariables, [string] $strBlackList) {
    $ErrorActionPreference = 'stop'
    $bolReturn = $false
    $intProcExit = 0
    $dtNow = Get-Date
    $dateReverse = $dtNow.Year.ToString() + "-" + $dtNow.Month.ToString().PadLeft(2, '0') + "-" + $dtNow.Day.ToString().PadLeft(2, '0') + "_" + $dtNow.TimeOfDay.Hours.ToString().PadLeft(2, '0') + "-" + $dtNow.TimeOfDay.Minutes.ToString().PadLeft(2, '0')
    switch ($strAction) {
        "Script" {
            $strScriptFile = $DACPACSQLScripts + $dateReverse + "_" + $strInstance.Replace('\', '_') + "." + $strDatabase + ".sql"
            $strArguments = "/action:Script /TargetTrustServerCertificate:True /SourceFile:" + [char]34 + $strDACPAC + [char]34 + " /TargetDatabaseName:" + [char]34 + $strDatabase + [char]34 + " /TargetServerName:" + [char]34 + $strInstance + [char]34 + " /Profile:" + [char]34 + $strPublishProfile + [char]34 + " /OutputPath:" + [char]34 + $strScriptFile + [char]34 + $strVariables
            $output = $strScriptFile
        }
        "DeployReport" {
            $strReportFile = $DACPACSQLScripts + $dateReverse + "_" + $strInstance.Replace('\', '_') + "." + $strDatabase + ".xml"
            $strArguments = "/action:DeployReport /TargetTrustServerCertificate:True /SourceFile:" + [char]34 + $strDACPAC + [char]34 + " /TargetDatabaseName:" + [char]34 + $strDatabase + [char]34 + " /TargetServerName:" + [char]34 + $strInstance + [char]34 + " /Profile:" + [char]34 + $strPublishProfile + [char]34 + " /OutputPath:" + [char]34 + $strReportFile + [char]34 + $strVariables
            $output = $strReportFile
        }
        "Publish" {
            $strArguments = "/action:Publish /TargetTrustServerCertificate:True /SourceFile:" + [char]34 + $strDACPAC + [char]34 + " /TargetDatabaseName:" + [char]34 + $strDatabase + [char]34 + " /TargetServerName:" + [char]34 + $strInstance + [char]34 + " /Profile:" + [char]34 + $strPublishProfile + [char]34 + $strVariables
            $output = "Captured"
        }
        default {
            Write-Host "Invalid action passed..."
            throw ""
        }
    }
    Write-Host ""
    Write-Host "Action:          " $strAction "****"
    Write-Host "DACPAC:          " $strDACPAC
    Write-Host "Against:         " $strInstance"."$strDatabase
    Write-Host "Publish Profile: " $strPublishProfile
    Write-Host "To:              " $output
    Write-Host ""
	
    $ProcessInfo = New-Object System.Diagnostics.ProcessStartInfo
    $ProcessInfo.FileName = $sqlPackagePath
    $ProcessInfo.RedirectStandardError = $true
    $ProcessInfo.RedirectStandardOutput = $true				
    $ProcessInfo.UseShellExecute = $false
    $ProcessInfo.Arguments = $strArguments	
    $Process = New-Object System.Diagnostics.Process
    $Process.StartInfo = $ProcessInfo
    $oStdOutEvent = Register-ObjectEvent -InputObject $Process -EventName OutputDataReceived -Action {Write-Host "StdOut:          " $Event.SourceEventArgs.Data}
    $oStdErrEvent = Register-ObjectEvent -InputObject $Process -EventName ErrorDataReceived -Action {Write-Host "StdERR:          " $Event.SourceEventArgs.Data}
    $Process.Start() | Out-Null
    $Process.BeginOutputReadLine()
    $Process.BeginErrorReadLine()
    $Process.WaitForExit()
    Unregister-Event -SourceIdentifier $oStdOutEvent.Name
    Unregister-Event -SourceIdentifier $oStdErrEvent.Name
    $intProcExit = $Process.ExitCode
    $ProcessInfo = $null
    $Process = $null	
    #Write-Host "Exit code:       " $intProcExit
    if ($intProcExit -eq 0) {
        if ($strAction -eq "Publish") {
            $bolReturn = $true
        }
        else {
            Write-Host "Checking:        " $output
            if ($strBlackList.Length -gt 0) {
                $bolBlackStatements = $false
                $intLineCount = 0
                Write-Host "Blacklist        " $strBlackList
                $oContent = Get-Content $output
                foreach ($strLine in $oContent) {
                    $intLineCount++
                    if ($strBlackList.Contains(";")) {
                        foreach ($strEntry in $strBlackList.Split("`;")) {
                            if ($strLine.ToLower().Contains($strEntry.Tolower())) {
                                Write-Host "BLACKLISTED:     " $strLine
                                $bolBlackStatements = $true
                            }
                        }
                    }
                    else {
                        if ($strLine.ToLower().Contains($strBlackList)) {
                            Write-Host "BLACKLISTED:     " $strLine
                            $bolBlackStatements = $true
                        }
                    }
                }
                Write-Host "Lines checked:   " $intLineCount
                if (!$bolBlackStatements) {
                    $bolReturn = $true
                }
            }
            else {
                Write-Host "                  Nothing to check, blacklist is empty..."
                $bolReturn = $true
            }
        }
    }	
    return $bolReturn
}

function CheckAndApplySQL([string] $strInstance, [string] $strDatabase, [string] $strSQLFile, [string] $strBlackList, [int] $QueryTimeout = 3600) {
    $bolReturn = $false
    $bolBlackStatements = $false	
    if ($strBlackList.Length -gt 0) {
        $bolBlackStatements = $false
        $intLineCount = 0
        Write-Host "Blacklist        " $strBlackList
        $oContent = Get-Content $strSQLFile
        foreach ($strLine in $oContent) {
            $intLineCount++
            if ($strBlackList.Contains(";")) {
                foreach ($strEntry in $strBlackList.Split("`;")) {
                    if ($strLine.ToLower().Contains($strEntry.Tolower())) {
                        Write-Host "BLACKLISTED:     " + $strLine
                        $bolBlackStatements = $true
                    }
                }
            }
            else {
                if ($strLine.ToLower().Contains($strBlackList)) {
                    Write-Host "BLACKLISTED:     " + $strLine
                    $bolBlackStatements = $true
                }
            }
        }
        Write-Host "Lines checked:   " $intLineCount
        if (!$bolBlackStatements) {
            Write-Host "Applying:        " $strSQLFile
            try {
                Invoke-Sqlcmd -ServerInstance $strInstance -Database $strDatabase -InputFile $strSQLFile  -QueryTimeout $QueryTimeout -TrustServerCertificate -ErrorAction 'Stop' -Verbose 
                $bolReturn = $true
            }
            catch {
                Write-Host "Error:" ($_) " applying:" $strSQLFile
                throw "Aborting because of an error applying SQL script..."
            }
        }
    }
    else {
        Write-Host "                  Nothing to check, blacklist is empty..."
        $bolReturn = $true
    }
    return $bolReturn
}

function Merge-Tokens() {
    [CmdletBinding()] 
    param (
        [Parameter(Mandatory = $True, ValueFromPipeline = $true)]
        [AllowEmptyString()]
        [String] $template,

        [Parameter(Mandatory = $true)]
        [HashTable] $tokens
    ) 

    begin { Write-Verbose "$($MyInvocation.MyCommand.Name)::Begin" }

    process {
        Write-Verbose "$($MyInvocation.MyCommand.Name)::Process" 

        # https://github.com/craibuc/PsTokens
        # adapted based on this Stackoverflow answer: http://stackoverflow.com/a/29041580/134367
        try {

            [regex]::Replace( $template, '__(?<tokenName>[\w\.]+)__', {
                    # __TOKEN__
                    param($match)

                    $tokenName = $match.Groups['tokenName'].Value              
                    $tokenValue = Invoke-Expression "`$tokens.$tokenName"
                    Write-Host "   " $tokenName "=" $tokenValue

                    if ($tokenValue) {
                        # there was a value; return it
                        return $tokenValue
                    } 
                    else {
                        # non-matching token; return token
                        return $match
                    }
                })

        }
        catch {
            write-host "Error in Merge-Tokens" $_
            throw ""
        }
    }
    end { Write-Verbose "$($MyInvocation.MyCommand.Name)::End" }
} 

function CheckFeature([string] $strComputerName, [string] $strFeature) {
    Write-Host "Checking for:" $strFeature "on:" $strComputerName
    $session = New-PSSession -ComputerName $strComputerName
    Invoke-Command -session $session {Import-Module ServerManager}    
    Invoke-Command -session $session {$ProgressPreference = "SilentlyContinue"}   
    [bool]$state = invoke-command -session $session {$resState = Get-WindowsFeature -Name $($args[0]); return [bool]$resState.Installed} -ArgumentList $strFeature
    Remove-PSSession $session
    return $state
}

function InstFeature([string] $strComputerName, [string] $strFeature, [bool] $bolAllSubFeatures, [string] $strSourceSxSFolder, [string] $strDeploymentServiceAccount, [string] $strDeploymentServiceAccountPassword) {
    # Required because deployment nodes don't support -ComputerName on current powershell version
    $bolReturn = $false
    Write-Host "Checking:" $strComputerName":"$strFeature
    $session = New-PSSession -ComputerName $strComputerName
    if (CheckFeature $strComputerName $strFeature) {
        Write-Host "    Already installed..."
        $bolReturn = $true
    }
    else {
        Write-Host "    Installing:" $strFeature
        if (-not($session)) { Write-Host "    Unable to start session" }
        Invoke-Command -session $session {$ProgressPreference = "SilentlyContinue"}
        Invoke-Command -session $session {net use * $($args[0]) $($args[1]) /user:$($args[2]) 2>&1>null} -ArgumentList $strSourceSxSFolder, $DeploymentServiceAccountPassword, $DeploymentServiceAccount
        if ($bolAllSubFeatures) {	
            if (((Get-CimInstance -ClassName Win32_OperatingSystem -ComputerName $strComputerName).Name).Contains("2012")) {
                Invoke-Command -session $session {Install-WindowsFeature -Name $($args[0]) -IncludeAllSubFeature -Source $($args[1]) | Out-Null} -ArgumentList $strFeature, $strSourceSxSFolder
            }
            else {
                Invoke-Command -session $session {Import-Module ServerManager; Add-WindowsFeature -Name $($args[0]) -IncludeAllSubFeature | Out-Null; Remove-Module ServerManager} -ArgumentList $strFeature
            }
        }
        else {
            if (((Get-CimInstance -ClassName Win32_OperatingSystem -ComputerName $strComputerName).Name).Contains("2012")) {
                Invoke-Command -session $session {Install-WindowsFeature -Name $($args[0]) -Source $($args[1]) | Out-Null} -ArgumentList $strFeature, $strSourceSxSFolder
            }
            else {                
                Invoke-Command -session $session {Import-Module ServerManager; Add-WindowsFeature -Name $($args[0]) | Out-Null; Remove-Module ServerManager} -ArgumentList $strFeature
            }
        }
        Invoke-Command -session $session {net use * /d /y 2>&1>null}
        Remove-PSSession $session
        $bolReturn = CheckFeature $strComputerName $strFeature
    }
    return $bolReturn
}

function UnInstFeature([string] $strComputerName, [string] $strFeature, [bool] $bolRestartBeforeCheck) {
    # Required because deployment nodes don't support -ComputerName on current powershell version
    $bolReturn = $false
    Write-Host "Checking:" $strComputerName":"$strFeature
    $session = New-PSSession -ComputerName $strComputerName
    if (CheckFeature $strComputerName $strFeature) {
        Write-Host "    Uninstalling:" $strFeature
        Invoke-Command -session $session {$ProgressPreference = "SilentlyContinue"}
        if ( ((Get-CimInstance -ClassName Win32_OperatingSystem -ComputerName $strComputerName).Name).Contains("2012")) {
            Invoke-Command -session $session {Uninstall-WindowsFeature -Name $($args[0]) | Out-Null} -ArgumentList $strFeature
        }
        else {
            Invoke-Command -session $session {Import-Module ServerManager; Remove-WindowsFeature -Name $($args[0]) | Out-Null; Remove-Module ServerManager} -ArgumentList $strFeature
        }
        Remove-PSSession $session
        if ($bolRestartBeforeCheck) {
            Restart-Servers $strComputerName
        }
        $tmp = CheckFeature $strComputerName $strFeature
        if (-not($tmp)) {$bolReturn = $true}
    }
    else {
        Write-Host "    Not installed, won't remove..."
        $bolReturn = $true
    }
    return $bolReturn
}

function CreateOleConnectionString([string] $provider, [string] $server, [string] $database, [bool] $mars = $false) {
    if ($mars) {
        [string]::Format("Provider={0};Data Source={1};Integrated Security=SSPI;Initial Catalog={2};Packet Size=32767;MARS Connection=True", $provider, $server, $database)
    }
    else {
        [string]::Format("Provider={0};Data Source={1};Integrated Security=SSPI;Initial Catalog={2};Packet Size=32767", $provider, $server, $database)
    }
}

Function Test-RequiredProperties {
    <#
        .SYNOPSIS
            Take a array of required property names and test if the all are defined, throw an error if 1 or more are not

        .DESCRIPTION
            Take a array of required property names and test if the all are defined, throw an error if 1 or more are not

        .PARAMETER  Properties
            Array of property names
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Position = 0, Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [System.String[]]$Properties,
        [Switch]$AllowEmptyValues
    )

    $missingProperties = $false

    foreach ($propName in $Properties) {
        
        try {
            $prop = Get-Variable -Name $propName -ErrorAction Stop

            $propValue = Get-Variable -Name $propName -ValueOnly
    
			        
            if ([string]::IsNullOrEmpty($propValue)) {
                if ($AllowEmptyValues) {
                    Write-Host "WARNING: Property $($propName): has a null/empty value"
                } 
                else {
                    Write-Host "****Property $($propName): has a null/empty value****"
                    $missingProperties = $true
                }
                
            }
        }
        catch {
            Write-Host "****Property $($propName): Not defined****"
            $missingProperties = $true
        }
    }
    if ($missingProperties) {
        Write-Host ""
        throw "1 or more properties undefined"
    }    
}

Function DeleteFolderonSSRSPortal
(
    [Parameter(Position = 0, Mandatory = $true)]
    [string]$ReportingServerUri,
 
    [Parameter(Position = 1, Mandatory = $true)]
    [string]$SSRSReportDestinationFolder
) {
    Write-Host "Deleting Folder: " $SSRSReportDestinationFolder # deleting Report folder on site
    try {
        Remove-SsrsItem -Url $ReportingServerURI -ItemPath $SSRSReportDestinationFolder -erroraction SilentlyContinue 
    }
    catch [System.Web.Services.Protocols.SoapException] {
        Write-Host "Folder Does not Exist"
    }
}

Function CreateFolderonSSRSPortal
(
    [Parameter(Position = 0, Mandatory = $true)]
    [string]$ReportingServerUri,
 
    [Parameter(Position = 1, Mandatory = $true)]
    [string]$SSRSReportDestinationFolder
) {
    Write-Host "Creating folder:" $SSRSReportDestinationFolder #Recreating report folder on site
    New-SsrsFolder -Url $ReportingServerURI -Name "$SSRSReportDestinationFolder" -Verbose
}

Function CreateDataSourceonSSRSPortal
(
    [Parameter(Position = 0, Mandatory = $true)]
    [string]$ReportingServerUri,
 
    [Parameter(Position = 1, Mandatory = $true)]
    [string]$SSRSDataSourceName,
    	 
    [Parameter(Position = 2, Mandatory = $true)]
    [string]$SSRSDataSourceDestinationFolder,
	
    [Parameter(Position = 3, Mandatory = $true)]
    [string]$Description,
     
    [Parameter(Position = 4, Mandatory = $true)]
    [string]$ConnectionString,

    [Parameter(Position = 5, Mandatory = $true)]
    [string]$Username,
	
    [Parameter(Position = 6, Mandatory = $true)]
    [string]$Password
) {
    Write-Host "Creating DataSource: $SSRSDataSourceDestinationFolder/$SSRSDataSourceName"
    try {   
        New-SsrsDataSource -Url $ReportingServerURI -Name "$SSRSDataSourceName" -Folder "$SSRSDataSourceDestinationFolder" -Description "$Description" -ConnectString "$ConnectionString"   -Extension "SQL" -CredentialRetrieval ([Internal.DOrcSSrsModule.SsrsReportsService.CredentialRetrievalEnum]::Store) -UserName $UserName -Password $Password -WindowsCredentials $true
    }
    catch [Exception] {	
        if ($_.Exception.Message.ToString() -match "already exists") {
            Write-Host "Datasource $SSRSDataSourceName already exists"
        }
        else {
            Throw $_.Exception.Message
        }
    }
}

Function UploadSSRSFiles
(
    [Parameter(Position = 0, Mandatory = $true)]
    [string]$ReportingServerURI,

    [Parameter(Position = 1, Mandatory = $true)]
    [string]$SSRSSourceFolder,
 
    [Parameter(Position = 2, Mandatory = $true)]
    [string]$SSRSReportDestinationFolder,

    [Parameter(Position = 3, Mandatory = $true)]
    [string]$SSRSDataSourceDestinationFolder,
    
    [Parameter(Position = 4, Mandatory = $false)]
    [string]$Environment
) {
    Write-Host ""
    $SSRSFiles = Get-ChildItem -Path $SSRSSourceFolder -Recurse -Filter "*.rdl" # pick up all ssrs files

    if ($SSRSFiles.count -eq 0) {   
        throw ".rdl files not found in $SSRSSourceFolder"
    }
    else {
        Write-Host "Uploading" $SSRSFiles.Count"reports..."
    }

    foreach ($SSRSFile in $SSRSFiles) {
        $FullReportFileName = Join-Path $SSRSSourceFolder $SSRSFile #full path name to SSRS file in dropfolder
        $ReportName = $SSRSFile -replace ".rdl", ""
        $ReportWithPath = $SSRSReportDestinationFolder + "/" + $ReportName #full ssrs report path on SSRS site
        Write-Host ""
        Write-Host "Uploading: " $FullReportFileName "As: " $ReportWithPath
        New-SsrsReport -Url $ReportingServerURI -File $FullReportFileName -Folder $SSRSReportDestinationFolder -Description $ReportName -Overwrite #create the new SSRS report
        #create Data Source from finding data source from .rdl file
        $SSRSDataSourceNames = GetDataSource $FullReportFileName

        $DataSourceNamesCommaSep = ""
        $DataSourcePathsCommaSep = ""
        $separator = ""
        foreach ($SSRSDataSourceName in $SSRSDataSourceNames) {

            $DataSourceReference = $SSRSDataSourceName.DataSourceReference
            $ConnectionString = "SSRS_" + $DataSourceReference + "_ConnectionString"
            $ConnectionString = Get-Variable $ConnectionString -ValueOnly -ErrorAction SilentlyContinue
            if ($ConnectionString -eq $null) {
                $DatabaseServer = Get-Variable "DbServer_$DataSourceReference" -ValueOnly -ErrorAction SilentlyContinue
                $DatabaseName = Get-Variable "DbName_$DataSourceReference" -ValueOnly -ErrorAction SilentlyContinue
                if (($DatabaseServer -eq $null) -or ($DatabaseName -eq $null)) {
                    throw "Can't find connection string in DOrc Database for $DataSourceReference"
                }
                else {
                    Write-Host ("Generating connection string from Environment Management Database for database type $DataSourceReference")
                    $ConnectionString = "Data Source=$DatabaseServer;Initial Catalog=$DatabaseName;Integrated Security=True"
                }
            }
            else {
                Write-Host ("Using DOrc connection string property SSRS_$DataSourceReference" + "_ConnectionString")
            }
            $Username = "SSRS_" + $DataSourceReference + "_Username"
            $Username = Get-Variable $Username -ValueOnly -ErrorAction Stop
            $Password = "SSRS_" + $DataSourceReference + "_Password"
            $Password = Get-Variable $Password -ValueOnly -ErrorAction Stop
            $SSRSDataSourceDestinationFullPath = $SSRSDataSourceDestinationFolder + "/" + $DataSourceReference
            CreateDataSourceonSSRSPortal $ReportingServerURI $DataSourceReference $SSRSDataSourceDestinationFolder $DataSourceReference $Connectionstring $Username $Password

            $DataSourceNamesCommaSep = $DataSourceNamesCommaSep + $separator + $SSRSDataSourceName.Name
            $DataSourcePathsCommaSep = $DataSourcePathsCommaSep + $separator + $SSRSDataSourceDestinationFullPath
            $separator = ","
        }
        Write-Host "Associating: " $FullReportFileName "With: " $SSRSDataSourceDestinationFullPath
        Set-SsrsDataSourceReference -Url $ReportingServerURI -ReportPath $ReportWithPath -DataSourcePath $DataSourcePathsCommaSep -DataSourceName $DataSourceNamesCommaSep # associate the new SSRS report to the datasource


        if ([string]::IsNullOrEmpty($Environment)) {    
            Write-Host "'Environment' Property is null or empty, therefore skipping creation of file subscription"
        }
        else {
            $ScheduleDefPath = Join-Path $SSRSSourceFolder ($ReportName + ".xml")
            if (Test-Path $ScheduleDefPath) {
                Write-Host "File Subscription: $ScheduleDefPath found so adding file subscription based on the supplied definition"
                Add-SSRSFileSubscription -ReportServerURI $ReportingServerURI -XMLFile $ScheduleDefPath -Env $Environment -ServiceUserName $Username -ServicePassword $Password -EnvironmentSSRSReportPath $ReportWithPath
            }
            else {
                Write-Host "No Schedule Definition XML file found so not adding file subscription"
            }
        }
    }
}

Function GetDataSource
(
    [Parameter(Position = 0, Mandatory = $true)]
    [string]$SSRSFilePath
) {
    $RDLFile = $SSRSFilePath
    [xml]$xmlFile = Get-Content $RDLFile
    $DataSource = $xmlfile.Report.DataSources.DataSource
    return $DataSource
} 

Function Add-SSRSFileSubscription
(
    [Parameter(Position = 0, Mandatory = $true)]
    [string]$ReportServerUri,
 
    [Parameter(Position = 1, Mandatory = $true)]
    [string]$XMLFile,
    	 
    [Parameter(Position = 2, Mandatory = $true)]
    [string]$Env,
	
    [Parameter(Position = 3, Mandatory = $true)]
    [string]$ServiceUserName,
     
    [Parameter(Position = 4, Mandatory = $true)]
    [string]$ServicePassword,
	
    [Parameter(Position = 5, Mandatory = $true)]
    [string]$EnvironmentSSRSReportPath
) {
    $ssrsProxy = New-WebServiceProxy -Uri $ReportServerUri -UseDefaultCredential ;
    [xml]$config = Get-Content $XMLFile
    $ReportName = $config.FirstChild.ReportName
    $ReportPath = $EnvironmentSSRSReportPath
    $DropFileName = $config.FirstChild.FileName
	
    $DropPaths = $config.FirstChild.OutputFilePath
    $DropPath = $DropPaths.ChildNodes | Where-Object {$_.LocalName -eq $Env}
    If ($DropPath.Length -lt 1) {$DropPath = ($DropPaths.Default) + "\" + $Env}
    Else {$DropPath = $DropPaths.$Env}
	
    #Write-Host "Drop path = " $DropPath
	
    $OutputFormat = $config.FirstChild.OutputFormat
    $OutputWriteMode = $config.FirstChild.OutputWriteMode
    $OutputFileName = $config.FirstChild.OutputFileName
    $EventType = $config.FirstChild.EventType
    $SubscriptionDescription = $config.FirstChild.SubscriptionDescription
    [string]$ScheduledefinintionXML = $config.FirstChild.ScheduleDefifintionXML.InnerXML

    $FullPath = $ReportPath

    $type = $ssrsProxy.GetType().Namespace
    $ExtensionSettingsDataType = ($type + '.ExtensionSettings')
    $ActiveSettingsDataType = ($type + '.ActiveState')
    $ParameterValueType = ($type + '.ParameterValue')

    $extensionSettings = New-Object ($ExtensionSettingsDataType)

    $extensionSettings.Extension = 'Report Server FileShare'

    $ParameterValueOrFieldReferenceType = ($type + '.ParameterValueOrFieldReference[]')

    $extensionParams = New-Object $ParameterValueOrFieldReferenceType 6

    #Only used for description
    $subscriptionType = '_File_Subscription'

    $Path = New-Object ($type + '.ParameterValue')
    $Path.Name = 'PATH'
    $Path.Value = $DropPath
    $extensionParams[0] = $Path

    $FileName = New-Object ($type + '.ParameterValue')
    $FileName.Name = 'FILENAME'
    $FileName.Value = $DropFileName
    $extensionParams[1] = $FileName

    $FileExtension = New-Object ($type + '.ParameterValue')
    $FileExtension.Name = 'FILEEXTN'
    $FileExtension.Value = 'TRUE'
    $extensionParams[2] = $FileExtension

    $SubUserName = New-Object ($type + '.ParameterValue')
    $SubUserName.Name = 'USERNAME'
    $SubUserName.Value = $ServiceUserName
    $extensionParams[3] = $SubUserName

    $RenderFormat = New-Object ($type + '.ParameterValue')
    $RenderFormat.Name = 'RENDER_FORMAT'
    $RenderFormat.Value = $OutputFormat
    $extensionParams[4] = $RenderFormat

    $WriteMode = New-Object ($type + '.ParameterValue')
    $WriteMode.Name = 'WRITEMODE'
    $WriteMode.Value = $OutputWriteMode
    $extensionParams[5] = $WriteMode

    $Password = New-Object ($type + '.ParameterValue')
    $Password.Name = 'PASSWORD'
    $Password.Value = $ServicePassword
    $extensionParams[5] = $Password
			
    $Report_Subscr_Description = 'Automatically generated supscription defined by the XML in the report drop folder'

    $extensionSettings.ParameterValues = $extensionParams
	
    Return $ssrsProxy.CreateSubscription($FullPath, $extensionSettings, $Report_Subscr_Description, $EventType, $ScheduledefinintionXML, $null)
}

Function Move-ClusterRole {
    <#
            .SYNOPSIS
                Moves cluster role to the another node
            .DESCRIPTION
                Takes role name, node name and moves a role to a provided node.
        #>
    param(
        [Parameter(Position = 0, Mandatory = $true)]
        [string]$RoleName,
        [Parameter(Position = 1, Mandatory = $true)]
        [string]$ToNodeName
    )
    $cluster = Get-DbaWsfcCluster $ToNodeName
    if (!$cluster){ return}
    $role = Get-DbaWsfcRole -ComputerName $ToNodeName | where {$_.Name -eq $RoleName}
    if ($role.OwnerNode -eq $ToNodeName){return}
    $output=Invoke-Command -ComputerName $ToNodeName -ScriptBlock {
		param($Cluster_Role_Name,$Node_Name)
        Write-host "Switching $Cluster_Role_Name to $Node_Name node"
		try {
			$info = Move-ClusterGroup -Name $Cluster_Role_Name -Node $Node_Name -ErrorAction Stop -Errorvariable isError
			Write-Host "`nSuccess!"
			Write-Host "The $($info.Name) role is switched to: $($info.OwnerNode)`nCluster status: $($info.State)"
			Write-host "`nCheck if cluster resources are offline, and try to run each one:"
			Start-ClusterGroup $Cluster_Role_Name -Verbose -ErrorAction Stop -Errorvariable isError
		}
        catch {
			foreach ($exception in $IsError) {
				Write-Error $($Exception.Exception.Message)
			}
		}
    } -ArgumentList @($RoleName, $ToNodeName)
    $output
}
Function Update-ClusterRoleOwners{
    param(
        [Parameter(Position = 0, Mandatory = $true)]
        [string]$FromNode,
        [Parameter(Position = 1, Mandatory = $true)]
        [string]$ToNode
    )
    $roles = Get-DbaWsfcRole -ComputerName $FromNode | where {!($_.Name -eq "Cluster Group") -and !($_.Name -eq "Available Storage")}
    write-host "Updating Cluster Role Owners"
    foreach ($role in $roles){
        if ($role.OwnerNode -eq $ToNode){continue}
        write-host "move $($role.Name) to $ToNode"
        Move-ClusterRole -RoleName $role.Name -ToNodeName $ToNode
    }
}
Function Restore-ClusterRoleOwners{
    param (
        [Parameter(Position = 0, Mandatory = $true)]
        $StateBefore
    )
    $roles = Get-DbaWsfcRole -ComputerName $StateBefore[0].OwnerNode | where {!($_.Name -eq "Cluster Group") -and !($_.Name -eq "Available Storage")}
    write-host "Restoring Cluster Role Owners"
    foreach ($item in $StateBefore) {
        $role = $roles | where {$_.Name -eq $item.Name}
        if ($item.OwnerNode -eq $role.OwnerNode){continue}
        write-host "move $($role.Name) to $($item.OwnerNode)"
        Move-ClusterRole -RoleName $role.Name -ToNodeName $item.OwnerNode
    }
}

function Get-HostsOfType {
    param(
        [Parameter(Position = 0, Mandatory = $true)]
        $ServerInfo
    )
    $servers = @()
    foreach ($Row in $ServerInfo) {
        $serverName = $Row.Server_Name.Trim()
        $serverType = $Row.Application_Server_Name.Trim()
        $isCluster = Get-DbaWsfcCluster $serverName
        if ($isCluster) {
            $nodes = Get-DbaWsfcNode $isCluster.Name
            foreach ($node in $nodes) {
                $servers+=[pscustomobject]@{
                    ServerName = $node.Name;
                    ServerType = $serverType 
                }
            }
        }
        else{
            $servers+=[pscustomobject]@{
                ServerName = $serverName;
                ServerType = $serverType 
            }
        }
    }
    return $servers
}


#region Function DeployMSI
Function DeployMSI {
    <#
        .SYNOPSIS
            Deploys the namd MSI from the DropFolder
            
        .DESCRIPTION
            Takes the name of an MSI to be deployed and looks for a named JSON to determine
            the properties and other attributes

        .PARAMETER  MSIFile
            The name and optionally relative drop folder path of the msi to install,
            if the file is not found it will be searched for from the drop folder.
            Only one must exist, any more and error will be thrown

        .PARAMETER  DropFolder
            The root folder where to find the MSI files, including sub-folders

        .PARAMETER  ProductNames
            An array of product names to uninstall before the MSI is installed

		.PARAMETER  ServerTag
            ServerTag defines which servers msi will be deployed to. Optional parametr can be setup in project's json. Otherwise this property is defined in MSI's json					 
        .PARAMETER NoLogoffUsers
            Switch if present will not log off users RPC sessions on target servers
    #>
    [CmdletBinding()]
    [OutputType([Bool])]
    Param(
        [Parameter(Position = 0, Mandatory = $true)]
        [System.String]$MSIFile,        
        [Parameter(Position = 1, Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [System.String]$DropFolder,
        [Parameter(Position = 2, Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [System.String[]]$ProductNames,
        [Parameter(Position = 3, Mandatory = $false)]
        [System.String[]]$ServerTag,
        
        [Switch]$NoLogoffUsers
    )
    try {
        # Bounded wait for the drop folder / MSI to become available, replacing a
        # legacy unconditional 'Start-Sleep -s 10'. Returns as soon as the MSI is
        # found; only waits (up to $DropFolderMaxWaitSeconds) when it isn't yet there.
        $DropFolderMaxWaitSeconds = 10
        $DropFolderPollSeconds = 1
        $DropFolderWaited = 0
        $msiFiles = @(Get-ChildItem -Path $DropFolder -Include $MSIFile -Recurse -ErrorAction SilentlyContinue)
        while ($msiFiles.Count -eq 0 -and $DropFolderWaited -lt $DropFolderMaxWaitSeconds) {
            Start-Sleep -Seconds $DropFolderPollSeconds
            $DropFolderWaited += $DropFolderPollSeconds
            $msiFiles = @(Get-ChildItem -Path $DropFolder -Include $MSIFile -Recurse -ErrorAction SilentlyContinue)
        }

        if ($msiFiles.Count -eq 0) {
            throw "[ERROR][DeployMSI][$(Get-Date)] Could not find any files named $($MSIFile) in $DropFolder"
        }
        
        if ($msiFiles.Count -gt 1) {
            throw "[ERROR][DeployMSI][$(Get-Date)] Found $($msiFiles.Count) files named $($MSIFile) in $DropFolder"
        }
        
        $msiFullPath = $msiFiles[0].FullName
        $settings = LoadMsiSettings "$($msiFullPath).json"

        $props = $settings.GetDeployPropertyNames()
        if ($props -ne $null -and $props.Count -gt 0) {
            $missingProperties = $false
            $invalidProperties = $false
            foreach ($propName in $props) {
                try {
                    $prop = Get-Variable -Name $propName -ErrorAction Stop
                    $propValue = Get-Variable -Name $propName -ValueOnly    			        
                    if ($propValue -match '["]') {
                        Write-Host "****WARNING: Property $($propName)'s value has characters that require escaping****"
                        $invalidProperties = $true
                    }            
                }
                catch {
                    Write-Host "****WARNING: Property $($propName) not defined. Skipped.****"
                    $missingProperties = $true
                }
            }
            if ($invalidProperties) {throw "`nOne or more properties' values have characters that require escaping which prevents the msi installation.`nPlease replace them with escape sequence."} 
            if ($missingProperties) {throw "`nOne or more properties undefined"}                
        }
        
        if ([string]::IsNullOrEmpty($settings.ServerType)) 
            {
            If ($ServerTag) 
                {
                $ServerTag = @($ServerTag)
                $settings = $settings | Add-Member -NotePropertyMembers @{ServerType=@($ServerTag)} -PassThru
                Write-Host "[DeployMSI][$(Get-Date)] ServerTag from project's json file has been used to define ServerType"
                }
            Else
                {
                throw "[ERROR][DeployMSI][$(Get-Date)] No ServerType type found in $($settings.FileName)"
                }
            }
        
        #set the var for further use within start-job scriptblock - it must be set to something to support "$using:"
        if ($GenericScript_StartServicesInEnvironment -ne "true") {
            $GenericScript_StartServicesInEnvironment = "false"
        }
        
        $ServerInfo = new-object "System.Data.DataTable"		
        $ServerInfo = GetServersOfType_V2 ($settings.ServerType)		
        if ($ServerInfo.Rows.Count -gt 0) {
            foreach ($Row in $ServerInfo) {
                $serverName = $Row.Server_Name.Trim()
                $serverType = $Row.Application_Server_Name.Trim()
                $msiArgs = $settings.GetPropertiesAsArrayList()
                    
                    # this is where we split workload to run in parallel
                    # first we want to cleanup any previous stale jobs for this env
                    Get-Job -Name "DeployMSI-$serverName" -ErrorAction SilentlyContinue | Where-Object { $_.State -ne "Running" } | Remove-Job -ErrorAction SilentlyContinue

                    # Here we need to establish which DOrc Runtime Vars exist in this Scope
                    $RuntimeVars = @{
                        BuildNumber                      = $BuildNumber
                        DeploymentLogDir                 = $DeploymentLogDir
                        ScriptRoot                       = $ScriptRoot
                        DropFolder                       = $DropFolder
                        EnvironmentName                  = $EnvironmentName
                        IsProd                           = $IsProd
                        DORC_ProdDeployUsername          = $DORC_ProdDeployUsername
                        DORC_ProdDeployPassword          = $DORC_ProdDeployPassword
                        DORC_NonProdDeployUsername       = $DORC_NonProdDeployUsername
                        DORC_NonProdDeployPassword       = $DORC_NonProdDeployPassword
                        DeploymentServiceAccount         = $DeploymentServiceAccount
                        DeploymentServiceAccountPassword = $DeploymentServiceAccountPassword
                        DBPermsOutput                    = $DBPermsOutput
                        MSILogsRoot                      = $MSILogsRoot
                        WiLogUtlPath                     = $WiLogUtlPath
                        DOrcSupportEmailSMTPServer       = $DOrcSupportEmailSMTPServer
                        DOrcSupportEmailFrom             = $DOrcSupportEmailFrom
                        DOrcSupportEmailTo               = $DOrcSupportEmailTo
                    }
                    
                    foreach ($RuntimeVar in $RuntimeVars.keys) {
                        if (-not (Get-Variable $RuntimeVar -ErrorAction SilentlyContinue)) {
                            Write-Verbose  -message "[VERBOSE][DeployMSI][$(Get-Date)] Setting $RuntimeVar with empty value, as it does not exist."
                            try { 
                                New-Variable -Name $RuntimeVar
                            }
                            catch {
                                Throw "[ERROR][DeployMSI][$(Get-Date)] New-Variable failed, full exception: `n$_"
                            }
                        }
                    }

                    Write-Host "[DeployMSI] [$(Get-Date)] Creating Separate Start-Job session for parallel execution for [$serverName]..."
                    
                    Start-Job -ScriptBlock {
                        # Create DOrc Runtime variables in this scope
                        $RuntimeVars = $using:RuntimeVars
                        
                        foreach ($RuntimeVarName in $RuntimeVars.keys) {
                            try {
                                Write-Verbose -Message "[VERBOSE][DeployMSI][$(Get-Date)] Creating DOrc Runtime Variable [$RuntimeVarName] with a value of [$($RuntimeVars[$RuntimeVarName])]"
                                New-Variable -Name $RuntimeVarName -Value $RuntimeVars[$RuntimeVarName] -Force
                            }
                            catch {
                                Throw "[ERROR][DeployMSI][$(Get-Date)] New-Variable Failed, full exception: `n$_"
                            }
                        }

                        if (Test-Connection $using:serverName -Count 1 -quiet) {

                            Write-Host "[INFO][DeployMSI][$(Get-Date)]" $using:serverName "is of type" $using:serverType "is alive and will be deployed to..."
                            
                            if ($using:NoLogoffUsers) {
                                Write-Host "[INFO][DeployMSI][$(Get-Date)] LogOffUsers skipped..."
                            }
                            elseif ((Check-IsCitrixServer -compName $using:serverName)) {
                                Write-Host "[INFO][DeployMSI][$(Get-Date)] LogOffUsers skipped because the target is Citrix..."
                            }
                            else {
                                LogOffUsers $using:serverName
                            }
                            
                            $settings = LoadMsiSettings "$($using:msiFullPath).json"
                            
                            if (($settings.ServicesToStop).Count -ne 0) {
                                foreach ($service in $settings.ServicesToStop) {
                                    Stop-Services $service $using:serverName
                                }
                            }

                            try {
                                foreach ($product in $using:ProductNames) {
                                    if ((DOrcDeployModule\RemoveMSI $using:serverName $using:msiFullPath $product)) {
                                        Write-Host "[INFO][DeployMSI][$(Get-Date)] Uninstalled $product from $($using:serverName)"
                                    }
                                    else {
                                        throw "[ERROR][DeployMSI][$(Get-Date)] Uninstall of $product from $($using:serverName)"
                                    }
                                }
                                
                                if (DOrcDeployModule\InstallMSI $using:serverName $using:msiFullPath $using:msiArgs) {
                                    Write-Host "[INFO][DeployMSI][$(Get-Date)] Install ok..."
                                }
                                else {
                                    throw "[ERROR][DeployMSI][$(Get-Date)] Problem installing the MSI..."
                                }

                                if ($using:GenericScript_StartServicesInEnvironment -eq "true") {
                                    if (($settings.ServicesToStart).Count -ne 0) {
                                        foreach ($service in $settings.ServicesToStart) {
                                            StartServices $service $using:serverName
                                        }
                                    }
                                }
                            }
                            catch {
                                Throw "[ERROR][DeployMSI][$(Get-Date)] `n$_"
                            }
                        }
                        else {
                            Throw "[ERROR][DeployMSI][$(Get-Date)] $using:ServerName is not online..."
                        }
                    } -Name "DeployMSI-$ServerName" | Out-Null
                }#foreach
            
                $jobs = @()
                foreach ($Row in $ServerInfo) {
                    $serverName = $Row.Server_Name.Trim()
                    $jobs += Get-Job -Name "DeployMSI-$serverName"
                }

                $ErrorMsg = $null
                foreach ($job in $jobs) {
                    Receive-Job -Job $job -Wait
                    if ($job.State -eq 'Failed') {
                        $errorMsg += "[$($job.Name)] $($job.ChildJobs[0].JobStateInfo.Reason.Message)`n"
                        Write-Host "[INFO][DeployMSI][$(Get-Date)] Removing PowerShell Job session for [$($job.Name)]..."
                        $job | Remove-Job
                    }
                    else {
                        Write-Host "[INFO][DeployMSI][$(Get-Date)] Removing PowerShell Job session for [$($job.Name)]..."
                        $job | Remove-Job
                    }
                }
                if ($ErrorMsg) {
                    Throw $errorMsg
                }
        }
        else {
            throw "[ERROR][DeployMSI][$(Get-Date)] No servers of type $($settings.ServerType) on $EnvironmentName to target ..."
        }
    }
    catch {
        throw
    }
}
#endregion Function DeployMSI

#region Function LoadJSONFromFile
Function LoadJSONFromFile {
    [CmdletBinding()]
    Param(
        [Parameter(Position = 0, Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [System.String]$Path
    )
    try {
        return (Get-Content $Path) -join "`n" | ConvertFrom-Json
    }
    catch {
        throw
    }
}
#endregion Function LoadJSONFromFile

#region Function LoadMsiSettings
Function LoadMsiSettings {
    Param
    (
        [String]$SettingsFile
    )
    try {
        if (-not (Test-Path -Path $SettingsFile -PathType Leaf)) {
            throw "[LoadMsiSettings] Cannot find $SettingsFile"
        }
        else {
            $settings = LoadJSONFromFile -Path $SettingsFile
        }
        Add-Member -InputObject $settings -MemberType NoteProperty -Name FileName -Value $SettingsFile

        
        # Add methods to settings object
        $getParameterValue = {
            Param([String]$Name)
            
            $varName = ($this.Parameters | Where-Object {$_.MSIParameter -eq $Name} ).DeployProperty
            return (Get-Variable -Name $varName -ValueOnly)
        }
        Add-Member -InputObject $settings -MemberType ScriptMethod -Name GetParameterValue -Value $getParameterValue        

        $getDeployPropertyNames = {
            
            $varNames = @()
            foreach ($param in $this.Parameters) {
                $varNames += $param.DeployProperty
            }
            return $varNames
        }
        Add-Member -InputObject $settings -MemberType ScriptMethod -Name GetDeployPropertyNames -Value $getDeployPropertyNames        
        $getPropertiesAsArrayList = {
            $arrParameters = New-Object System.Collections.ArrayList($null)
            foreach ($param in $this.Parameters) {
                [Void]$arrParameters.add("$($param.MSIParameter)=" + [char]34 + "$($this.GetParameterValue($param.MSIParameter))" + [char]34)
            }
            
            return $arrParameters
        }
        Add-Member -InputObject $settings -MemberType ScriptMethod -Name GetPropertiesAsArrayList -Value $getPropertiesAsArrayList

        return $settings
    }
    catch {
        throw
    }
}
#endregion Function LoadMsiSettings

function WasDbSnapped([string] $strInstance, [string] $strDatabase) {
    $bolSnapped = $false
    $connection = New-Object System.Data.SqlClient.SqlConnection
    $connection.ConnectionString = "Server=" + $strInstance + ";Database=master;Integrated Security=true"
    $connection.Open()
    $command = $connection.CreateCommand()
    $command.CommandText = "select m.physical_name from sys.master_files m inner join sys.databases d on (m.database_id = d.database_id) where d.name = '" + $strDatabase + "' and m.physical_name like '%.mdf%'"
    $table = new-object "System.Data.DataTable"
    $table.Load($command.ExecuteReader())
    $connection.Close()
    if ($table.Rows.Count -gt 0) {
        foreach ($Row in $table.Rows) {
            if ($Row.Item("physical_name").Contains("__")) {
                $bolSnapped = $true
            }
        }
    }
    $table = $null
    return $bolSnapped
}

function GetSQLServerName([string] $strInstance) {
    $strSQLServerName = ""
    $connection = New-Object System.Data.SqlClient.SqlConnection
    $connection.ConnectionString = "Server=" + $strInstance + ";Database=master;Integrated Security=true"
    $connection.Open()
    $command = $connection.CreateCommand()
    $command.CommandText = "SELECT SERVERPROPERTY('ServerName')"
    $table = new-object "System.Data.DataTable"
    $table.Load($command.ExecuteReader())
    $connection.Close()
    if ($table.Rows.Count -gt 0) {
        foreach ($Row in $table.Rows) {
            $strSQLServerName = $Row[0]
        }
    }
    $table = $null
    return $strSQLServerName
}

function Invoke-RemoteProcess([string] $serverName, [string] $strExecutable, [string] $strParams = "", [string] $strUser = "", [string] $strPassword = "", [switch]$IgnoreStdErr) {
    $bolResult = $true
    $strExecutableChild = $null

    # If the caller appended a child-process marker (e.g. NSIS ";Au_"), split
    # it off up-front so later UNC handling sees a clean path.
    if ($strExecutable.Contains(";")) {
        $strExecutableChild = $strExecutable.Split(";")[1]
        $strExecutable = $strExecutable.Split(";")[0]
    }

    # UNC inputs are staged onto the target via Copy-Item -ToSession further
    # down. That streams bytes over the WinRM channel using the client's own
    # identity, so the target never needs to reach back over SMB. This avoids
    # the Windows double-hop problem (net use with explicit /user: from within
    # a Network logon session fails with ERROR_NO_SUCH_LOGON_SESSION when the
    # share is DFS-backed). $strUser / $strPassword are retained in the
    # signature for backward-compatibility but are no longer consulted for UNC
    # inputs.
    $uncInput = $null
    if ($strExecutable.StartsWith("\\")) {
        write-host "    UNC path detected - will stage on target via PSSession:" $strExecutable
        $uncInput = $strExecutable
    }

    $session = New-PSSession -ComputerName $ServerName
    $stagedRemotePath = $null
    try {
        if ($uncInput) {
            # Resolve the target's TEMP directory rather than hard-coding
            # C:\Windows\Temp — Windows can be installed on a different drive
            # and %TEMP% on a service account is typically what we want anyway.
            $remoteTempDir = Invoke-Command -session $session { $env:TEMP }
            if ([string]::IsNullOrEmpty($remoteTempDir)) { $remoteTempDir = 'C:\Windows\Temp' }
            $stagedRemotePath = [IO.Path]::Combine($remoteTempDir, "dorc-" + [guid]::NewGuid().ToString('N') + "-" + [IO.Path]::GetFileName($uncInput))
            write-host "    Staging to target at:" $stagedRemotePath
            try {
                Copy-Item -ToSession $session -Path $uncInput -Destination $stagedRemotePath -Force -ErrorAction Stop
            } catch {
                write-host "    Copy-Item -ToSession failed:" $_.Exception.Message
                $bolResult = $false
                return $bolResult
            }
            $strExecutable = $stagedRemotePath
            write-host "    Executable (staged):" $strExecutable
        }
        $result = Invoke-Command -session $session {$result = $false; if (Test-Path -Path $($args[0]) -PathType Leaf) { $result = $true }; return $result} -ArgumentList $strExecutable
        if ($result) {
            write-host "Executing:" $strExecutable $strParams "on:" $ServerName
            Invoke-Command -session $session { $ProcessInfo = New-Object System.Diagnostics.ProcessStartInfo }
            Invoke-Command -session $session { $ProcessInfo.FileName = $($args[0]) } -ArgumentList $strExecutable
            Invoke-Command -session $session { $ProcessInfo.RedirectStandardError = $true }
            Invoke-Command -session $session { $ProcessInfo.RedirectStandardOutput = $true }
            Invoke-Command -session $session { $ProcessInfo.UseShellExecute = $false }
            Invoke-Command -session $session { $ProcessInfo.Arguments = $($args[0])} -ArgumentList $strParams
            Invoke-Command -session $session { $Process = New-Object System.Diagnostics.Process }
            Invoke-Command -session $session { $Process.StartInfo = $ProcessInfo }
            Invoke-Command -session $session { $Process.Start()}
            Invoke-Command -session $session { try { $out = $Process.StandardOutput.ReadToEndAsync() } catch {} }
            Invoke-Command -session $session { try { $outErr = $Process.StandardError.ReadToEndAsync() } catch {} }
            Invoke-Command -session $session { $Process.WaitForExit() }
            if (![String]::IsNullOrEmpty($strExecutableChild)) {
                do {
                    start-sleep 2
                    write-host "    Checking for child process:" $strExecutableChild
                    $remProcs = Invoke-Command -session $session { $result = Get-Process $($args[0]) -ErrorAction SilentlyContinue | measure ; return $result } -ArgumentList $strExecutableChild
                    $remProcs.Count
                } while ($remProcs.Count -gt 0)
                $remProcs = $null
            }
            $execResult = Invoke-Command -session $session { return $Process.ExitCode }
            write-host "    Remote execution complete, exit code:" $execResult
            if ($execResult -ne 0) { $bolResult = $false }
            $stdOut = Invoke-Command -session $session { return $out.Result}
            $stdErr = Invoke-Command -session $session { return $outErr.Result }
            Invoke-Command -session $session { $outErr, $out, $Process, $ProcessInfo = $null }
            if ($stdOut.Length -gt 0) {
                if ($stdOut.Contains([char]10)) {
                    foreach ($strLine in $stdOut.Split([char]10)) {
                        write-host "    Stdout:" $strLine
                    }
                }
                else { write-host "    Stdout:" $stdOut }
                write-host ""

            }
            if ($stdErr.Length -gt 0) {
                if (!$IgnoreStdErr) {$bolResult = $false}
                if ($stdErr.Contains([char]10)) {
                    foreach ($strLine in $stdErr.Split([char]10)) {
                        write-host "    StdERR:" $strLine
                    }
                }
                else { write-host "    StdERR:" $stdErr }
                write-host ""
            }
            $stdOut, $stdErr = $null
        }
        else {
            write-host "    Unable to find:" $strExecutable "from" $ServerName
            $bolResult = $false
        }
    } finally {
        if ($stagedRemotePath) {
            try {
                Invoke-Command -session $session { Remove-Item -Path $($args[0]) -Force -ErrorAction SilentlyContinue } -ArgumentList $stagedRemotePath | Out-Null
            } catch { }
        }
        # Session teardown can throw if the session has already faulted;
        # swallow to keep the real execution result intact.
        try { Remove-PSSession $session -ErrorAction SilentlyContinue } catch { }
    }
    write-host "bolResult:" $bolResult
    return $bolResult
}

function Open-RemoteRegistryHive([string] $serverName) {
    return [Microsoft.Win32.RegistryKey]::OpenRemoteBaseKey('LocalMachine', $serverName)
}

function Test-IsRunningAsAdministrator {
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Find-RemoteNSIS([string] $serverName, [string] $productString) {
    $strUninstallString = "None"
    $Reg = Open-RemoteRegistryHive $serverName
    $RegKey_x32 = $Reg.OpenSubKey("SOFTWARE\\Wow6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall")
    $RegKey_x64 = $Reg.OpenSubKey("SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall")
    foreach ($subKeyName in $RegKey_x32.GetSubKeyNames()) {
        if ($subKeyName.ToString().Contains($productString)) {
            write-host "Found:" $subKeyName.ToString()
            $erlangKey = $RegKey_x32.OpenSubKey($subKeyName.ToString())
            $strUninstallString = $erlangKey.GetValue("UninstallString")
        }
    }
    foreach ($subKeyName in $RegKey_x64.GetSubKeyNames()) {
        if ($subKeyName.ToString().Contains($productString)) {
            write-host "Found:" $subKeyName.ToString()
            $erlangKey = $RegKey_x64.OpenSubKey($subKeyName.ToString())
            $strUninstallString = $erlangKey.GetValue("UninstallString")
        }
    }
    $erlangKey, $RegKey_x32, $RegKey_x64, $Reg = $null
    if ([string]::IsNullOrEmpty($strUninstallString)) { return "None" }
    return $strUninstallString.Trim('"')
}

function Remove-NSISErlang([string] $serverName) {
    $arrDirectories = New-Object System.Collections.ArrayList($null)
    $remErlang = Find-RemoteNSIS $serverName "Erlang"
    $maxAttempts = 5
    $attempts = 0
    do {
        if ($remErlang -ne "None") {
            if ($attempts -ge $maxAttempts) {
                throw "Remove-NSISErlang: exceeded $maxAttempts attempts on $serverName; uninstall string '$remErlang' still present after each attempt. The uninstall registry entry may be stale (pointing at a file that no longer exists)."
            }
            $attempts++
            write-host "    Uninstall string:" $remErlang
            $remErlang += ";Au_"
            $bolResult = (Invoke-RemoteProcess $serverName $remErlang "/S")[0]
            write-host "[Remove-NSISErlang] Result:" $bolResult
            if (!$bolResult) { throw "    Failed to remove..."}
            [Void]$arrDirectories.add("\\" + $serverName + "\" + $remErlang.SubString(0, $remErlang.LastIndexOf("\")).Replace(":", "$"))
            $remErlang = Find-RemoteNSIS $serverName "Erlang"
        }
    } while ($remErlang -ne "None")
    foreach ($remDir in $arrDirectories) {
        write-host "    Checking:" $remDir
        if (Test-Path -Path $remDir -PathType Container) {
            write-host "    Removing:" $remDir
            remove-item $remDir -recurse -force -verbose
        }
    }
    $remErlang, $bolResult, $arrDirectories = $null
}

function Remove-NSISRabbitMQ([string] $serverName) {
    $arrDirectories = New-Object System.Collections.ArrayList($null)
    $remRabbit = Find-RemoteNSIS $serverName "RabbitMQ"
    $maxAttempts = 5
    $attempts = 0
    do {
        if ($remRabbit -ne "None") {
            if ($attempts -ge $maxAttempts) {
                throw "Remove-NSISRabbitMQ: exceeded $maxAttempts attempts on $serverName; uninstall string '$remRabbit' still present after each attempt. The uninstall registry entry may be stale (pointing at a file that no longer exists)."
            }
            $attempts++
            write-host "    Uninstall string:" $remRabbit
            $remRabbit += ";Au_"
            $bolResult = (Invoke-RemoteProcess $serverName $remRabbit "/S")[0]
            write-host "[Remove-NSISRabbitMQ] Result:" $bolResult
            if (!$bolResult) { throw "    Failed to remove..."}
            [Void]$arrDirectories.add("\\" + $serverName + "\" + $remRabbit.SubString(0, $remRabbit.LastIndexOf("\")).Replace(":", "$"))
            $remRabbit = Find-RemoteNSIS $serverName "RabbitMQ"
        }
    } while ($remRabbit -ne "None")
    foreach ($remDir in $arrDirectories) {
        write-host "    Checking:" $remDir
        if (Test-Path -Path $remDir -PathType Container) {
            write-host "    Removing:" $remDir
            remove-item $remDir -recurse -force -verbose
        }
    }
    $remRabbit, $bolResult, $arrDirectories = $null
}

function Set-RemoteSystemVar {
    param (
    [string] $serverName, 
    [string] $varName, 
    [string] $value,
    [switch] $Add
    )
    
    try {
        $session = New-PSSession -ComputerName $serverName
    }
    catch {
        Remove-PSSession $session
        Throw "Failed to establish remote PS session to [$serverName]`n"
    }
    
    if ($add) {
        try {
            $existingValue = Invoke-Command -session $session { [System.Environment]::GetEnvironmentVariable($($args[0]), "Machine")} -ArgumentList $varName
        }
        catch {
            Remove-PSSession $session
            Throw "Failed to get existing value of System Variable [$varName]`n"
        }       
        Write-host "[DEBUG] Existing value of System Variable [$varName] `"$existingValue`"`n"
        #now add it to the value variable for later use
        $value = $existingValue + ";" + $value
    }
    
    try {
        Write-host "[VERBOSE] Setting System Variable [$varName] to `"$value`"`n"
        Invoke-Command -session $session { [System.Environment]::SetEnvironmentVariable($($args[0]), $($args[1]), "Machine")} -ArgumentList $varName, $value
    }
    catch {
        Remove-PSSession $session
        Throw "Failed to set System Variable [$varName] to [$value]`n"
    }
    
    Remove-PSSession $session
}

function Get-EndurDbVersion
(
  [Parameter(Position = 0, Mandatory = $true)] [string] $endurDbServer,
  [Parameter(Position = 1, Mandatory = $true)] [string] $endurDb
)
{
    $dataTable = New-Object System.Data.DataTable
    $sqlConnection = New-Object System.Data.SQLClient.SQLConnection
    $sqlQuery = "SELECT TOP 1 [major],[minor],[revision],[build] FROM [" + $endurDb + "].[dbo].[version_number]"
    $sqlConnection.ConnectionString = "Server=$endurDbServer;Database=$endurDb;Integrated Security=True"
    $sqlConnection.Open()
    $command = New-Object System.Data.SQLClient.SQLCommand
    $command.Connection = $sqlConnection
    $command.CommandText = $sqlQuery
    $reader = $command.ExecuteReader()
    $dataTable.Load($reader)
    $sqlConnection.Close()
    $ver = $dataTable.Rows[0][0].ToString() + "." + $dataTable.Rows[0][1].ToString() + "." + $dataTable.Rows[0][2].ToString() + "." + $dataTable.Rows[0][3].ToString()
    $reader, $command, $sqlConnection, $dataTable, $sqlQuery = $null
    return $ver
}

function GetDbInfoByTypeForEnvWithArray([string] $strEnvironment, [string] $strType) {
    $DOrcToken = Get-DorcToken 
    $DorcAPIHeaders = @{
        "Authorization" = "Bearer $DOrcToken" 
    }
    $uri=$RefDataApiUrl + 'RefDataEnvironments?env=' + $strEnvironment
	write-host "GetDbInfoByTypeForEnvWithArray Uri is:" $uri
    $EnvId=(Invoke-RestMethod -Uri $uri -method Get -Headers $DorcAPIHeaders -ContentType 'application/json').EnvironmentId
	write-host "EnvId" $EnvId 
    $uri=$RefDataApiUrl + 'RefDataEnvironmentsDetails/' + $EnvId
	write-host "EnvironmentDetails Uri is:" $uri
    $table=Invoke-RestMethod -Uri $uri -method Get -Headers $DorcAPIHeaders -ContentType 'application/json'
    $table=$table.DbServers | where {$_.Type -eq $strType} | Select Name, ServerName, ArrayName
    $strResult="Invalid"
    if ($table.Name.count -eq 0) {
        Write-Host "No entries returned for" $strEnvironment $strType 
    }
    elseif ($table.Name.Count -eq 1) {
            $strResult = $table.ServerName + ":" + $table.Name + ":" + $table.ArrayName
    }
    else {
        throw "Too many entries for $strEnvironment $strType"
    }
    return $strResult
}

function Snap-Database 
(
    [Parameter(Position = 0, Mandatory = $true)] [string] $dropFolder,
    [Parameter(Position = 1, Mandatory = $true)] [string] $dacpacName,
    [Parameter(Position = 2, Mandatory = $true)] [string] $envMgtDBServer, 
    [Parameter(Position = 3, Mandatory = $true)] [string] $envMgtDBName,
    [Parameter(Position = 4, Mandatory = $true)] [string] $restoreMode,
    [Parameter(Position = 5, Mandatory = $true)] [string] $restoreSource
)
{
    $result = $true
    $rows = (Get-ChildItem -Path $dropFolder -Recurse)
    $dacpacFile = $null
    foreach ($row in $rows) {
        if ($row.Name.Equals($dacpacName)) { $dacpacFile = $row.FullName }   
    }
    if ([String]::IsNullOrEmpty($dacpacFile)) { write-host "Couldn't locate" $dacpacName "in" $dropFolder ; $result = $false }
    else {
        $jsonFile = $dacpacFile.TrimEnd("dacpac") + "restore.json"
        $postRestoreFile = $dacpacFile.TrimEnd("dacpac") + "postrestore.sql"
        If (!(Test-Path $dacpacFile)) { write-host "Cannot find:" $dacpacName ; $result = $false }
        If (!(Test-Path $jsonFile)) { write-host "Cannot find JSON " $dacpacName; $result = $false }
        write-host "JSON settings:" $jsonFile
        $jsonParams = LoadJSONFromFile $jsonFile		
        switch ($RestoreSource.ToLower()) {
            "prod" { $SourceInfo = (GetDbInfoByTypeForEnvWithArray $jsonParams.SourceEnvProd $jsonParams.DatabaseType) }
            "staging" { $SourceInfo = (GetDbInfoByTypeForEnvWithArray $jsonParams.SourceEnvStaging $jsonParams.DatabaseType) }
            default { write-host "RestoreSource should be prod or staging..." $result = $false }
        }
        if (!($SourceInfo.Contains(":"))) { write-host "Source database information could not be retrived for db type:" $jsonParams.DatabaseType "in" $jsonParams.SourceEnvProd ; $result = $false }
        $strEnvMgtConnString = "Server=" + $EnvMgtDBServer + ";Database=" + $EnvMgtDBName + ";Integrated Security=true"
        $TargetInfo = (GetDbInfoByTypeForEnvWithArray $EnvironmentName $jsonParams.DatabaseType)
        if (!($TargetInfo.Contains(":"))) { write-host "Target database information could not be retrived for db type:" $jsonParams.DatabaseType "in" $EnvironmentName ; $result = $false }
        if ($TargetInfo -eq $SourceInfo) { write-host "Source and target the same!" ; $result = $false }
        $TargetDB = ($TargetInfo.Split(":"))[1]
        $TargetInstance = GetSQLServerName ($TargetInfo.Split(":"))[0]
        $SourceDB = ($SourceInfo.Split(":"))[1]
        $SourceInstance = GetSQLServerName ($SourceInfo.Split(":"))[0]
        $array =  ($SourceInfo.Split(":"))[2]
        write-host ""
        write-host "Source:" $SourceInstance"."$SourceDB
        write-host "Target:" $TargetInstance"."$TargetDB
        write-host "Array: " $array
        write-host ""

        if ([string]::IsNullOrEmpty($array)) { write-host "Cannot continue as the Array information is not valid..." ; $result = $false } 
        if ($result) {
            # Restore
            Switch ($RestoreMode.ToLower()) {
                "latest" { Invoke-PureSQLSnapshotCopy -SourceDatabase $SourceDB -SourceSQLServer $SourceInstance -DestinationDatabase $TargetDB -DestinationSQLServer $TargetInstance -PureArrayName $array }
            }

            # Permissions
            $TargetInstance = ($TargetInfo.Split(":"))[0]
            Apply-DatabasePermissions -instance $TargetInstance -database $TargetDB

            # Simple Recovery Model
 #           if ($SimpleRecoveryModel)
 #           {
                Write-Host "Setting Simple Recovery Model for " $TargetInstance"."$TargetDB
                $RecoveryModelresult = Invoke-Sqlcmd -ServerInstance $TargetInstance -Query "ALTER DATABASE $TargetDB SET RECOVERY SIMPLE" -QueryTimeout 600 -TrustServerCertificate -ErrorAction 'Stop' -OutputSqlErrors $true 
                $RecoveryModelresult
  #          }

            # Post restore SQL
            if (Test-Path $postRestoreFile)
            {
                Write-Host "Applying:" $postRestoreFile "on" $TargetInstance"."$TargetDB
                $postRestoreresult = Invoke-Sqlcmd -ServerInstance "$TargetInstance" -Database "$TargetDB" -InputFile $postRestoreFile -QueryTimeout 600 -TrustServerCertificate -ErrorAction 'Stop' -OutputSqlErrors $true 
                $postRestoreresult
            }
            else {write-host "$postRestoreFile not found..."}
        }
    }
    return $result
}

function Check-ProductInstalled
(
    [Parameter(Position = 0, Mandatory = $true)] [string] $serverName,
    [Parameter(Position = 1, Mandatory = $true)] [string] $productName
)
{
    $installed = $false
    $products = Get-CimInstance -ClassName Win32_Product -ComputerName $serverName
    foreach ($product in $products) { if ($product.Name.ToLower() -eq $productName.ToLower()) { $installed = $true } }
    $products = $null
    return $installed
}

function Install-WindowsFeaturesDorc
(
    [Parameter(Position = 0, Mandatory = $true)] [string] $targetServerType,
    [Parameter(Position = 1, Mandatory = $true)] [string] $baseBuildFeatures,
    [Parameter(Position = 2, Mandatory = $true)] [string] $deploymentServiceAccount,
    [Parameter(Position = 3, Mandatory = $true)] [string] $deploymentServiceAccountPassword,
    [Parameter(Position = 4, Mandatory = $true)] [string] $coreCodeSxSFolder
)
{
    $ProgressPreference = 'SilentlyContinue'
    $ServerInfo = new-object "System.Data.DataTable"
    $ServerInfo = GetServersOfType $EnvironmentName $targetServerType
    if ($ServerInfo.Rows.Count -gt 0) {
        foreach ($Row in $ServerInfo) {
            $serverName = $Row.Server_Name.Trim()
            $serverType = $Row.Application_Server_Name.Trim()
            $remOS = Get-CimInstance -ClassName Win32_OperatingSystem -ComputerName $serverName
            if ($remOS.Name -match "2008") {
                write-host "[Install-WindowsFeaturesDorc] Target server O/S is 2008, skipping:" $serverName
            }
            elseif (Test-Connection $serverName -Count 1 -quiet) {
                Write-Host "[Install-WindowsFeaturesDorc]" $serverName "is of type" $serverType "is alive and will be deployed to..."
                if ($BaseBuildFeatures.Contains(";")) {
                    $features = $BaseBuildFeatures.Split("`;")
                }
                else {
                    $features = $BaseBuildFeatures
                }
                if ($BaseBuildFeatures -match "Web-Server") {
                    write-host "[Install-WindowsFeaturesDorc]     Removing IIS..."
                    Uninstall-WindowsFeature -Name "Web-Server" -ComputerName $serverName -WarningAction SilentlyContinue
                    Restart-Servers $serverName
                }
                $session = New-PSSession -ComputerName $serverName
                Invoke-Command -session $session {$ProgressPreference ='SilentlyContinue'}
                Invoke-Command -session $session {net use * /d /y 2>&1>null}
                Invoke-Command -session $session {net use * $($args[0]) $($args[1]) /user:$($args[2]) 2>&1>null} -ArgumentList $coreCodeSxSFolder, $DeploymentServiceAccountPassword, $DeploymentServiceAccount
                foreach ($feature in $features) {
                    $result = Get-WindowsFeature -Name $feature -ComputerName $serverName
                    if ($result.Installed){
                        write-host "[Install-WindowsFeaturesDorc]     Already installed:" $feature
                    }
                    else {
                        write-host "[Install-WindowsFeaturesDorc]     Installing:" $feature
                        try {
                            Invoke-Command -session $session {Install-WindowsFeature -Name $($args[0]) -Source $($args[1]) -WarningAction SilentlyContinue -ErrorAction Stop} -ArgumentList $feature, $coreCodeSxSFolder -ErrorAction Stop
                        }
                        catch {
                            Write-Error -Message "Exectution of this command failed: `nInstall-WindowsFeature -Name $feature -Source $coreCodeSxSFolder; Exception: `n$_"
                        }
                    }
                }
                Invoke-Command -session $session {net use * /d /y 2>&1>null}
                Remove-PSSession $session
                Restart-Servers $ServerName
            }
            else {
                throw "$ServerName is not online..."
            }
            Write-Host ""
        }
    }
    else {
        write-host "No servers to target..."
    }
}

function Apply-DatabasePermissions 
(
    [Parameter(Position = 0, Mandatory = $true)] [string] $instance,
    [Parameter(Position = 1, Mandatory = $true)] [string] $database
)
{
        write-host ""
        write-host "[Apply-DatabasePermissions] Processing:" $instance"."$database
        $strStatus = GetDBStatus $instance $database 
        if ($strStatus -eq "Normal") {
            Write-Host "[Apply-DatabasePermissions] Processing:" $instance"."$database "is" $strStatus
            $outputFolder = $DBPermsOutput + "\" + (GetDateReverse) + "-" + $instance.Replace("\", "_") + "." + $database
            Write-Host "[Apply-DatabasePermissions] Output folder:" $outputFolder
            Get-DBPermissions -server $instance -database $database -outputFilepath $outputFolder
            if ((Test-Path $outputFolder -PathType Container) -and ((Get-Childitem $outputFolder -Recurse -File -Filter *.sql | Measure-Object | ForEach-Object{$_.Count}) -gt 0)) {
                write-host "[Apply-DatabasePermissions] Permissions extract does exist...:" $instance"."$database
                write-host "[Apply-DatabasePermissions] Applying permissions to:" $instance"."$database                
                write-host "[Apply-DatabasePermissions] Using:" $ApplyPermissionsExePath
                $args = "/instance:$instance /database:$database /prod:$IsProd"
                $tmpOutput = New-TemporaryFile
                start-process -FilePath $ApplyPermissionsExePath -ArgumentList $args -RedirectStandardOutput $tmpOutput -Wait
                $permsOutput = Get-Content -Path $tmpOutput
                foreach ($line in $permsOutput) { write-host "[Apply-DatabasePermissions]" $line}
                Remove-Item $tmpOutput.FullName -Force
            } else { write-host "[Apply-DatabasePermissions] SQL extract has not succeeded to permissions will not be reset..." }
        } else { write-host "[Apply-DatabasePermissions] Database is not in the normal state..." }
}

function Check-ProductInstalledReg
(
    [Parameter(Position = 0, Mandatory = $true)] [string] $serverName,
    [Parameter(Position = 1, Mandatory = $true)] [string] $productName
)
{
    $installed = $false
    $reg = [Microsoft.Win32.RegistryKey]::OpenRemoteBaseKey("LocalMachine",$serverName)
    $uninstKey = "SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
    $subkey = $reg.OpenSubKey($uninstKey)
    $subs = $subkey.GetSubKeyNames()
    foreach ($key in $subs) {
        $productKey = $uninstKey + "\" + $key
        $prodKey = $reg.OpenSubKey($productKey)
        $dispName = $prodKey.GetValue("DisplayName")
        if (!([String]::IsNullOrEmpty($dispName))) { if ($dispName.ToLower() -eq $productName.ToLower()) { $installed = $true } }
    }
    return $installed
}

function Add-ToRemoteSystemPath (
    [Parameter(Position = 0, Mandatory = $true)] [string] $comp,
    [Parameter(Position = 1, Mandatory = $true)] [string] $newPath
)
{
    $remPath = Invoke-Command -ComputerName $comp { [Environment]::GetEnvironmentVariable("Path","Machine") }
    if ($remPath.ToLower().Contains($newPath.ToLower())) { write-host $newPath "is already in the path on $comp" }
    else {
        $newFullPath = $remPath.TrimEnd(";") + ";" + $newPath
        write-host "Setting path to:" $newFullPath
        $session = New-PSSession -ComputerName $comp
        Invoke-Command -session $session { Set-ItemProperty -Path 'Registry::HKEY_LOCAL_MACHINE\System\CurrentControlSet\Control\Session Manager\Environment' -Name PATH -Value $($args[0]) -Force } -ArgumentList $newFullPath
        Remove-PSSession -Session $session
    }
}

function Add-ADO2LocalGroup
(
    [Parameter(Position = 0, Mandatory = $true)] [string] $comp,
    [Parameter(Position = 1, Mandatory = $true)] [string] $localGroup,
    [Parameter(Position = 2, Mandatory = $true)] [string] $adoItem,
    [Parameter(Position = 3, Mandatory = $true)] [string] $user,
    [Parameter(Position = 4, Mandatory = $true)] [string] $pass
)
{
    if (Test-Connection $comp) {
        if ($adoItem.ToLower().Contains($DomainAdoItem)) { $adoItem = $adoItem.ToLower().Replace($DomainAdoItem, "") }
		$ado = Get-ADObject -Filter {(SamAccountName -eq $adoItem)}
		$adoClass = $ado.ObjectClass
		if (($adoClass -eq "user") -or ($adoClass -eq "group")) {
			$passwd = ConvertTo-SecureString $pass -AsPlainText -Force
			$cred = New-Object System.Management.Automation.PSCredential ($user, $passwd)
			$session = New-PSSession -ComputerName $serverName -Credential $cred
			write-host "[Add-ADO2LocalGroup] Adding: $adoItem ($adoClass) to $localGroup on: $serverName"
			Invoke-Command -session $session { $group = [ADSI]("WinNT://"+$env:COMPUTERNAME+"/$($args[0]),group") } -ArgumentList $localGroup
			Invoke-Command -session $session { $group.add("WinNT://$env:USERDOMAIN/$($args[0]),$($args[1])") } -ArgumentList $adoItem, $adoClass
			Remove-PSSession -Session $session
		} else { write-host "[Add-ADO2LocalGroup] INVALID: $adoItem" }
    } else { write-host "[Add-ADO2LocalGroup] FAIL: Could not ping $comp" }
}

function Setup-VMAccess 
(
    [Parameter(Position = 0, Mandatory = $true)] [string] $env,
    [Parameter(Position = 1, Mandatory = $true)] [string] $serverTypeFilter,
    [Parameter(Position = 2, Mandatory = $true)] [string] $recUser,
    [Parameter(Position = 3, Mandatory = $true)] [string] $recPassword,
    [Parameter(Position = 4, Mandatory = $true)] [string] $dorcUser,
    [Parameter(Position = 5, Mandatory = $true)] [string] $remoters,
    [Parameter(Position = 6, Mandatory = $true)] [string] $localAdmins,
    [Parameter(Position = 7, Mandatory = $true)] [string] $logonAsService
)
{
    $ServerInfo = new-object "System.Data.DataTable"
    $ServerInfo = GetServersOfType $EnvironmentName $serverTypeFilter
    foreach ($Row in $ServerInfo) {
        $serverName = $Row.Server_Name.Trim()
        if (Test-Connection $serverName) {
            write-host "[Setup-VMAccess] Processing: $serverName"
            Add-ADO2LocalGroup -comp $serverName -localGroup "administrators" -adoItem $dorcUser -user $recUser -pass $recPassword
            if ($localAdmins -eq "null"){
                write-host "[Setup-VMAccess] No local admins to add..."
            } else {
                if (($EnvironmentName -match "dv") -or ($EnvironmentName -match "dev")) {
                    write-host "[Setup-VMAccess] DV Server detected..."
                    if ($localAdmins -match ";") { $localAdminsAll = $localAdmins.Split(";") } else { $localAdminsAll = $localAdmins }
                    foreach ($localAdmin in $localAdminsAll) {
                        Add-ADO2LocalGroup -comp $serverName -localGroup "administrators" -adoItem $localAdmin -user $recUser -pass $recPassword
                    }
                }
            }
            if ($remoters -eq "null"){
                write-host "[Setup-VMAccess] No remoters to add..."
            } else {
                if ($remoters -match ";") { $remotersAll = $remoters.Split(";") } else { $remotersAll = $remoters }
                foreach ($remoter in $remotersAll) {
                    Add-ADO2LocalGroup -comp $serverName -localGroup "Remote Desktop Users" -adoItem $remoter -user $recUser -pass $recPassword
                    Add-ADO2LocalGroup -comp $serverName -localGroup "Event Log Readers" -adoItem $remoter -user $recUser -pass $recPassword
                }
            }
            if ($logonAsService -eq "null"){
                write-host "[Setup-VMAccess] No Logon As Service rights to add..."
            } else {
                if ($logonAsService -match ";") { $logonAsServiceAll = $logonAsService.Split(";") } else { $logonAsServiceAll = $logonAsService }
                foreach ($las in $logonAsServiceAll) {
                    write-host "[Setup-VMAccess] Granting Logon As Service to: $las"
                    Grant-UserRight -Account $las -Right SeServiceLogonRight -Computer $ServerName
                }
            }
        } else { write-host "[Setup-VMAccess] FAIL: Could not ping $serverName" }
    }
}

function Get-ServerIDs 
(
    [Parameter(Position = 0, Mandatory = $true)] [string] $environment,
    [Parameter(Position = 1, Mandatory = $true)] [string] $serverType
)
{
    $ServerInfo = new-object "System.Data.DataTable"
    $ServerInfo = GetServersOfType $environment $serverType
    if ($ServerInfo.Rows.Count -gt 0) {
        foreach ($Row in $ServerInfo) {
            $serverName = $Row.Server_Name.Trim()
            $serverType = $Row.Application_Server_Name.Trim()
            try {
                [guid]$id = icm $serverName {(get-wmiobject Win32_ComputerSystemProduct).UUID} -ErrorAction Stop
                $result += $serverName.ToUpper() + ":" + $id + ";"
            }
            catch {
                Write-Host "[Get-ServerIDs] Server $ServerName not reachable. This is expected for a new build."
                $result += $serverName.ToUpper() + ":" + "Not Reachable" + ";"
            }
            
        }
    } else { write-host "[Get-ServerIDs] No servers..." }
    return $result
}

function Check-ServerIDsDifferent
(
    [Parameter(Position = 0, Mandatory = $true)] [string] $environment,
    [Parameter(Position = 1, Mandatory = $true)] [string] $serverType,
    [Parameter(Position = 2, Mandatory = $true)] [string] $previousIDs
)
{
    $result = $true
    $ServerInfo = new-object "System.Data.DataTable"
    $ServerInfo = GetServersOfType $environment $serverType
    if ($ServerInfo.Rows.Count -gt 0) {
        foreach ($Row in $ServerInfo) {
            $serverName = $Row.Server_Name.Trim()
            $serverType = $Row.Application_Server_Name.Trim()
            try {
                [guid]$id = icm $serverName {(get-wmiobject Win32_ComputerSystemProduct).UUID} -ErrorAction Stop
            }
            catch {
                Write-Host "[Get-ServerIDs] Server $ServerName not reachable. This is expected for a new build."
                continue
            }
            $nowID = $serverName.ToUpper() + ":" + $id
            if ($previousIDs -match $nowID) {
                write-host "[Check-ServerIDsDifferent] FAIL:" $serverName "has the same ID:" $id
                $result = $false
            } else { write-host "[Check-ServerIDsDifferent] Pass:" $serverName "has a new ID:" $id }
        }
    } else { write-host "No servers..." }
    return $result
}

function Deploy-SSISPackages
(
    [Parameter(Position = 0, Mandatory = $true)] [string] $environment,
    [Parameter(Position = 1, Mandatory = $true)] [string] $packageFolderRoot,
    [Parameter(Position = 2, Mandatory = $true)] [string] $ssisServer,
    [Parameter(Position = 2, Mandatory = $true)] [string] $ssisDb
)
{
	Try {
		$result = $false
		[Reflection.Assembly]::LoadWithPartialName("Microsoft.SqlServer.Management.IntegrationServices")
		$ISNamespace = "Microsoft.SqlServer.Management.IntegrationServices"
		$sqlConnectionString = "Data Source=$ssisServer;Initial Catalog=master;Integrated Security=SSPI;"
		Write-Host "Cxn String: " + $sqlConnectionString
		$sqlConnection = New-Object System.Data.SqlClient.SqlConnection $sqlConnectionString
		$integrationServices = New-Object "$ISNamespace.IntegrationServices" $sqlConnection
		$catalog = $integrationServices.Catalogs.get_Item($ssisDb)
		if ($catalog.Name.ToLower() -eq $ssisDb.ToLower()) {
			Write-Host "[Deploy-SSISPackages] Checking for folder: $environment"
			$ispacs = Get-Childitem $packageFolderRoot -Recurse -File -Filter *.ispac
			$folder = $catalog.Folders[$environment]
			if (!$folder) {
				Write-Host "[Deploy-SSISPackages] Creating Folder: $environment"
				$folder = New-Object "$ISNamespace.CatalogFolder" ($catalog, $environment, $environment)            
				$folder.Create()  
			}
			foreach ($ispac in $ispacs) {
				$exists = $false
				foreach ($project in $folder.Projects) {
					if ($ispac.Name.ToLower() -match $project.Name.ToLower()) {
						$exists = $true
						$projectToRemove = $project
					}
				}
				if ($exists) {
					$removeText = $environment + "\Projects\" + $project.Name
					Write-Host "[Deploy-SSISPackages] Removing: " $removeText
					$folder.Projects.Remove($projectToRemove)
					$folder.Alter()
				}
				Write-Host "[Deploy-SSISPackages] Deploying:" $ispac.FullName
				[byte[]] $projectFile = [System.IO.File]::ReadAllBytes($ispac.FullName)            
				$folder.DeployProject($ispac.Name.Replace(".ispac", ""), $projectFile)
			}
			$integrationServices, $catalog, $folder = $null
			$integrationServices = New-Object "$ISNamespace.IntegrationServices" $sqlConnection
			$catalog = $integrationServices.Catalogs.get_Item($ssisDb)
			$folder = $catalog.Folders[$environment]
			foreach ($project in $folder.Projects) {
				if ($ispac.Name.ToLower() -match $project.Name.ToLower()) {
					write-host "[Deploy-SSISPackages] Verified: " $project.IdentityKey
					$result = $true
				}
			}
			$integrationServices, $catalog, $folder = $null
		} else { Write-Host "[Deploy-SSISPackages] Failed to connect to SSIS server $ssisServer.$ssisDb" }
		return $result
	}
	Catch {
        Write-Host "Error during deploy of ssis package:"
        Write-Host $_
        throw
	}
	Finally {
		
	}
}

function Set-SSISPackageParamters
(
    [Parameter(Position = 0, Mandatory = $true)] [string] $environment,
    [Parameter(Position = 1, Mandatory = $true)] [string] $packageFolderRoot,
    [Parameter(Position = 2, Mandatory = $true)] [string] $ssisServer,
    [Parameter(Position = 2, Mandatory = $true)] [string] $ssisDb
)
{
    Try {
    $result = $false
    $mask = "*******************************************************************************************************************************************************"
    [Reflection.Assembly]::LoadWithPartialName("Microsoft.SqlServer.Management.IntegrationServices")
    $ISNamespace = "Microsoft.SqlServer.Management.IntegrationServices"
    $sqlConnectionString = "Data Source=$ssisServer;Initial Catalog=master;Integrated Security=SSPI;"
    $sqlConnection = New-Object System.Data.SqlClient.SqlConnection $sqlConnectionString
    $integrationServices = New-Object "$ISNamespace.IntegrationServices" $sqlConnection
    $catalog = $integrationServices.Catalogs.get_Item($ssisDb)
    $folder = $catalog.Folders[$environment]
    $envVarsSet = $false
    
    $DOrcToken = Get-DorcToken 
    $DorcAPIHeaders = @{
        "Authorization" = "Bearer $DOrcToken" 
    }

    if ($catalog.Name.ToLower() -eq $ssisDb.ToLower()) {
        $isConfigs = Get-Childitem $packageFolderRoot -Recurse -File -Filter *.json
        if ($isConfigs.Count -gt 0) {
            write-host "[Set-SSISPackageParamters] JSON files have been found..."
            foreach ($project in $folder.Projects) {
                foreach ($package in $project.Packages) {
                    foreach ($isConfig in $isConfigs) {
                        if ($isConfig.Name.ToLower() -match $package.Name.ToLower()) {
                            $settingText = $project.Name + "\" + $package.Name
                            write-host "[Set-SSISPackageParamters] Setting paramters for:" $settingText "using" $isConfig.FullName
                            $jsonConfig = Get-Content -Raw -Path $isConfig.FullName | ConvertFrom-Json
                            foreach ($jsonParameter in $jsonConfig.Parameters) {
                                $isSecure = $false
                                try {
                                    $value = (get-variable $jsonParameter.DeployProperty -ErrorAction SilentlyContinue -WarningAction SilentlyContinue).Value
                                    $url = $DORC_PropertiesUrl #+ $jsonParameter.DeployProperty
                                    $ProgressPreference = "SilentlyContinue"
                                    $propInfo = Invoke-WebRequest $url -Headers $DorcAPIHeaders -UseBasicParsing | ConvertFrom-Json
									$propInfo = $propInfo|  where {$_.Name -eq $jsonParameter.DeployProperty}
                                    $ProgressPreference = "Continue"
                                    $isSecure = $propInfo.Secure #IsSecured
                                } catch { $value = "<<< Not Defined in DOrc >>>" }
                                if ([string]::IsNullOrEmpty($value)) { $value = "<<< Not Defined in DOrc >>>" }
                                elseif ($isSecure) { $outputValue = $mask.Substring(0, $value.Length) } 
                                else { $outputValue = $value }
                                $output = "[Set-SSISPackageParamters] " + $jsonParameter.DeployProperty + " = " + $outputValue + " --> " + $jsonParameter.SSISParameter
                                write-host $output
                                foreach ($packageParameter in $package.Parameters){
                                    if ($packageParameter.Name -eq $jsonParameter.SSISParameter) {
                                        $output =  "[Set-SSISPackageParamters]   Updating: " + $packageParameter.Name + " = " + $outputValue
                                        write-host $output
                                        $packageParameter.Set([Microsoft.SqlServer.Management.IntegrationServices.ParameterInfo+ParameterValueType]::Literal, $value.ToString())
                                        $project.Alter()
                                    }
                                }
                            }
                        } elseif (($isConfig.Name.ToLower() -match "environmentvariables") -and !($envVarsSet)) {
                            $varEnv = $folder.Environments["Variables"]
                            if (!($varEnv)){
                                write-host "[Set-SSISPackageParamters] Creating Environment: Variables"
                                $env = New-Object $ISNamespace".EnvironmentInfo" ($folder, "Variables", "Variables")
                                $env.Create()
                            } else {
                                write-host "[Set-SSISPackageParamters] Removing Environment: Variables"
                                $folder.Environments.Remove($varEnv)
                                $folder.Alter()
                                write-host "[Set-SSISPackageParamters] Creating Environment: Variables"
                                $env = New-Object $ISNamespace".EnvironmentInfo" ($folder, "Variables", "Variables")
                                $env.Create()    
                            }
                            $varEnv = $folder.Environments["Variables"]
                            write-host "[Set-SSISPackageParamters] Setting Environment paramters for:" $project.Name "using" $isConfig.FullName
                            $jsonConfig = Get-Content -Raw -Path $isConfig.FullName | ConvertFrom-Json
                            foreach ($jsonParameter in $jsonConfig.Parameters) {
                                $isSecure = $false
                                try {
                                    $value = (get-variable $jsonParameter.DeployProperty -ErrorAction SilentlyContinue -WarningAction SilentlyContinue).Value
                                    $url = $DORC_PropertiesUrl #+ $jsonParameter.DeployProperty
                                    $ProgressPreference = "SilentlyContinue"
                                    $propInfo = Invoke-WebRequest $url -Headers $DorcAPIHeaders -UseBasicParsing | ConvertFrom-Json
									$propInfo = $propInfo|  where {$_.Name -eq $jsonParameter.DeployProperty}
                                    $ProgressPreference = "Continue"
                                    $isSecure = $propInfo.Secure #IsSecured
                                } catch { $value = "<<< Not Defined in DOrc >>>" }
                                if ([string]::IsNullOrEmpty($value)) { $value = "<<< Not Defined in DOrc >>>" }
                                elseif ($isSecure) { $outputValue = $mask.Substring(0, $value.Length) } 
                                else { $outputValue = $value }
                                $output = "[Set-SSISPackageParamters] Environment: " + $jsonParameter.DeployProperty + " = " + $outputValue + " --> " + $jsonParameter.SSISParameter
                                write-host $output
                                $description = "Set by DOrc:" + $jsonParameter.DeployProperty
                                $varEnv.Variables.Add($jsonParameter.SSISParameter, [System.TypeCode]::String, $value, $isSecure, $description)
                                $varEnv.Alter()
                            }
                            $envVarsSet = $true
                        }
                    }
                }
            }
            $result = $true
        } else { Write-Host "[Deploy-SSISPackages] No JSON files found..." ; $result = $true }
    } else { Write-Host "[Set-SSISPackageParamters] Failed to connect to SSIS server $ssisServer.$ssisDb" ; $result = $false }
    $packageParameters, $integrationServices, $catalog, $folder, $isConfigs = $null
    return $result
    }
	Catch {
        Write-Host "Error during deploy of ssis params:"
        Write-Host $_
        throw
	}
	Finally {
		
	}
}
function CheckBackup ([string] $SourceInstance, [string] $SourceDB, [string] $RestoreMode){ 
    if (($RestoreMode -eq "latest") -or ($RestoreMode -eq "now") -or ($RestoreMode -eq "pit")) {write-host "restore mode $RestoreMode"}
		else {throw "wrong RestoreMode, expected: latest/now/pit"}
    $inc = "msdb..backupset.type = 'D' OR backupset.type = 'I' OR backupset.type = 'L'"
    $full = "msdb..backupset.type = 'D'"
    $type = $full
    Write-Host ">>> SourceInstance: $SourceInstance"
    Write-Host ">>> SourceDB: $SourceDB"

    $realSQLNameQueryResult = Invoke-Sqlcmd -Query "SELECT @@SERVERNAME" -ServerInstance "$SourceInstance" -TrustServerCertificate 
    $realSQLName = $realSQLNameQueryResult.Column1

    $fullbackpath =  Invoke-Sqlcmd -Query "USE master SELECT top(1)
        msdb.dbo.backupmediafamily.physical_device_name as path
        FROM msdb.dbo.backupmediafamily
        INNER JOIN msdb.dbo.backupset ON msdb.dbo.backupmediafamily.media_set_id = msdb.dbo.backupset.media_set_id
        WHERE msdb.dbo.backupset.database_name = '$SourceDB'
        AND (CONVERT(datetime, msdb.dbo.backupset.backup_start_date, 102) >= GETDATE() - 60)
        AND ($type) AND msdb.dbo.backupset.server_name = '$realSQLName'
        ORDER BY
        msdb.dbo.backupset.backup_finish_date desc" -ServerInstance "$SourceInstance" -TrustServerCertificate
	$guidPattern = '^\{?[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}\}?$'
	Write-Host "CheckBackup full path:" $fullbackpath.path
	if (!([string]::IsNullOrEmpty($fullbackpath.path))) {
		$fullPathType = if ($fullbackpath.path -match $guidPattern) { 'CommvaultBackup' } else { 'filesharebackup' }
		Write-Host "CheckBackup full path type:" $fullPathType
		if ($RestoreMode -eq "latest"){
			return [PSCustomObject]@{ IsValid = $true; FullPath = $fullbackpath.path; FullPathType = $fullPathType; IncPath = $null; IncPathType = $null }
		}
	}
	else { return [PSCustomObject]@{ IsValid = $false; FullPath = $null; FullPathType = $null; IncPath = $null; IncPathType = $null } }
    if ($RestoreMode -eq "now" -or $RestoreMode -eq "pit"){
        $type = $inc
        $incbackpath =  Invoke-Sqlcmd -Query "USE master SELECT top(1)
			msdb.dbo.backupmediafamily.physical_device_name as path
			FROM msdb.dbo.backupmediafamily
			INNER JOIN msdb.dbo.backupset ON msdb.dbo.backupmediafamily.media_set_id = msdb.dbo.backupset.media_set_id
			WHERE msdb.dbo.backupset.database_name = '$SourceDB'
			AND (CONVERT(datetime, msdb.dbo.backupset.backup_start_date, 102) >= GETDATE() - 60)
			AND ($type) AND msdb.dbo.backupset.server_name = '$realSQLName'
			ORDER BY
			msdb.dbo.backupset.backup_finish_date desc" -ServerInstance "$SourceInstance" -TrustServerCertificate
		Write-Host "CheckBackup inc path:" $incbackpath.path
		if (!([string]::IsNullOrEmpty($incbackpath.path))) {
			$incPathType = if ($incbackpath.path -match $guidPattern) { 'CommvaultBackup' } else { 'filesharebackup' }
			Write-Host "CheckBackup inc path type:" $incPathType
			return [PSCustomObject]@{ IsValid = $true; FullPath = $fullbackpath.path; FullPathType = $fullPathType; IncPath = $incbackpath.path; IncPathType = $incPathType }
		}
		else { return [PSCustomObject]@{ IsValid = $false; FullPath = $fullbackpath.path; FullPathType = $fullPathType; IncPath = $null; IncPathType = $null } }
    }
}

Function Get-MSHotfix  {  
    <#
    .SYNOPSIS
    Get list of installed Hotfixes. This is essentially a wrapper for "wmic qfe list".
    
    .DESCRIPTION
    Get list of installed Hotfixes. Note, the term Hotfix is incorrectly used interchangeably with Windows Update or Patch.
    
    .PARAMETER ComputerName
    ComputerName
    
    .PARAMETER Credential
    Credential object
        
    .EXAMPLE
    $admcred = Get-Credential
    $Hotfixes = Get-MSHotfix -ComputerName SERVER1 -Credential $admcred 2>$null
    
    Stores list of installed hotfixes on SERVER1 in variable $Hotfixes. Error stream is ignored.

    .EXAMPLE
    $admcred = Get-Credential
    Get-MSHotfix -ComputerName SERVER1 -Credential $admcred | sort InstalledOn | ft HotFixID, InstalledOn, InstalledBy
    
    Produces table with list of installed hotfixes sorted by date. Oldest on the top.

    #>
    param (
        $ComputerName = $env:COMPUTERNAME,
        [pscredential]$Credential
    )
    
    $params = @{}

    if ($ComputerName) {
        $params."ComputerName" = $ComputerName;
    }
    if ($Credential) {
        $params."Credential" = $Credential;
    }

    $outputs = Invoke-Command -ScriptBlock {Invoke-Expression "wmic qfe list"} @params
    $outputs = $outputs[1..($outputs.length)]
      
      
    foreach ($output in $Outputs) {  
        if ($output) {  
            $output = $output -replace 'Security Update','Security-Update'
            $output = $output -replace 'Service Pack','Service-Pack'
            $output = $output -replace 'NT AUTHORITY','NT-AUTHORITY'  
            $output = $output -replace '\s+',' '  
            $parts = $output -split ' ' 
            $InstalledBy = $parts[4]
            if ($parts[5] -like "*/*/*") {  
                $Dateis = [datetime]::ParseExact($parts[5], '%M/%d/yyyy',[Globalization.cultureinfo]::GetCultureInfo("en-US").DateTimeFormat)
            }
            elseif (($parts[4] -like "*/*/*")) {
                $Dateis = [datetime]::ParseExact($parts[4], '%M/%d/yyyy',[Globalization.cultureinfo]::GetCultureInfo("en-US").DateTimeFormat)
                $InstalledBy = "n/a"
            }
            else {
                #catch parsing errors
                try {
                    $Dateis = get-date([DateTime][Convert]::ToInt64("$parts[5]", 16)) -Format '%M/%d/yyyy'
                }
                catch {
                    #unknown date format
                    $Dateis = Get-Date 1901
                }
            }
            New-Object -Type PSObject -Property @{  
                KBArticle = [string]$parts[0]  
                Computername = [string]$parts[1]  
                Description = [string]$parts[2]  
                FixComments = [string]$parts[6]  
                HotFixID = [string]$parts[3]  
                InstalledOn = [datetime]$Dateis.Date #to make is sortable!
                InstalledBy = $InstalledBy
                InstallDate = [string]$parts[7]  
                Name = [string]$parts[8]  
                ServicePackInEffect = [string]$parts[9]  
                Status = [string]$parts[10]  
            }
        }
    }
}

Function Get-ServerOSVersion {
    param (
        $ComputerName = $env:COMPUTERNAME,
        [pscredential]$Credential
    )

    $params = @{}
    if ($PSBoundParameters['ComputerName']) {
        $params."ComputerName" = $ComputerName
    }
    if ($PSBoundParameters['Credential']) {
        $params."Credential" = $Credential
    }
    
    $buildNumber = Invoke-Command {(Get-CimInstance Win32_OperatingSystem).BuildNumber} @params

    switch ($buildNumber) {
        6001 {$OS = "Windows Server 2008"}
        7600 {$OS = "Windows Server 2008 R2"}
        7601 {$OS = "Windows Server 2008 R2 SP1"}    
        9200 {$OS = "Windows Server 2012"}
        9600 {$OS = "Windows Server 2012 R2"}
        14393 {$OS = "Windows Server 2016 1607"}
        15063 {$OS = "Windows Server 2016 1703"}
        16229 {$OS = "Windows Server 2016 1709"}
        17134 {$OS = "Windows Server 2019 1803"}
        17763 {$OS = "Windows Server 2019 1809"}
        18363 {$OS = "Windows Server 2019 1909"}
        19041 {$OS = "Windows Server 2019 2004"}
        default { $OS = "n/a"}
    }
    return $OS
}

Function Get-DorcCredSSPStatus {
    <#
    .SYNOPSIS
    Evaluates whether CredSSP is supported for establishing Powershell session to a remote host from local machine.
     
    .DESCRIPTION
    This function will validate number of things.
    - Is credential delegation enabled in WSMAN settings on local machine (Client)
    - Is credential delegation enabled in WSMAN settings on remote machine (Server)
    - Are any CredSSP vulnerability hotfixes installed on either local or remote machine,
      see https://support.microsoft.com/en-gb/help/4295591/credssp-encryption-oracle-remediation-error-when-to-rdp-to-azure-vm
    - Are any registry changes in place to work around the above hotfixes
    - Attempts to establish CredSSP PS session to the remote computer
    
    .PARAMETER ComputerName
    Remote Computer Name
    
    .PARAMETER Credential
    Credential Object
    
    .PARAMETER Test
    Attempts to establish CredSSP PS session to the remote computer. 
    
    .EXAMPLE
    $admcred = Get-Credential
    Get-DorcCredSSPStatus -ComputerName SERVER1 -Credential $admcred -Test
    
    Validates whether local and remote machine can establish PS CredSSP session. The result is an output object looking like this:
    
    LocalComputerName             : CLIENT1
    RemoteComputerName            : SERVER1
    LocalOS                       : 10.0.17134
    RemoteOS                      : 10.0.14393
    LocalCredSSPEnabled           : True
    RemoteCredSSPEnabled          : True
    LocalPatchInstalled           : False
    RemotePatchInstalled          : False
    LocalHotFixWorkaroundInPlace  : False
    RemoteHotFixWorkaroundInPlace : False
    CredSSPWorks                  : True
    
    .LINK
    https://blogs.technet.microsoft.com/ashleymcglone/2016/08/30/powershell-remoting-kerberos-double-hop-solved-securely/
    https://support.microsoft.com/en-gb/help/4295591/credssp-encryption-oracle-remediation-error-when-to-rdp-to-azure-vm
    #>

    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [String]
        $ComputerName,

        [Parameter(Mandatory = $true)]
        [pscredential]
        $Credential,

        [Parameter(Mandatory = $false)]
        [switch]
        $Test
    )

    if (-not (Test-IsRunningAsAdministrator)) {
        throw "Get-DorcCredSSPStatus requires the session to be running as Administrator."
    }

    $params = @{}

    if ($PSBoundParameters['ComputerName']) {
        $params."ComputerName" = $ComputerName
    }
    if ($PSBoundParameters['Credential']) {
        $params."Credential" = $Credential
    }
    
    #Verify local computer has CredSSP enabled on Local machie (Client)
    try {
        $GetWSMAN = Get-WSManCredSSP -ErrorAction Stop
        #Expected output should look like this:
            # "The machine is configured to allow delegating fresh credentials to the following target(s): wsman/*.domain.name,
            # This computer is not configured to receive credentials from a remote client computer."
    }
    catch {
        Throw $_
    }
    if (($GetWSMAN -match "The machine is configured to allow delegating fresh credentials")`
        -and (($GetWSMAN -match "$ComputerName") -or ($GetWSMAN -match "\*")) ) {
        $LocalCredSSPEnabled = $true
    }
    else {
        $LocalCredSSPEnabled = $false
    }

    #Get operating system version
    try {
        $RemoteOS = Get-ServerOSVersion @params
    }
    catch {
        Write-Warning -message "Failed to get OS version of $ComputerName!"
    }

    try {
        $LocalOS = Get-ServerOSVersion
    }
    catch {
        Write-Warning -message "Failed to get OS version of $Env:COMPUTERNAME!"
    }
    

    #Check if CredSSP is enabled on the remote computer
    try {
        $GetWSMANRemote = Invoke-Command {Get-WSManCredSSP} @params -ErrorAction Stop
    }
    catch {
        Throw "Failed to connect to [$ComputerName] with Invoke-Command to obtain WSMAN config"
    }
    if ($GetWSMANRemote -match "This computer is configured to receive credentials from a remote client computer") {
        $RemoteCredSSPEnabled = $true
    }
    elseif ($GetWSMANRemote -match "This computer is not configured to receive credentials from a remote client computer") {
        $RemoteCredSSPEnabled = $false
    }
    
    #Check if CredSSP hotfixes are present
    $CredSSPHotfixes = @(
        [pscustomobject]@{os = "Windows Server 2008 R2"; hotfixes = @("KB4088875", "KB4088878")},
        [pscustomobject]@{os = "Windows Server 2012"; hotfixes = @("KB4103730", "KB4103726")},
        [pscustomobject]@{os = "Windows Server 2012 R2"; hotfixes = @("KB4103725", "KB4103715")},
        [pscustomobject]@{os = "Windows Server 2016 1607"; hotfixes = @("KB4103723")},
        [pscustomobject]@{os = "Windows Server 2016 1703"; hotfixes = @("KB4103731")},
        [pscustomobject]@{os = "Windows Server 2016 1709"; hotfixes = @("KB4103727")}  
    )
    
    $RemoteApplicableHotfixes = ($CredSSPHotfixes | Where-Object {Invoke-Command {$using:_.os -eq $using:RemoteOS} @params }).hotfixes
    $LocalApplicableHotfixes = ($CredSSPHotfixes | Where-Object { $_.os -eq $LocalOS}).hotfixes

    if ($RemoteApplicableHotfixes) {
        $RemoteHotfixes = Get-MSHotfix @params 2>$null | Where-Object {$RemoteApplicableHotfixes -contains $_.HotFixID}  #is expected to throw errors
    }
    
    if ($LocalApplicableHotfixes) {
        $LocalHotfixes = Get-MSHotfix -ComputerName $Env:COMPUTERNAME 2>$null | Where-Object {$LocalApplicableHotfixes -contains $_.HotFixID}
    }

    if (($RemoteHotfixes | Measure-Object).Count -ge 1) {
        $RemotePatchInstalled = $true
    }
    else {
        $RemotePatchInstalled = $false
    }

    if (($LocalHotfixes | Measure-Object).Count -ge 1) {
        $LocalPatchInstalled = $true
    }
    else {
        $LocalPatchInstalled = $false
    }

    #Check whether registry workaround is in place (https://support.microsoft.com/en-gb/help/4093492/credssp-updates-for-cve-2018-0886-march-13-2018)
    try {
        $LocalAllowEncryptionOracleValue = (Get-ItemProperty HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System\CredSSP\Parameters -Name AllowEncryptionOracle -ErrorAction Stop).AllowEncryptionOracle
    }
    catch {
        Write-Verbose -Message "[VERBOSE] Local AllowEncryptionOracleValue registry key either does not exist or is not accessible on [$Env:COMPUTERNAME]"
    }
    try {
        $RemoteAllowEncryptionOracleValue = Invoke-Command {(Get-ItemProperty HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System\CredSSP\Parameters -Name AllowEncryptionOracle).AllowEncryptionOracle} @params -ErrorAction Stop
    }
    catch {
        Write-Verbose -Message "[VERBOSE] Remote AllowEncryptionOracleValue registry key either does not exist or is not accessible on [$ComputerName]"
    }
    if ($RemoteAllowEncryptionOracleValue -eq 2) {
        $RemoteHotFixWorkaroundInPlace = $true
    }
    else {
        $RemoteHotFixWorkaroundInPlace = $false
    }

    if ($LocalAllowEncryptionOracleValue -eq 2) {
        $LocalHotFixWorkaroundInPlace = $true
    }
    else {
        $LocalHotFixWorkaroundInPlace = $false
    }
    
    #Test CredSSP
    if ($PSBoundParameters['Test']) {
        try {
            $Session = New-PSSession @params -Authentication Credssp -ErrorAction Stop
            $CredSSPWorks = $true
        }
        catch [System.Management.Automation.Remoting.PSRemotingTransportException] {
            if ($_ -match "server name cannot be resolved") {
                Throw "[ERROR] Server name [$ComputerName] cannot be resolved!"
            }
            else {
                $CredSSPWorks = $false
            }
        }
        catch {
            $CredSSPWorks = $false
            Throw $_
        }
    }
    else {
        $CredSSPWorks = "N/A"
    }
    
    #Build Custom Object for output
    $properties = @{
        "LocalComputerName"               = $Env:COMPUTERNAME
        "RemoteComputerName"              = $ComputerName
        "LocalOS"                         = $LocalOS
        "RemoteOS"                        = $RemoteOS
        "LocalCredSSPEnabled"             = $LocalCredSSPEnabled
        "RemoteCredSSPEnabled"            = $RemoteCredSSPEnabled
        "LocalPatchInstalled"             = $LocalPatchInstalled
        "RemotePatchInstalled"            = $RemotePatchInstalled
        "LocalHotFixWorkaroundInPlace"    = $LocalHotFixWorkaroundInPlace
        "RemoteHotFixWorkaroundInPlace"   = $RemoteHotFixWorkaroundInPlace
        "CredSSPWorks"                    = $CredSSPWorks
    }
    
    if ($session) {
        Remove-PSSession $session
    }
    
    $output = New-Object -TypeName psobject -Property $properties
    Return $output | Select-Object LocalComputerName, RemoteComputerName, LocalOS, RemoteOS, LocalCredSSPEnabled, RemoteCredSSPEnabled, LocalPatchInstalled, RemotePatchInstalled, LocalHotFixWorkaroundInPlace, RemoteHotFixWorkaroundInPlace, CredSSPWorks
}

Function Enable-DorcCredSSP {
    <#
    .SYNOPSIS
    Enables CredSSP for remote PS session on the local computer (where this is executed) and a remote machine
    
    .DESCRIPTION
    Enables CredSSP for remote PS session on the local computer (where this is executed) and a remote machine
    
    .PARAMETER ComputerName
    ComputerName
    
    .PARAMETER Credential
    Credential object
    
    .PARAMETER Force
    Forces creation of registry values for patched systems.
    
    .EXAMPLE
    Enable-DorcCredSSP -ComputerName SERVER1 -credential $admcred -Force -verbose
    
    Enables CredSSP and shows detailed verbose output.
    #>
    
    [CmdletBinding(SupportsShouldProcess = $true)]
    param (
        [Parameter(Mandatory = $true)]
        [String]        
        $ComputerName,
        
        [Parameter(Mandatory = $true)]
        [pscredential]
        $Credential,

        [Parameter(Mandatory = $false)]
        [switch]
        $Force
    )
    
    $params = @{}

    if ($PSBoundParameters['ComputerName']) {
        $params."ComputerName" = $ComputerName
    }
    if ($PSBoundParameters['Credential']) {
        $params."Credential" = $Credential
    }
    
    $CredSSPStatus = Get-DorcCredSSPStatus @params -Test
    Write-Verbose -Message "[VERBOSE] `n$($CredSSPStatus | out-string)"
    if ($CredSSPStatus.CredSSPWorks -eq $true) {
        Return "[INFO] CredSSP has already been enabled between [$Env:COMPUTERNAME] and [$ComputerName]"
    }
    
    if ($CredSSPStatus.LocalCredSSPEnabled -eq $false) {
        Write-Verbose -Message "Configuring Local WSMAN for CredSSP"
        try {
            Enable-WSManCredSSP -Role Client -DelegateComputer $ComputerName -Force -ErrorAction Stop
        }
        catch {
            Throw "[ERROR] Failed to enable CredSSP on local machine [$Env:COMPUTERNAME]: Full Exception: `n$_"
        }
    }

    if ($CredSSPStatus.RemoteCredSSPEnabled -eq $false) {
        Write-Verbose -Message "Configuring Remote WSMAN for CredSSP"
        try {
            Invoke-Command {Enable-WSManCredSSP -Role Server -Force -ErrorAction Stop} @params -ErrorAction Stop
        }
        catch {
            Throw "[ERROR] Failed to enable CredSSP on remote machine [$Env:COMPUTERNAME]: Full Exception: `n$_"
        }
    }
 
    if ($PSBoundParameters['Force']) {
        Write-Warning -Message "[WARN] Putting a registry override in. This will make system vulnerable."
        try  {
            New-Item HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System\CredSSP\Parameters -Force -ErrorAction Stop | Out-Null
            New-ItemProperty HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System\CredSSP\Parameters -Name AllowEncryptionOracle -Value 2 -Force -ErrorAction Stop | Out-Null
            Write-Warning -Message "[WARN] System [$Env:COMPUTERNAME] may need to be rebooted for the changes to kick in"
        }
        catch {
            Throw "[ERROR] Failed to put a registry override on [$Env:COMPUTERNAME]"
        }
        try { 
            Invoke-Command {
                New-Item HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System\CredSSP\Parameters -Force -ErrorAction Stop | Out-Null;
                New-ItemProperty HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System\CredSSP\Parameters -Name AllowEncryptionOracle -Value 2 -Force -ErrorAction Stop | Out-Null
            } @params -ErrorAction Stop
        }
        catch {
            Throw "[ERROR] Failed to put a registry override on [$ComputerName]"
        }
    }

    #Validate CredSSP works
    $CredSSPStatus = Get-DorcCredSSPStatus @params -Test
    Write-Verbose -Message "[VERBOSE] `n$($CredSSPStatus | out-string)"
    if ($CredSSPStatus.CredSSPWorks -eq $true) {
        Return "[INFO] CredSSP Successfully enabled between [$ENV:ComputerName] and [$ComputerName]"
    }
    else {
        Throw "[ERROR] Failed to enable CredSSP, please investigate. You may need to use the -Force parameter to add a registry workaround for patched systems."
    }
}

Function Check-IsCitrixServer {
    <#
    .SYNOPSIS
    Checks to see if the specified computer is a Citrix server
    
    .DESCRIPTION
    Checks to see if the specified computer is a Citrix server
    
    .PARAMETER ComputerName
    ComputerName
    
    .EXAMPLE
    Check-IsCitrixServer -ComputerName "SSDV-CTXAPP01"

    #>
    
    param (
        [Parameter(Mandatory = $true)]
        [String]        
        $compName
    )
    
    $result = $false

    Try {
        $compOS = "unknown"
        $os = Get-CimInstance -ComputerName $compName -ClassName Win32_OperatingSystem -Property *
        $compOS = $os.Caption
        $os = $null
    } catch { }
    if ($compOS -eq "unknown") {
        write-host "[Check-IsCitrixServer] Unable to identify O/S on: $compName"
    } elseif ($compOS.ToLower() -match "server"){
        write-host "[Check-IsCitrixServer] $compName is $compOS"
        $rkCitrixValueCount = icm -ComputerName $compName { $rkCitrix = get-item HKLM:\SOFTWARE\Citrix -ErrorAction SilentlyContinue ; return $rkCitrix.ValueCount }
        if ($rkCitrixValueCount -gt 0) {
            write-host "[Check-IsCitrixServer] $compName is a Citrix Server..."
            $result = $true
        }
    }
    return $result
}

Function Stop-CitrixApp {
    <#
    .SYNOPSIS
    Terminates an application on a Citrix server for all users
    
    .DESCRIPTION
    Terminates an application on a Citrix server for all users
    
    .EXAMPLE
     Stop-CitrixApp -compName $serverName -procName "client" -pathText $envForPath -warningMessage "Client will terminate in 30 seconds, please save any work and exit..."
    #>
    
    param (
        [Parameter(Mandatory = $true)]
        [String]        
        $compName,
        
        [Parameter(Mandatory = $true)]
        [string]
        $procName,

        [Parameter(Mandatory = $true)]
        [string]
        $pathText,

        [Parameter(Mandatory = $true)]
        [string]
        $warningMessage
    )
    
    if (Test-Connection -ComputerName $compName){
        $validProcesses = Invoke-Command -ComputerName $compName { Get-Process -IncludeUserName } | Where-Object {$_.ProcessName -match $procName -and $_.Path -match $pathText}
        foreach($validProcess in $validProcesses) {
            Write-Host "[Stop-CitrixApp] Messaging:" $validProcess.UserName
            Invoke-Command -ComputerName $compName {msg $($args[0]) /TIME:30 "$($args[1])"} -ArgumentList $validProcess.UserName.Split("\")[1], $warningMessage
        }
        start-sleep -Seconds 30
        $validProcesses = Invoke-Command -ComputerName $compName { Get-Process -IncludeUserName } | Where-Object {$_.ProcessName -match $procName -and $_.Path -match $pathText}
        foreach($validProcess in $validProcesses) {
            $info = $compName + "." + $validProcess.UserName
            Write-Host "[Stop-CitrixApp] Terminating: [$info]" $validProcess.Path
            Invoke-Command -ComputerName $compName {Get-Process -IncludeUserName | Where-Object UserName -eq $($args[0]) | Stop-Process -Force -ErrorAction SilentlyContinue} -ArgumentList $validProcess.UserName
        }
        $validProcesses, $info = $null
    } else { write-host "[Stop-CitrixApp] Cannot connect to:" $compName }
}

function Test-HaveAdminAccess {
    param (
        [Parameter(Position = 0, Mandatory = $true)]
        [string] $serverName
    )

    $result = $false
    $isAdmin = Invoke-Command $serverName { ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
    if ($isAdmin.GetType().fullname -eq "System.Boolean") { $result = $isAdmin }
    return $result
}


function Get-GACUtilPath {
    param (
        [Parameter(Position = 0, Mandatory = $true)]
        [string] $serverName
    )

    # Saves having to have DOrc properties for this exe
    $GACUtilPath = "C:\Windows\Microsoft.NET\Framework\v1.1.4322\gacutil.exe"
    if (Test-Path ("\\" + $serverName + "\C$" + "\Program Files (x86)\Microsoft SDKs\Windows\v10.0A\bin\NETFX 4.6 Tools\x64\gacutil.exe")) {
        $GACUtilPath = "C:\Program Files (x86)\Microsoft SDKs\Windows\v10.0A\bin\NETFX 4.6 Tools\x64\gacutil.exe"
    } elseif (Test-Path ("\\" + $serverName + "\C$" + "\Program Files (x86)\Microsoft SDKs\Windows\v8.1A\bin\NETFX 4.5.1 Tools\gacutil.exe")) {
        $GACUtilPath = "C:\Program Files (x86)\Microsoft SDKs\Windows\v8.1A\bin\NETFX 4.5.1 Tools\gacutil.exe"
    } elseif (Test-Path ("\\" + $serverName + "\C$" + "\Program Files (x86)\Microsoft SDKs\Windows\v7.0A\Bin\x64\gacutil.exe")) {
        $GACUtilPath = "C:\Program Files (x86)\Microsoft SDKs\Windows\v7.0A\Bin\x64\gacutil.exe"
    }
    return $GACUtilPath
}
function Get-LibsInGAC {
    param (
        [Parameter(Position = 0, Mandatory = $true)]
        [string] $serverName,

        [Parameter(Position = 1, Mandatory = $true)]
        [string] $GACUtilPath
    )
    return (Invoke-Command -ComputerName $serverName { & $($args[0]) /l } -ArgumentList $GACUtilPath)
}

function UnRegister-FromGAC {
    param (
        [Parameter(Position = 0, Mandatory = $true)]
        [string] $serverName,

        [Parameter(Position = 1, Mandatory = $true)]
        [string] $library,

        [Parameter(Position = 2, Mandatory = $true)]
        [string] $GACUtilPath
    )
    Invoke-RemoteProcess -serverName $serverName -strExecutable $GACUtilPath -strParams "/uf $library" 
}

function Register-ToGAC {
    param (
        [Parameter(Position = 0, Mandatory = $true)]
        [string] $serverName,

        [Parameter(Position = 1, Mandatory = $true)]
        [string] $library,

        [Parameter(Position = 2, Mandatory = $true)]
        [string] $GACUtilPath
    )

    $tempDest = "\\" + $serverName + "\c$\installs"
    if (Test-Path $tempDest) {
        Copy-Item $library -Destination $tempDest -Force
        $lib = "C:\Installs" + ($library.Substring($library.LastIndexOf("\") , ($library.Length - $library.LastIndexOf("\"))))
        Invoke-RemoteProcess -serverName $serverName -strExecutable $GACUtilPath -strParams "/i $lib"
        Invoke-Command -ComputerName $serverName { Remove-Item $($args[0]) -Force } -ArgumentList $lib
    } else { throw "[Register-FromNuGetToGAC] Expected C:\Installs not found" }
}

function Register-FromNuGetToGAC {
    param (
        [Parameter(Position = 0, Mandatory = $true)]
        [string] $packageLocation,
        
        [Parameter(Position = 1, Mandatory = $true)]
        [string] $packageName,

        [Parameter(Position = 2, Mandatory = $true)]
        [string] $packageVersion,

        [Parameter(Position = 3, Mandatory = $true)]
        [string] $serverType,
        
        [Parameter(Position = 4, Mandatory = $false)]
        [string] $packageSubfolder
    )

    $ProgressPreference = 'SilentlyContinue'
    $targetServerType = $serverType
    $ServerInfo = new-object "System.Data.DataTable"
    $ServerInfo = GetServersOfType $EnvironmentName $targetServerType
    
    if ($ServerInfo.Rows.Count -gt 0)
    {
        
        $tmpSource = [System.IO.Path]::GetRandomFileName().Replace(".", "")
        Register-PackageSource -Name $tmpSource -Location $packageLocation -ProviderName NuGet

        $tempFolder = ($env:temp + "\" + [System.IO.Path]::GetRandomFileName().Replace(".", ""))

        $nupkgName = $tempFolder + "\" + $packageName + "." + $packageVersion + ".nupkg"
        $extractFolder = Join-Path $tempFolder "Temp"
        New-Item -ItemType Directory -Path $extractFolder

        write-host "[Register-FromNuGetToGAC] Downloading NuPkg..."
        $ProgressPreference = "SilentlyContinue"
        Save-Package -Name $packageName -RequiredVersion $packageVersion -Path $tempFolder -Source $tmpSource
        Rename-Item -Path $nupkgName -NewName $nupkgName.Replace(".nupkg", ".zip")
        Expand-Archive -Path $nupkgName.Replace(".nupkg", ".zip") -DestinationPath $extractFolder
        $ProgressPreference = "Continue"

        if ($packageSubfolder) {
            $packageSubfolder= $packageSubfolder.TrimStart("\").Trim()
            $extractFolder = $extractFolder+"\"+$packageSubfolder
            if (!(Test-Path $extractFolder)) {throw "$packageSubfolder was not found in the package"}
        }

        $dlls = Get-Childitem $extractFolder -Recurse -File -Filter *.dll
        write-host "[Register-FromNuGetToGAC] Libraries found:" $dlls.Count "in $extractFolder"
        foreach ($Row in $ServerInfo)
        {
            $serverName = $Row.Server_Name.Trim()
            $serverType = $Row.Application_Server_Name.Trim()
            if (Test-Connection $serverName -Count 1 -quiet)
            {
                write-host "[Register-FromNuGetToGAC] $serverName is alive..."
                if ((Test-HaveAdminAccess -serverName $serverName)) {
                    write-host "[Register-FromNuGetToGAC] Admin access confirmed, attempting to register libraries in $nupkgName on $serverName..."
                    $GACUtilPath = Get-GACUtilPath -serverName $serverName
                    write-host "[Register-FromNuGetToGAC] Using: $GACUtilPath"
                    foreach ($dll in $dlls) { 
                        Write-Host "[Register-FromNuGetToGAC] $dll"
                        $libName = $dll.Name.Replace(".dll", "")
                        $remLibs = Get-LibsInGAC -serverName $serverName -GACUtilPath $GACUtilPath
                        $count = $remLibs.Count
                        write-host "[Register-FromNuGetToGAC] Found $count libraries registered in GAC on $serverName"
                        if ($remLibs -match $libName) {
                            Write-Host "[Register-FromNuGetToGAC] $libName will be unregistered..."
                            UnRegister-FromGAC -serverName $serverName -library $libName -GACUtilPath $GACUtilPath
                            $remLibs = Get-LibsInGAC -serverName $serverName -GACUtilPath $GACUtilPath
                            if ($remLibs -match $libName) { 
                                throw "[Register-FromNuGetToGAC] unregister failed..." 
                            } else { Write-Host "[Register-FromNuGetToGAC] Success, $libName has been unregistered..."}
                        }
                        Write-Host "[Register-FromNuGetToGAC] Registering $libName from " $dll.FullName
                        Register-ToGAC -serverName $serverName -library $dll.FullName -GACUtilPath $GACUtilPath
                        $remLibs = Get-LibsInGAC -serverName $serverName -GACUtilPath $GACUtilPath
                        if ($remLibs -match $libName) { Write-Host "[Register-FromNuGetToGAC] Success, $libName has been registered..." ; Write-Host "" }
                    }    
                } else { Throw "[Register-FromNuGetToGAC] Don't have admin access on $serverName" }
            }
        }
        Remove-Item $tempFolder -Recurse -Force
        UnRegister-PackageSource -Name $tmpSource -Force
    } else { Throw "[Register-FromNuGetToGAC] No servers of type $serverType" }   
}

function Grant-LogonAsAService {
    <#
    .Synopsis
      Grant logon as a service right to the defined user.
    .Parameter computerName
      Defines the name of the computer where the user right should be granted.
      Default is the local computer on which the script is run.
    .Parameter username
      Defines the username under which the service should run.
      Use the format domain\username or username.  
      Default is the user under which the script is run.
    .Example
      Usage:
      .\GrantSeServiceLogonRight.ps1 -computerName hostname.domain.com -username "domain\username"
    #>
    param(
      [string] $computerName = ("{0}.{1}" -f $env:COMPUTERNAME.ToLower(), $env:USERDNSDOMAIN.ToLower()),
      [string] $username = ("{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME)
    )
    Invoke-Command -ComputerName $computerName -Script {
      param([string] $username)
      $tempPath = [System.IO.Path]::GetTempPath()
      $import = Join-Path -Path $tempPath -ChildPath "import.inf"
      if(Test-Path $import) { Remove-Item -Path $import -Force }
      $export = Join-Path -Path $tempPath -ChildPath "export.inf"
      if(Test-Path $export) { Remove-Item -Path $export -Force }
      $secedt = Join-Path -Path $tempPath -ChildPath "secedt.sdb"
      if(Test-Path $secedt) { Remove-Item -Path $secedt -Force }
      try {
        Write-Host ("Granting SeServiceLogonRight to user account: {0} on host." -f $username)
        $sid = ((New-Object System.Security.Principal.NTAccount($username)).Translate([System.Security.Principal.SecurityIdentifier])).Value
        secedit /export /cfg $export
        $sids = (Select-String $export -Pattern "SeServiceLogonRight").Line
        foreach ($line in @("[Unicode]", "Unicode=yes", "[System Access]", "[Event Audit]", "[Registry Values]", "[Version]", "signature=`"`$CHICAGO$`"", "Revision=1", "[Profile Description]", "Description=GrantLogOnAsAService security template", "[Privilege Rights]", "$sids,*$sid")){
         Add-Content $import $line
        }
        secedit /import /db $secedt /cfg $import
        secedit /configure /db $secedt
        gpupdate /force
        Remove-Item -Path $import -Force
        Remove-Item -Path $export -Force
        Remove-Item -Path $secedt -Force
      } catch {
        Write-Host ("Failed to grant SeServiceLogonRight to user account: {0} on host: {1}." -f $username, $computerName)
        $error[0]
      }
    } -ArgumentList $username
}


function Get-AzAccessTokenToResource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ClientID,

        [Parameter(Mandatory = $true)]
        [string]$ClientSecret,

        [Parameter(Mandatory = $true)]
        [string]$TenantDomain,

        [Parameter(Mandatory = $true)]
        [string]$ResourceUrl
    )
    
    Import-Module -Name Az


    $SecureClientSecret = ConvertTo-SecureString $ClientSecret -AsPlainText -Force
    $Credential = New-Object System.Management.Automation.PSCredential($ClientID, $SecureClientSecret)

    Connect-AzAccount -TenantId $TenantDomain -Credential $Credential -ServicePrincipal

    $AccessTokenToResource = Get-AzAccessToken -ResourceUrl $ResourceUrl
    return $AccessTokenToResource
}

function DeployDACPACToAzureSQL {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$TargetServerName, 

        [Parameter(Mandatory = $true)]  
        [string]$TargetDatabaseName, 

        [Parameter(Mandatory = $true)]
        [string]$dacpacPath,         

        [Parameter(Mandatory = $true)]
        [string]$sqlPackagePath,     

        [Parameter(Mandatory = $true)]
        [string]$AccessToken,         

        [Parameter(Mandatory = $false)]
        [hashtable]$Variables
    )

    Write-Host "Deploying DACPAC to Azure SQL Server..."

    # Base args
    $args = @(
        "/Action:Publish",
        "/SourceFile:$dacpacPath",
        "/TargetServerName:$TargetServerName",
        "/TargetDatabaseName:$TargetDatabaseName",
        "/AccessToken:$AccessToken",
        "/Quiet"
    )

    # Add /Variables:... if provided
    if ($Variables) {
        $varString = ($Variables.GetEnumerator() | ForEach-Object {
                "$($_.Key)=$($_.Value)"
            }) -join ";"

        $args += "/v:$varString"
    }

    # Debug
    Write-Host "Running: $sqlPackagePath $($args -join ' ')"

    # Execute
    & "$sqlPackagePath" @args

    if ($LASTEXITCODE -eq 0) {
        Write-Host "DACPAC deployment to $TargetServerName database $TargetDatabaseName completed successfully."
    }
    else {
        Write-Host "DACPAC deployment failed with exit code $LASTEXITCODE"
        throw "Deployment failed"
    }
}

function Get-DorcToken {   
    $DorcIDSsecret =  $DorcCliSecret
	
    if ([string]::IsNullOrWhiteSpace($DorcIDSsecret)) {
        Write-Error "The DorcIDSsecret is empty or null. Please provide a valid value."
        return $null
    }	
    $IDSHeaders = @{
        "Content-Type" = "application/x-www-form-urlencoded"
    }

    try {
        $DorcApiUrl = if ($RefDataApiUrl) { $RefDataApiUrl } else { "https://deploymentportal:8443" }
        $DorcApiUrl = $DorcApiUrl.TrimEnd('/')
        $ApiConfig = Invoke-WebRequest -Uri "$DorcApiUrl/ApiConfig" -UseBasicParsing | ConvertFrom-Json
        $IDSBaseURL = $ApiConfig.OAuthAuthority + "/connect/token"
        $ApiScope = ($ApiConfig.OAuthUiRequestedScopes -split ' ' | Where-Object { $_ -like '*.manage' } | Select-Object -First 1)
        if (-not $ApiScope) { $ApiScope = "dorc-api.manage" }
        Write-Host "Token endpoint is: $IDSBaseURL"
        Write-Host "Using scope: $ApiScope"
        $IDSFormData = @{
            "grant_type"    = "client_credentials"
            "client_id"     = "dorc-cli"
            "client_secret" = "$DorcIDSsecret"
            "scope"         = "$ApiScope"
        }
        $IDSResponse = Invoke-WebRequest -Uri $IDSBaseURL -Method POST -Headers $IDSHeaders -Body $IDSFormData -UseBasicParsing
        $TokenResponse = $IDSResponse.Content | ConvertFrom-Json        
        return $TokenResponse.access_token
    } catch {
		  Write-Error "Failed to retrieve token. Please check DorcIDSsecret variable value! Error: $_"
		  Throw
		  return $null
    }
}
