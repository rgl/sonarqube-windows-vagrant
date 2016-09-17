. ./common.ps1

# NB this takes about 40m to install on my machine.
# NB VS requires a reboot after install.
Start-Choco `
    -Arguments `
        'install',
        '-y',
        '--allow-empty-checksums',
        'visualstudio2015community' `
    -SuccessExitCodes 0,3010
