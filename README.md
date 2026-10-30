# AI-Enhanced SIEM Solution

A self-contained SOC/SIEM lab that couples **Wazuh** (HIDS), **Suricata** (NIDS), **Elastic Stack** (log platform) and a local **LLM** (Qwen3-14B on Ollama) to triage, enrich and explain security alerts. Everything runs on-premises via Vagrant + VirtualBox; no alert data leaves the lab.

The FastAPI enrichment service explains each alert in plain language, writes KQL queries to investigate it, and suggests remediation mapped to MITRE ATT&CK. Five attack scenarios (SSH brute force, port scan, file modification, ICMP flood, suspicious User-Agent) are scripted end to end.

---

## Architecture at a glance

Six VMs on a single host-only network (`192.168.56.0/24`):

| VM            | IP              | Role                              |
| ------------- | --------------- | --------------------------------- |
| `VM-WAZUH-01` | 192.168.56.10   | Wazuh manager (HIDS) + Filebeat   |
| `VM-ELK-01`   | 192.168.56.20   | Elasticsearch + Kibana            |
| `VM-SURI-01`  | 192.168.56.30   | Suricata (NIDS) + Filebeat        |
| `VM-AI-01`    | 192.168.56.40   | Ollama + FastAPI enrichment       |
| `VM-ENDP-01`  | 192.168.56.51   | Endpoint 1 (Wazuh agent)          |
| `VM-ENDP-02`  | 192.168.56.52   | Endpoint 2 (Wazuh agent)          |

See [docs/architecture.md](docs/architecture.md) for the full network plan and VM roles.

---

## Quickstart

Requirements: **VirtualBox** + **Vagrant** on the host. Total lab resources: ~20 GB RAM, 12 vCPUs, ~60 GB disk across VMs.

Boot the VMs in this order. ELK generates the CA and API keys the others need:

```bash
vagrant up elk              # 1. ES + Kibana, CA, API keys, index templates
vagrant up wazuh            # 2. waits for /vagrant/certs/ca.crt before starting Filebeat
vagrant up suricata         # 3. same
vagrant up endp01 endp02    # 4. endpoints with Wazuh agents
vagrant up ai               # 5. Ollama + FastAPI
```

Other useful commands:

```bash
vagrant ssh wazuh       # shell into a VM
vagrant halt            # stop all
vagrant destroy -f      # wipe all
```

Full deployment notes (including how to store VM disks on another drive, e.g. `D:\`) are in [docs/deployment.md](docs/deployment.md).

### Check that logs are flowing

From `VM-ELK-01`, using the `elastic` password set in [`scripts/elk/install_elk.sh`](scripts/elk/install_elk.sh):

```bash
curl -sk -u "elastic:$ES_PASS" \
  --cacert /etc/elasticsearch/certs/ca/ca.crt \
  "https://192.168.56.20:9200/_cat/indices?v"
# after a few minutes you should see:
# wazuh-alerts-YYYY.MM.DD    green  1  0
# suricata-eve-YYYY.MM.DD    green  1  0
```

Swap the path for `wazuh-alerts-*/_count` or `suricata-eve-*/_count` to count documents per source.

---

## Repository layout

```
.
├─ Vagrantfile                 # 6-VM lab definition
├─ app/fastapi/                # enrichment service: alerts, dedup, scoring, prompts, LLM gateway, validation, UI
├─ config/
│  ├─ .env.example
│  └─ ai/                      # versioned prompts, response schemas, remediation actions
├─ data/samples/
│  ├─ benchmark_prompt.txt
│  └─ scenarios/               # S1–S5 attack scenarios
├─ scripts/
│  ├─ wazuh/                   # manager + agent install
│  ├─ suricata/                # Suricata + custom rules
│  ├─ elk/                     # ES + Kibana, templates
│  ├─ filebeat/                # Wazuh and Suricata shippers
│  ├─ ai/                      # firewall, Ollama, model pull, benchmark, FastAPI install
│  └─ tests/                   # end-to-end scenario runs
├─ systemd/soc-ai-fastapi.service
└─ docs/
```

---

## Documentation

- [docs/architecture.md](docs/architecture.md): network plan, VM roles, data flow
- [docs/deployment.md](docs/deployment.md): bringing the lab up, storage on `D:\`, common issues
- [docs/evaluation.md](docs/evaluation.md): how the enrichment is evaluated
- [docs/demo_script.md](docs/demo_script.md): walkthrough of a demo run
- [docs/roadmap.md](docs/roadmap.md): planned modules
