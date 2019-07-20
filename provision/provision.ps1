. ./common.ps1

# install useful applications.
choco install -y visualstudiocode
choco install -y notepad2
choco install -y 7zip
choco install -y googlechrome

# set the default browser.
choco install -y SetDefaultBrowser
SetDefaultBrowser HKLM 'Google Chrome'

# dependencies.
choco install -y adoptopenjdk8jre

# update $env:PATH with the recently installed Chocolatey packages.
Import-Module "$env:ChocolateyInstall\helpers\chocolateyInstaller.psm1"
Update-SessionEnvironment

# add certificates to the default java trust store.
Get-ChildItem C:\vagrant\tmp\*.der -ErrorAction SilentlyContinue | ForEach-Object {
    $certificatePath = $_.FullName
    $alias = $_.BaseName.ToLower()
    @(
        'C:\Program Files\Java\jre*\lib\security\cacerts'
        'C:\Program Files\Java\jdk*\jre\lib\security\cacerts'
        'C:\Program Files\AdoptOpenJDK\*jre\lib\security\cacerts'
        'C:\Program Files\AdoptOpenJDK\*jdk\jre\lib\security\cacerts'
    ) | ForEach-Object {Get-ChildItem $_ -ErrorAction SilentlyContinue} | ForEach-Object {
        $keyStore = $_
        $keytool = Resolve-Path "$keyStore\..\..\..\bin\keytool.exe"
        # delete the existing alias if it exists.
        $keytoolOutput = &$keytool `
            -noprompt `
            -delete `
            -storepass changeit `
            -keystore $keyStore `
            -alias $alias
        if ($LASTEXITCODE -and ($keytoolOutput -notmatch 'keytool error: java.lang.Exception: Alias .+ does not exist')) {
            Write-Host $keytoolOutput
            throw "failed to delete $alias from keystore $keyStore"
        }
        # add the certificate.
        Write-Host "Adding $alias to the java $keyStore keystore..."
        # NB we use Start-Process because keytool writes to stderr... and that
        #    triggers PowerShell to fail, so we work around this by redirecting
        #    stdout and stderr to a temporary file.
        # NB keytool exit code is always 1, so we cannot rely on that.
        Start-Process `
            -FilePath $keytool `
            -ArgumentList `
                '-noprompt',
                '-import',
                '-trustcacerts',
                '-storepass changeit',
                "-keystore `"$keyStore`"",
                "-alias `"$alias`"",
                "-file `"$certificatePath`"" `
            -RedirectStandardOutput "$env:TEMP\keytool-stdout.txt" `
            -RedirectStandardError "$env:TEMP\keytool-stderr.txt" `
            -NoNewWindow `
            -Wait
        $keytoolOutput = Get-Content -Raw "$env:TEMP\keytool-stdout.txt","$env:TEMP\keytool-stderr.txt"
        if ($keytoolOutput -notmatch 'Certificate was added to keystore') {
            Write-Host $keytoolOutput
            throw "failed to import $alias to keystore $keyStore"
        }
    }
}

# add hosts entries.
Add-Content -Encoding Ascii "$env:WINDIR\System32\drivers\etc\hosts" "192.168.56.2 dc.example.com`n"

# set variables.
$sonarQubeUrl = 'http://localhost:9000'
$sonarQubeUsername = 'admin'
$sonarQubePassword = 'admin'
$sonarQubeVersion = '6.7.7'
$sonarQubeZipUrl = "https://binaries.sonarsource.com/Distribution/sonarqube/sonarqube-$sonarQubeVersion.zip"
$sonarQubeZipHash = 'c3b9cdb6188a8fbf12dfefff38779fe48beb440794c1c91e6122c36966afb185'
$sonarQubeHome = "C:\sonarqube-$sonarQubeVersion"

# download SonarQube.
Write-Host 'Downloading SonarQube...'
$path = "$($env:TEMP)\SonarQube"
$sonarQubeZip = "$path\sonarqube-$sonarQubeVersion.zip"
mkdir -Force $path | Out-Null
(New-Object Net.WebClient).DownloadFile($sonarQubeZipUrl, $sonarQubeZip)
$s = New-Object IO.FileStream $sonarQubeZip, 'Open'
$sonarQubeZipActualHash = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($s)).Replace('-', '')
$s.Close()
if ($sonarQubeZipActualHash -ne $sonarQubeZipHash) {
    throw "$sonarQubeZipUrl does not match the expected hash"
}
Write-Host 'Installing SonarQube...'
# extract it.
$shell = New-Object -COM Shell.Application
$shell.NameSpace($sonarQubeZip).items() | %{ $shell.NameSpace($path).CopyHere($_) }
Move-Item "$path\sonarqube-$sonarQubeVersion" C:\
# install the service.
&$sonarQubeHome\bin\windows-x86-64\InstallNTService.bat
if ($LASTEXITCODE) {
    throw "failed to install the SonarQube service with LASTEXITCODE=$LASTEXITCODE"
}
# TODO run the service in a non-system account.
# start the service.
&$sonarQubeHome\bin\windows-x86-64\StartNTService.bat
if ($LASTEXITCODE) {
    throw "failed to start the SonarQube service with LASTEXITCODE=$LASTEXITCODE"
}

Write-Host 'Waiting for SonarQube to start...'
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
) | ForEach-Object {
    Write-Host "installing the $_ plugin..."
    Invoke-RestMethod -Headers $headers -Method Post -Uri $sonarQubeUrl/api/plugins/install -Body @{key=$_}
}

