# AI-Enhanced SIEM Solution

A self-contained SOC/SIEM lab that couples **Wazuh** (HIDS), **Suricata** (NIDS), **Elastic Stack** (log platform) and a local **LLM** (Ollama) to triage, enrich and explain security alerts. Runs entirely on a developer workstation via Vagrant + VirtualBox.

> **Status:** early lab bring-up. The Vagrant environment and the Wazuh + Suricata provisioning scripts are working. ELK, the AI VM, and the FastAPI/UI services are planned — see [docs/roadmap.md](docs/roadmap.md).

---

## Architecture at a glance

Six VMs on a single host-only network (`192.168.56.0/24`):

| VM            | IP              | Role                              | Provisioning |
| ------------- | --------------- | --------------------------------- | ------------ |
| `VM-WAZUH-01` | 192.168.56.10   | Wazuh manager (HIDS)              | done |
| `VM-ELK-01`   | 192.168.56.20   | Elasticsearch + Kibana            | pending |
| `VM-SURI-01`  | 192.168.56.30   | Suricata (NIDS) in promiscuous    | done |
| `VM-AI-01`    | 192.168.56.40   | Ollama + FastAPI enrichment       | pending |
| `VM-ENDP-01`  | 192.168.56.51   | Endpoint 1 (Wazuh agent)          | done |
| `VM-ENDP-02`  | 192.168.56.52   | Endpoint 2 (Wazuh agent)          | done |

See [docs/architecture.md](docs/architecture.md) for the full network plan and VM roles.

---

## Quickstart

Requirements: **VirtualBox** + **Vagrant** on the host. Total lab resources: ~20 GB RAM, 12 vCPUs, ~60 GB disk across VMs.

```bash
vagrant up              # boot everything (heavy)
vagrant up wazuh        # boot one VM only
vagrant ssh wazuh       # shell into a VM
vagrant halt            # stop all
vagrant destroy -f      # wipe all
```

Full deployment notes (including how to store VM disks on another drive, e.g. `D:\`) are in [docs/deployment.md](docs/deployment.md).

---

## Repository layout (current)

```
.
├─ Vagrantfile           # 6-VM lab definition
├─ scripts/
│  ├─ wazuh/
│  │  ├─ install_wazuh.sh     # Wazuh manager — ports 1514/1515, JSON logging
│  │  └─ install_agent.sh     # Wazuh agent — auto-enroll to 192.168.56.10
│  └─ suricata/
│     └─ install_suricata.sh  # Suricata + custom rules (SSH brute, port scan, ICMP flood)
├─ docs/
│  ├─ architecture.md
│  ├─ deployment.md
│  └─ roadmap.md
└─ README.md
```

The target full layout (app, config, systemd, etc.) is documented in [docs/roadmap.md](docs/roadmap.md).

---

## Documentation

- [docs/architecture.md](docs/architecture.md) — network plan, VM roles, data flow
- [docs/deployment.md](docs/deployment.md) — bringing the lab up, storage on `D:\`, common issues
- [docs/roadmap.md](docs/roadmap.md) — what's next, planned modules and file layout
