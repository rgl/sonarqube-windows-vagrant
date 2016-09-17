Vagrant.configure("2") do |config|
    config.vm.box = "windows_2012_r2"

    config.vm.provider :virtualbox do |v, override|
        v.linked_clone = true
        v.cpus = 2
        v.memory = 4096
        v.customize ["modifyvm", :id, "--vram", 64]
        v.customize ["modifyvm", :id, "--clipboard", "bidirectional"]
    end

    config.vm.provision "shell", path: "provision/locale.ps1"
    config.vm.provision "shell", inline: "$env:chocolateyVersion='0.10.0'; iex ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))"
    config.vm.provision "shell", inline: "cd c:/vagrant/provision; . ./provision-vs.ps1", name: "Provision Visual Studio"
    config.vm.provision :reload
    config.vm.provision "shell", inline: "cd c:/vagrant/provision; . ./provision.ps1", name: "Provision"
end
