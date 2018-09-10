Vagrant.configure("2") do |config|
  config.vm.box = "regiohelden/ubuntu-16.04"
  config.vm.provider "libvirt" do |l|
  	l.memory = "4096"
  	l.cpus = 3
  end

  config.vm.define :server do |srv|
    srv.vm.hostname = "graphite"
    srv.vm.network "private_network", ip: "192.168.33.10"
    srv.vm.network "forwarded_port", guest: 80, host: 8019
    srv.vm.provision "shell", path: "provision.sh"
  end
end
