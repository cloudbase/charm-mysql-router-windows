# Copyright 2020 Cloudbase Solutions Srl
#
#    Licensed under the Apache License, Version 2.0 (the "License"); you may
#    not use this file except in compliance with the License. You may obtain
#    a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
#    WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
#    License for the specific language governing permissions and limitations
#    under the License.

Import-Module JujuWindowsUtils
Import-Module JujuHooks
Import-Module JujuLogging
Import-Module JujuUtils
Import-Module JujuHelper


$DEFAULT_INSTALL_BASE = Join-Path $env:ProgramFiles 'Cloudbase Solutions'
$DEFAULT_DB_PREFIX = "mysqlrouter"
$DEFAULT_SHARED_DB_ADDRESS = "127.0.0.1"
$DEFAULT_BASE_PORT = 3306

function Get-Vcredist {
    Write-JujuWarning "Getting vcredist."
    $vcredistUrl = Get-JujuCharmConfig -Scope "vcredist-url"
    if (!$vcredistUrl) {
        Write-JujuWarning "Trying to get vcredist Juju resource"
        $vcredistPath = Get-JujuResource -Resource "vcredist-x64"
        return $vcredistPath
    } else {
        Write-JujuInfo ("'vcredist-url' config option is set to: '{0}'" -f $vcredistUrl)
        $url = $vcredistUrl
    }

    $file = ([System.Uri]$url).Segments[-1]
    $tempDownloadFile = Join-Path $env:TEMP $file
    Start-ExecuteWithRetry {
        Invoke-FastWebRequest -Uri $url -OutFile $tempDownloadFile
    } -RetryMessage "Downloading vcredist failed. Retrying..."

    return $tempDownloadFile
}

function Install-Vcredist {
    Write-JujuWarning "Installing vcredist"
    $installerPath = Get-Vcredist
    Write-JujuInfo ("Path: {0}" -f $installerPath)
    $ps = Start-Process -Wait -PassThru -FilePath $installerPath `
                        -ArgumentList "/install /passive"
    if ($ps.ExitCode -eq 0) {
        Write-JujuWarning "Finished installing vcredist"
    } else {
        Throw ("Failed to install vcredist. Exit code: {0}" -f $ps.ExitCode)
    }
}

function Get-MySQLRouterInstaller {
    Write-JujuWarning "Getting mysql router installer"
    $mysqlRouterURL = Get-JujuCharmConfig -Scope "mysql-router-url"
    if (!$mysqlRouterURL) {
        Write-JujuWarning "Trying to get vcredist Juju resource"
        $mySQLRouterPath = Get-JujuResource -Resource "mysql-router"
        return $mySQLRouterPath
    } else {
        Write-JujuInfo ("'mysql-router-url' config option is set to: '{0}'" -f $mysqlRouterURL)
        $url = $mysqlRouterURL
    }

    $file = ([System.Uri]$url).Segments[-1]
    $tempDownloadFile = Join-Path $env:TEMP $file
    Start-ExecuteWithRetry {
        Invoke-FastWebRequest -Uri $url -OutFile $tempDownloadFile
    } -RetryMessage "Downloading vcredist failed. Retrying..."

    return $tempDownloadFile
}

function Get-InstallLocation {
    $unitName = (Get-JujuLocalUnit).Replace('/', '-')
    $installLocation = Join-Path $DEFAULT_INSTALL_BASE ("mysql-router-{0}" -f $unitName)
    return $installLocation
}

function Get-MySQLConfigPath {
    $cfgDir = Get-MysqlRouterDataDir
    $mysqlRouterConf = Join-Path $cfgDir "mysqlrouter.conf"
    return $mysqlRouterConf
}

function Invoke-EnsureFolders {
    if (!(Test-Path $DEFAULT_INSTALL_BASE)) {
        mkdir $DEFAULT_INSTALL_BASE
    }
    $installLocation = Get-InstallLocation

    if (!(Test-Path $installLocation)) {
        mkdir $installLocation
    }

    $appDataDir = Get-MysqlRouterDataDir
    if(!(Test-Path $appDataDir)) {
        mkdir $appDataDir
    }
}

function Invoke-InstallMySQLRouter {
    $tempInstallerPath = Join-Path $env:TEMP "mysql-installer"
    if ((Test-Path $tempInstallerPath)) {
        rm -Recurse -Force $tempInstallerPath
    }
    Invoke-EnsureFolders
    $installLocation = Get-InstallLocation
    $mySQLRouterZip = Get-MySQLRouterInstaller

    Expand-Archive -Path $mySQLRouterZip -DestinationPath $tempInstallerPath
    mv $tempInstallerPath/mysql-router*/* $installLocation/
}

function Get-MySQLRouterBinPath {
    $installLocation = Get-InstallLocation
    $binDir = Join-Path $installLocation "bin"
    $mysqlRouterBin = Join-Path $binDir "mysqlrouter.exe"
    return $mysqlRouterBin
}

function Get-MySQLServiceName {
    $unitName = (Get-JujuLocalUnit).Replace('/', '-')
    return ("mysql-{0}" -f $unitName)
}

function Invoke-EnsureService {
    $serviceName = Get-MySQLServiceName
    $hasService = Get-Service $serviceName -ErrorAction SilentlyContinue
    if($hasService) {
        return
    }

    $binPath = Get-MySQLRouterBinPath
    $mySQLRouterConfig = Get-MySQLConfigPath
    $binaryPathName = "`"$binPath`" -c `"$mySQLRouterConfig`" --service"
    $unitName = Get-JujuLocalUnit
    $description = "MySQL router for {0}" -f $unitName

    New-Service -Name $serviceName `
                -BinaryPathName $binaryPathName `
                -DisplayName $description -Confirm:$false
    Start-ExternalCommand { sc.exe failure $serviceName reset=5 actions=restart/1000 }
    Start-ExternalCommand { sc.exe failureflag $serviceName 1 }
    Stop-Service $serviceName
}

