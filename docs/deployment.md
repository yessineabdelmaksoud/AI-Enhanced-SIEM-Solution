# Deployment

How to bring the lab up from a clean machine.

## 1. Prerequisites

- **VirtualBox** 7.x (`VBoxManage --version` should work)
- **Vagrant** 2.4+ (`vagrant --version`)
- **~60 GB free disk**, **~20 GB free RAM** if running all six VMs at once
- No other VirtualBox VMs on the `192.168.56.0/24` host-only network

## 2. (Optional) Store VMs on a different drive

By default VirtualBox places VM disks under `%USERPROFILE%\VirtualBox VMs\` on Windows. For this lab, where six VMs easily consume 30–60 GB, you may want them on a different drive.

Two independent settings control this:

| What | Setting | Default | Size |
|---|---|---|---|
| Base box (`ubuntu/jammy64`) download | `VAGRANT_HOME` env var | `~/.vagrant.d` | ~500 MB |
| VM disks (`.vdi`) | VirtualBox "default machine folder" | `~/VirtualBox VMs` | tens of GB |

### Example: put everything on `D:\`

**PowerShell / cmd:**

```powershell
VBoxManage setproperty machinefolder "D:\VMs"
setx VAGRANT_HOME "D:\Vagrant\home"
# close and reopen the terminal so VAGRANT_HOME is picked up
```

**Git Bash / WSL:**

```bash
"/c/Program Files/Oracle/VirtualBox/VBoxManage.exe" setproperty machinefolder "D:\\VMs"
export VAGRANT_HOME="D:/Vagrant/home"
# add to your shell profile if you want this persistent
```

Verify:

```bash
VBoxManage list systemproperties | grep "machine folder"
# Default machine folder:    D:\VMs
```

The per-project `.vagrant/` directory (machine IDs, keys) stays next to the `Vagrantfile` — it's tiny and is ignored by git.

## 3. Bring up the lab

From the repo root:

```bash
vagrant up                  # bring up all six VMs (heavy)
vagrant up wazuh            # bring up a single VM
vagrant up wazuh endp01     # bring up a subset
```

Recommended first-run order if you want to go incrementally:

1. `vagrant up wazuh` — Wazuh manager must be ready before endpoints can enroll
2. `vagrant up suricata`
3. `vagrant up endp01 endp02` — endpoint provisioning already waits for `1515/tcp` on the manager, so order only matters for resource reasons
4. `vagrant up elk ai` — once provisioning scripts are added (see [roadmap.md](roadmap.md))

## 4. Daily use

```bash
vagrant status              # see which VMs are running
vagrant ssh wazuh           # shell into a VM
vagrant halt                # stop everything cleanly
vagrant reload wazuh        # restart + re-apply Vagrantfile tweaks
vagrant provision wazuh     # re-run provisioning scripts only
vagrant destroy -f          # wipe VMs (keeps the downloaded box)
```

## 5. Validating each VM

### Wazuh manager

```bash
vagrant ssh wazuh
sudo systemctl status wazuh-manager
sudo ss -tlnp | grep -E '1514|1515'   # both should be LISTEN
sudo tail /var/ossec/logs/alerts/alerts.json
```

### Wazuh agents (endp01 / endp02)

```bash
vagrant ssh endp01
sudo systemctl status wazuh-agent
# on the manager, list registered agents:
vagrant ssh wazuh -c "sudo /var/ossec/bin/agent_control -l"
```

### Suricata

```bash
vagrant ssh suricata
sudo systemctl status suricata
sudo tail /var/log/suricata/eve.json
# trigger a rule from another VM or the host:
for i in $(seq 1 10); do ssh bad-user@192.168.56.30 false; done
# → expect SOC-LAB SSH Brute Force in eve.json
```

## 6. Common issues

### `UID mismatch` when running `vagrant up`

```
The UID used to create the VM was: 1000
Your UID is: 0
```

The `.vagrant/` directory contains state from another user/machine (e.g. a teammate's Linux box committed it by accident). Fix:

```bash
rm -rf .vagrant/machines
vagrant up
```

`.vagrant/` is per-machine scratch state and is gitignored for this reason.

### `Default machine folder` didn't change

If `VBoxManage setproperty machinefolder` reports success but new VMs still land under `C:\Users\...\VirtualBox VMs`, you likely had the VirtualBox GUI open when you set it. Close the GUI and retry.

### Box download interrupted

If `vagrant up` fails mid-download of `ubuntu/jammy64`, rerun — Vagrant resumes the download. To fully reset the download cache:

```bash
vagrant box remove ubuntu/jammy64 --force
```

### Suricata fails on `enp0s8`

The interface name is hard-coded in the Vagrantfile (`args: ["enp0s8", ...]`). If your VirtualBox version names the second NIC differently, edit the script invocation in the Vagrantfile. Check from inside the VM with `ip -br link`.

### Firewall blocks agent enrollment

The install scripts enable `ufw` and open only the ports they need (22, 1514, 1515 on the manager; 22 on endpoints). If you add services, remember to open their ports or agent/endpoint traffic will silently drop.