# configure LDAP.
# see https://docs.sonarqube.org/display/SONARQUBE67/LDAP+Plugin
Add-Content -Encoding Ascii "$sonarQubeHome\conf\sonar.properties" @'

#--------------------------------------------------------------------------------------------------
# LDAP

# General Configuration.
sonar.security.realm=LDAP
ldap.url=ldaps://dc.example.com
ldap.bindDn=jane.doe@example.com
ldap.bindPassword=HeyH0Password

# User Configuration.
ldap.user.baseDn=CN=Users,DC=example,DC=com
ldap.user.request=(&(sAMAccountName={login})(objectClass=person)(!(userAccountControl:1.2.840.113556.1.4.803:=2)))
ldap.user.realNameAttribute=displayName
ldap.user.emailAttribute=mail

# Group Configuration.
ldap.group.baseDn=CN=Users,DC=example,DC=com
ldap.group.request=(&(objectClass=group)(member={dn}))
ldap.group.idAttribute=sAMAccountName
'@

# restart SonarQube.
Write-Host 'restarting SonarQube...'
Restart-Service SonarQube
Wait-ForReady

# add shortcut to the desktop.
Set-Content -Encoding Ascii "$env:USERPROFILE\Desktop\SonarQube.url" @"
[InternetShortcut]
URL=http://localhost:9000
"@


#
# build a C# project, analyse and send it to SonarQube.

choco install -y git --params '/GitOnlyOnPath /NoAutoCrlf'
choco install -y gitextensions
choco install -y xunit
# NB we need to install a recent (non-released) version due
#    to https://github.com/OpenCover/opencover/issues/736
Push-Location opencover-rgl.portable
choco pack
choco install -y opencover-rgl.portable -Source $PWD
Pop-Location
choco install -y reportgenerator.portable
choco install -y sonarscanner-msbuild-net46

# configure the SonarQube runner credentials.
$configPath = 'C:\ProgramData\chocolatey\lib\sonarscanner-msbuild-net46\tools\SonarQube.Analysis.xml'
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
Set-Location MailBounceDetector
# NB "/d:sonar.branch.name=$(git rev-parse --abbrev-ref HEAD)"
#     can only be used on the SonarQube non-Community edition.
SonarScanner.MSBuild begin `
    '/k:github.com_rgl_MailBounceDetector' `
    '/n:github.com/rgl/MailBounceDetector' `
    "/v:$(git rev-parse HEAD)" `
    "/d:sonar.links.scm=$(git remote get-url origin)" `
    '/d:sonar.cs.opencover.reportsPaths=**\opencover-report.xml' `
    '/d:sonar.cs.xunit.reportsPaths=**\xunit-report.xml'
# retry the restore because it sometimes fails... but eventually succeeds.
while ($true) {
    MSBuild -m -p:Configuration=Release -t:restore
    if ($LASTEXITCODE -eq 0) {
        break
    }
    Start-Sleep -Seconds 1
    Write-Host 'Retrying the package restore...'
}
MSBuild -m -p:Configuration=Release -t:build
Get-ChildItem -Recurse */bin/*.Tests.dll | ForEach-Object {
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
SonarScanner.MSBuild end
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
Write-Host "Check the logs at $sonarQubeHome\logs"
