. ./common.ps1

# install useful applications.
choco install -y visualstudiocode
choco install -y notepad2
choco install -y 7zip
choco install -y googlechrome

# dependencies.
choco install -y adoptopenjdk8jre

# update $env:PATH with the recently installed Chocolatey packages.
Import-Module "$env:ChocolateyInstall\helpers\chocolateyInstaller.psm1"
Update-SessionEnvironment

$sonarQubeUrl = 'http://localhost:9000'
$sonarQubeUsername = 'admin'
$sonarQubePassword = 'admin'

# download SonarQube.
$path = "$($env:TEMP)\SonarQube"
$sonarQubeVersion = '6.7.7'
$sonarQubeZipUrl = "https://binaries.sonarsource.com/Distribution/sonarqube/sonarqube-$sonarQubeVersion.zip"
$sonarQubeZipHash = 'c3b9cdb6188a8fbf12dfefff38779fe48beb440794c1c91e6122c36966afb185'
$sonarQubeZip = "$path\sonarqube-$sonarQubeVersion.zip"
mkdir -Force $path | Out-Null
(New-Object Net.WebClient).DownloadFile($sonarQubeZipUrl, $sonarQubeZip)
$s = New-Object IO.FileStream $sonarQubeZip, 'Open'
$sonarQubeZipActualHash = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($s)).Replace('-', '')
$s.Close()
if ($sonarQubeZipActualHash -ne $sonarQubeZipHash) {
    throw "$sonarQubeZipUrl does not match the expected hash"
}
# extract it.
$shell = New-Object -COM Shell.Application
$shell.NameSpace($sonarQubeZip).items() | %{ $shell.NameSpace($path).CopyHere($_) }
Move-Item "$path\sonarqube-$sonarQubeVersion" C:\
# install the service.
&C:\sonarqube-$sonarQubeVersion\bin\windows-x86-64\InstallNTService.bat
if ($LASTEXITCODE) {
    throw "failed to install the SonarQube service with LASTEXITCODE=$LASTEXITCODE"
}
# TODO run the service in a non-system account.
# start the service.
&C:\sonarqube-$sonarQubeVersion\bin\windows-x86-64\StartNTService.bat
if ($LASTEXITCODE) {
    throw "failed to start the SonarQube service with LASTEXITCODE=$LASTEXITCODE"
}

# wait for it be available.
$headers = @{
    Authorization = ("Basic {0}" -f [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(("{0}:{1}" -f $sonarQubeUsername,$sonarQubePassword))))
}
function Wait-ForReady {
    Wait-Condition {(Invoke-RestMethod -Headers $headers -Method Get -Uri $sonarQubeUrl/api/system/status).status -eq 'UP'}
}
Wait-ForReady

# list out-of-box installed plugins. at the time of writing they were:
#   csharp
#   flex
#   java
#   javascript
#   php
#   python
#   scmgit
#   scmsvn
#   typescript
#   xml
(Invoke-RestMethod -Headers $headers -Method Get -Uri $sonarQubeUrl/api/plugins/installed).plugins `
    | Sort-Object -Property key `
    | ForEach-Object {"Out-of-box installed plugin: $($_.key)"}

# install plugins.
@(
    'ldap'            # http://docs.sonarqube.org/display/PLUG/LDAP+Plugin
    'checkstyle'      # https://github.com/checkstyle/sonar-checkstyle
) | %{
    Write-Host "installing the $_ plugin..."
    Invoke-RestMethod -Headers $headers -Method Post -Uri $sonarQubeUrl/api/plugins/install -Body @{key=$_}
}
echo 'restarting SonarQube...'
Invoke-RestMethod -Headers $headers -Method Post -Uri $sonarQubeUrl/api/system/restart
Wait-ForReady


#
# build a C# project, analyse and send it to SonarQube.

