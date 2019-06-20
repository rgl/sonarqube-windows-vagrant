Vagrant.configure("2") do |config|
    config.vm.box = "windows-2019-amd64"

    config.vm.provider :libvirt do |lv, config|
        lv.cpu_mode = 'host-passthrough'
        lv.cpus = 2
        lv.memory = 4096
        lv.keymap = 'pt'
        config.vm.synced_folder '.', '/vagrant', type: 'smb', smb_username: ENV['USER'], smb_password: ENV['VAGRANT_SMB_PASSWORD']
    end

    config.vm.provider :virtualbox do |v, override|
        v.linked_clone = true
        v.cpus = 2
        v.memory = 4096
        v.customize ["modifyvm", :id, "--vram", 64]
        v.customize ["modifyvm", :id, "--clipboard", "bidirectional"]
    end

    config.vm.provision "shell", path: "provision/locale.ps1"
    config.vm.provision "shell", inline: "$env:chocolateyVersion='0.10.15'; iex ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))"
    config.vm.provision "shell", inline: "cd c:/vagrant/provision; . ./provision-vs-build-tools.ps1", name: "Provision Visual Studio Build Tools"
    config.vm.provision :reload
    config.vm.provision "shell", inline: "cd c:/vagrant/provision; . ./provision.ps1", name: "Provision"
end