function Invoke-RemoveService {
    $serviceName = Get-MySQLServiceName
    $hasService = Get-Service $serviceName -ErrorAction SilentlyContinue
    if(!$hasService) {
        return
    }

    $svcObj = gcim Win32_Service -Filter ('Name = "{0}"' -f $serviceName)
    if($svcObj) {
        Stop-Service $serviceName
        $result = Invoke-CimMethod -InputObject $svcObj -MethodName Delete
        if ($result.ReturnValue -ne 0) {
            Throw ("Failed to uninstall service $serviceName. Error code: {0}" -f $result.ReturnValue)
        }
    }
}

function Get-RouterDBPrefix {
    $cfg = Get-JujuCharmConfig
    if ($cfg["db-prefix"]) {
        return $cfg["db-prefix"]
    }
    return $DEFAULT_DB_PREFIX
}

function Get-MySQLRouterUsername {
    $cfg = Get-JujuCharmConfig
    $routerUsername = $cfg["db-username"]
    if(!$routerUsername) {
        $routerUsername = $DEFAULT_MYSQL_ROUTER_USERNAME
    }
    return $routerUsername
}

function Get-MySQLRouterContext {
    $prefix = Get-RouterDBPrefix
    $passwdKey = "{0}_password" -f $prefix
    $required = @{
        $passwdKey = $null
        "db_host" = $null
    }

    $ctx = Get-JujuRelationContext -Relation "db-router" -RequiredContext $required
    if (!$ctx.Count) {
        return $null
    }

    $ret = @{
        "username" = Get-MySQLRouterUsername
        "password" = ConvertFrom-Yaml $ctx[$passwdKey]
        "hostname" = ConvertFrom-Yaml $ctx["db_host"]
    }
    return $ret
}

function Get-MysqlRouterDataDir {
    $unitName = (Get-JujuLocalUnit).Replace("/", "-")
    $appDataDir = Join-Path $env:ProgramData $unitName
    return $appDataDir
}

function Get-SharedDBAddress {
    return $DEFAULT_SHARED_DB_ADDRESS
}

function Get-MysqlRouterBasePort {
    $cfg = Get-JujuCharmConfig
    if (!$cfg["base-port"]) {
        return $DEFAULT_BASE_PORT
    }
    return $cfg["base-port"]
}

function Invoke-BootstrapMySQLRouter{
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        [string]$Username,
        [Parameter(Mandatory=$true)]
        [string]$Password,
        [Parameter(Mandatory=$true)]
        [string]$DBHost
    )

    PROCESS{
        $mysqlRouterBin = Get-MySQLRouterBinPath
        $mysqlRouterDataDir = Get-MysqlRouterDataDir
        $sharedDBAddress = Get-SharedDBAddress
        $basePort = Get-MysqlRouterBasePort
        $cmd = @(
            $mysqlRouterBin,
            "--user", $Username,
            "--bootstrap",
            "{0}:{1}@{2}" -f @($Username, $Password, $DBHost),
            "--directory", $mysqlRouterDataDir,
            "--conf-use-sockets",
            "--conf-bind-address", $sharedDBAddress,
            "--conf-base-port", $basePort)
        $ret = Invoke-JujuCommand $cmd
        Write-JujuInfo $ret
    }
}

function Invoke-EnsureRouterIsBootstrapped {
    $serviceName = Get-MySQLServiceName
    $mysqlRouterDataDir = Get-MysqlRouterDataDir
    $bootstrapped = Get-CharmState -Key "bootstrap-complete"
    if (!$bootstrapped) {
        Stop-Service $serviceName -ErrorAction SilentlyContinue
        if((Test-Path $mysqlRouterDataDir)) {
            rm -Recurse -Force $mysqlRouterDataDir
        } 
        Invoke-EnsureFolders

        $mysqlRouterCtx = Get-MySQLRouterContext
        if(!$mysqlRouterCtx) {
            Write-JujuWarning "MySQL router context not yet complete"
            return $false
        }
        Invoke-BootstrapMySQLRouter -Username $mysqlRouterCtx["username"] `
                                    -Password $mysqlRouterCtx["password"] `
                                    -DBHost $mysqlRouterCtx["hostname"]
        Restart-Service $serviceName
        Set-CharmState -Key "bootstrap-complete" -Value $true
    }
    return $true
}

#
# Charm Hooks
#

function Invoke-InstallHook {
    Install-Vcredist
    Invoke-InstallMySQLRouter
    Invoke-EnsureService
}

function Invoke-StopHook {
    Invoke-RemoveService
    Remove-CharmState -Key "bootstrap-complete"
    $installLocation = Get-InstallLocation
    rm -Recurse -Force $installLocation
}

function Invoke-ConfigChangedHook {
}

function Invoke-DBRouterRelationChanged {
    if (!(Invoke-EnsureRouterIsBootstrapped)) {
        return
    }
}

function Invoke-DBRouterRelationJoined {
    $prefix = Get-RouterDBPrefix
    $routerUsername = Get-MySQLRouterUsername
    $bindingAddress = Get-NetworkPrimaryAddress -Binding "db-router"
    $hostname_key = "{0}_hostname" -f $prefix
    $username_key = "{0}_username" -f $prefix
    $relationData = @{
        $hostname_key = $bindingAddress
        $username_key = $routerUsername
    }

    Set-JujuRelation -Settings $relationData
}