choco install -y git --params '/GitOnlyOnPath /NoAutoCrlf'
choco install -y gitextensions
choco install -y nuget.commandline
choco install -y xunit
# NB we need to install a recent (non-released) version due
#    to https://github.com/OpenCover/opencover/issues/736
Push-Location opencover-rgl.portable
choco pack
choco install -y opencover-rgl.portable -Source $PWD
Pop-Location
choco install -y reportgenerator.portable
choco install -y msbuild-sonarqube-runner

# configure the SonarQube runner credentials.
$configPath = 'C:\ProgramData\chocolatey\lib\msbuild-sonarqube-runner\tools\SonarQube.Analysis.xml'
$configXml = [xml](Get-Content $configPath)
$configNs = 'http://www.sonarsource.com/msbuild/integration/2015/1'
$ns = New-Object Xml.XmlNamespaceManager($configXml.NameTable); $ns.AddNamespace('c', $configNs)
$n = $configXml.CreateElement($null, 'Property', $configNs)
$n.SetAttribute('Name', 'sonar.host.url')
$n.InnerText = $sonarQubeUrl
$configXml.SonarQubeAnalysisProperties.AppendChild($n) | Out-Null
$n = $configXml.CreateElement($null, 'Property', $configNs)
$n.SetAttribute('Name', 'sonar.login')
$n.InnerText = $sonarQubeUsername
$configXml.SonarQubeAnalysisProperties.AppendChild($n) | Out-Null
$n = $configXml.CreateElement($null, 'Property', $configNs)
$n.SetAttribute('Name', 'sonar.password')
$n.InnerText = $sonarQubePassword
$configXml.SonarQubeAnalysisProperties.AppendChild($n) | Out-Null
$configXml.Save($configPath)

# update $env:PATH with the recently installed Chocolatey packages.
Import-Module C:\ProgramData\chocolatey\helpers\chocolateyInstaller.psm1
Update-SessionEnvironment

# configure the git client.
git config --global user.name 'Vagrant'
git config --global user.email vagrant@example.com
git config --global push.default simple

# build a project and send it to SonarQube.
Push-Location $env:USERPROFILE
git clone --quiet https://github.com/rgl/MailBounceDetector.git
cd MailBounceDetector
MSBuild.SonarQube.Runner begin `
    '/k:github.com_rgl_MailBounceDetector' `
    '/n:github.com/rgl/MailBounceDetector' `
    '/v:master' `
    '/d:sonar.cs.opencover.reportsPaths=**\opencover-report.xml' `
    '/d:sonar.cs.xunit.reportsPaths=**\xunit-report.xml'
MSBuild -m -p:Configuration=Release -t:restore -t:build
dir -Recurse */bin/*.Tests.dll | ForEach-Object {
    Push-Location $_.Directory
    Write-Host "Running the unit tests in $($_.Name)..."
    OpenCover.Console `
        -output:opencover-report.xml `
        -register:path64 `
        '-filter:+[*]* -[*.Tests*]* -[*]*.*Config -[xunit.*]*' `
        '-target:xunit.console.exe' `
        "-targetargs:$($_.Name) -nologo -noshadow -xml xunit-report.xml"
    ReportGenerator.exe `
        -reports:opencover-report.xml `
        -targetdir:coverage-report
    Compress-Archive `
        -CompressionLevel Optimal `
        -Path coverage-report/* `
        -DestinationPath coverage-report.zip
    Pop-Location
}
MSBuild.SonarQube.Runner end
Pop-Location


#
# show summary.

# list installed plugins.
# see $sonarQubeUrl/web_api/api/plugins
Write-Host 'Installed Plugins:'
(Invoke-RestMethod -Headers $headers -Method Get -Uri $sonarQubeUrl/api/plugins/installed).plugins `
    | Select-Object -Property key,name,description `
    | Sort-Object -Property key `
    | Format-Table -AutoSize

Write-Host "You can now access the SonarQube Web UI at $sonarQubeUrl"
Write-Host "The default user and password are admin"
Write-Host "Check for updates at $sonarQubeUrl/updatecenter/installed"
Write-Host "Check the logs at C:\sonarqube-$sonarQubeVersion\logs"
