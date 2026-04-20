# -*- mode: ruby -*-
# vi: set ft=ruby :

# IP Plan
# VM-WAZUH-01 : 192.168.56.10
# VM-ELK-01   : 192.168.56.20
# VM-SURI-01  : 192.168.56.30
# VM-AI-01    : 192.168.56.40
# VM-ENDP-01  : 192.168.56.51
# VM-ENDP-02  : 192.168.56.52

Vagrant.configure("2") do |config|

  config.vm.box = "ubuntu/jammy64"
  config.vm.box_check_update = false

  # ─── VM-WAZUH-01 ───────────────────────────────────────────
  config.vm.define "wazuh" do |wazuh|
    wazuh.vm.hostname = "vm-wazuh-01"
    wazuh.vm.network "private_network", ip: "192.168.56.10"

    wazuh.vm.provider "virtualbox" do |vb|
      vb.name   = "VM-WAZUH-01"
      vb.memory = 4096
      vb.cpus   = 2
    end

    wazuh.vm.provision "shell", path: "scripts/wazuh/install_wazuh.sh"

    # Filebeat-Wazuh : attend que le CA soit généré par ELK
    wazuh.vm.provision "shell", inline: <<-SHELL
      echo "Attente CA depuis VM-ELK-01..."
      until [ -f /vagrant/certs/ca.crt ]; do
        echo "CA introuvable, retry dans 10s..."
        sleep 10
      done
      echo "CA disponible."
    SHELL
    wazuh.vm.provision "shell", path: "scripts/filebeat/install_filebeat_wazuh.sh"
  end

  # ─── VM-ELK-01 ─────────────────────────────────────────────
  config.vm.define "elk" do |elk|
    elk.vm.hostname = "vm-elk-01"
    elk.vm.network "private_network", ip: "192.168.56.20"

    elk.vm.provider "virtualbox" do |vb|
      vb.name   = "VM-ELK-01"
      vb.memory = 6144
      vb.cpus   = 2
    end

    elk.vm.provision "shell", path: "scripts/elk/install_elk.sh"
  end

  # ─── VM-SURI-01 ────────────────────────────────────────────
  config.vm.define "suricata" do |suri|
    suri.vm.hostname = "vm-suri-01"
    suri.vm.network "private_network", ip: "192.168.56.30"

    suri.vm.provider "virtualbox" do |vb|
      vb.name   = "VM-SURI-01"
      vb.memory = 3072
      vb.cpus   = 2
      vb.customize ["modifyvm", :id, "--nicpromisc2", "allow-all"]
    end

    suri.vm.provision "shell",
      path: "scripts/suricata/install_suricata.sh",
      args: ["enp0s8", "192.168.56.0/24"]

    suri.vm.provision "shell", inline: <<-SHELL
      echo "Attente CA depuis VM-ELK-01..."
      until [ -f /vagrant/certs/ca.crt ]; do
        echo "CA introuvable, retry dans 10s..."
        sleep 10
      done
      echo "CA disponible."
    SHELL
    suri.vm.provision "shell", path: "scripts/filebeat/install_filebeat_suricata.sh"
  end

  # ─── VM-AI-01 ──────────────────────────────────────────────
  config.vm.define "ai" do |ai|
    ai.vm.hostname = "vm-ai-01"
    ai.vm.network "private_network", ip: "192.168.56.40"

    ai.vm.provider "virtualbox" do |vb|
      vb.name   = "VM-AI-01"
      vb.memory = 6144
      vb.cpus   = 4
    end

    # Provision AI vient plus tard - placeholder
  end

  # ─── VM-ENDP-01 ────────────────────────────────────────────
  config.vm.define "endp01" do |endp|
    endp.vm.hostname = "vm-endp-01"
    endp.vm.network "private_network", ip: "192.168.56.51"

    endp.vm.provider "virtualbox" do |vb|
      vb.name   = "VM-ENDP-01"
      vb.memory = 1024
      vb.cpus   = 1
    end

    endp.vm.provision "shell", inline: <<-SHELL
      until nc -z 192.168.56.10 1515; do sleep 5; done
    SHELL
    endp.vm.provision "shell", path: "scripts/wazuh/install_agent.sh"
  end

  # ─── VM-ENDP-02 ────────────────────────────────────────────
  config.vm.define "endp02" do |endp|
    endp.vm.hostname = "vm-endp-02"
    endp.vm.network "private_network", ip: "192.168.56.52"

    endp.vm.provider "virtualbox" do |vb|
      vb.name   = "VM-ENDP-02"
      vb.memory = 1024
      vb.cpus   = 1
    end

    endp.vm.provision "shell", inline: <<-SHELL
      until nc -z 192.168.56.10 1515; do sleep 5; done
    SHELL
    endp.vm.provision "shell", path: "scripts/wazuh/install_agent.sh"
  end

end