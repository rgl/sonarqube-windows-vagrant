. ./common.ps1

# install useful applications.
choco install -y visualstudiocode
choco install -y notepad2
choco install -y 7zip
choco install -y googlechrome
choco install -y baretail
choco install -y procmon
choco install -y procexp

# dependencies.
choco install -y --allow-empty-checksums jre8

$sonarQubeUrl = 'http://localhost:9000'
$sonarQubeUsername = 'admin'
$sonarQubePassword = 'admin'

# download SonarQube.
$path = "$($env:TEMP)\SonarQube"
$sonarQubeZipUrl = "https://sonarsource.bintray.com/Distribution/sonarqube/sonarqube-6.0.zip"
$sonarQubeZipHash = 'cecf45f35591a1419ef489d1bf13dfb0'
$sonarQubeZip = "$path\sonarqube-6.0.zip"
mkdir -Force $path | Out-Null
(New-Object Net.WebClient).DownloadFile($sonarQubeZipUrl, $sonarQubeZip)
$s = New-Object IO.FileStream $sonarQubeZip, 'Open'
$sonarQubeZipActualHash = [BitConverter]::ToString([Security.Cryptography.MD5]::Create().ComputeHash($s)).Replace('-', '')
$s.Close()
if ($sonarQubeZipActualHash -ne $sonarQubeZipHash) {
    throw "$sonarQubeZipUrl does not match the expected hash"
}
# extract it.
$shell = New-Object -COM Shell.Application
$shell.NameSpace($sonarQubeZip).items() | %{ $shell.NameSpace($path).CopyHere($_) }
Move-Item "$path\sonarqube-6.0" C:\
# install the service.
&C:\sonarqube-6.0\bin\windows-x86-64\InstallNTService.bat
if ($LASTEXITCODE) {
    throw "failed to install the SonarQube service with LASTEXITCODE=$LASTEXITCODE"
}
# TODO run the service in a non-system account.
# start the service.
&C:\sonarqube-6.0\bin\windows-x86-64\StartNTService.bat
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

# install plugins.
@(
    'ldap'            # http://docs.sonarqube.org/display/PLUG/LDAP+Plugin
    'JSON'            # https://github.com/racodond/sonar-json-plugin
    'checkstyle'      # https://github.com/checkstyle/sonar-checkstyle
    'javaProperties'  # https://github.com/racodond/sonar-jproperties-plugin
    'xml'             # http://docs.sonarqube.org/display/PLUG/XML+Plugin
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
choco install -y opencover.portable
choco install -y msbuild-sonarqube-runner

# configure the SonarQube runner credentials.
$configPath = 'C:\ProgramData\chocolatey\lib\msbuild-sonarqube-runner\tools\SonarQube.Analysis.xml'
$configXml = [xml](Get-Content $configPath)
$configNs = 'http://www.sonarsource.com/msbuild/integration/2015/1'
$ns = New-Object Xml.XmlNamespaceManager($configXml.NameTable); $ns.AddNamespace('c', $configNs)
$configXml.SelectSingleNode('/c:SonarQubeAnalysisProperties/c:Property[@Name="sonar.host.url"]', $ns).InnerText = $sonarQubeUrl
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
$env:PATH = "$env:PATH;C:\Program Files (x86)\MSBuild\14.0\bin"

# configure the git client.
git config --global user.name 'Vagrant'
git config --global user.email vagrant@example.com
git config --global push.default simple

# build a project and send it to SonarQube.
Push-Location $env:USERPROFILE
git clone --quiet https://github.com/rgl/MailBounceDetector.git
cd MailBounceDetector
nuget restore
MSBuild.SonarQube.Runner begin `
    '/k:github.com_rgl_MailBounceDetector' `
    '/n:github.com/rgl/MailBounceDetector' `
    '/v:master' `
    '/d:sonar.cs.opencover.reportsPaths=**\opencover-report.xml' `
    '/d:sonar.cs.xunit.reportsPaths=**\xunit-report.xml'
MSBuild /p:Configuration=Release
Push-Location MailBounceDetector.Tests\bin\Release
OpenCover.Console `
    -output:opencover-report.xml `
    -register:user `
    -target:C:\ProgramData\chocolatey\lib\XUnit\tools\xunit\xunit.console.exe `
    '-targetargs:MailBounceDetector.Tests.dll -xml xunit-report.xml'
Pop-Location
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
Write-Host "Check the logs at C:\sonarqube-6.0\logs"
