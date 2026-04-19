# Architecture

## Lab topology

Six Ubuntu 22.04 (`ubuntu/jammy64`) VMs on a single VirtualBox host-only network (`192.168.56.0/24`). All inter-VM traffic stays on that network; the host reaches every VM over it too.

```
           host 192.168.56.1
                 │
 ┌───────────────┼─────────────────────────────────────────┐
 │ host-only network 192.168.56.0/24                       │
 │                                                         │
 │  10 VM-WAZUH-01 ──────────── 20 VM-ELK-01               │
 │      Wazuh manager              Elasticsearch + Kibana  │
 │      (HIDS, 1514/1515)          (9200, 5601)            │
 │                                                         │
 │  30 VM-SURI-01                  40 VM-AI-01             │
 │      Suricata (NIDS)            Ollama + FastAPI        │
 │      eth1 = span/promisc        (11434, 8000)           │
 │                                                         │
 │  51 VM-ENDP-01                  52 VM-ENDP-02           │
 │      Wazuh agent                Wazuh agent             │
 └─────────────────────────────────────────────────────────┘
```

## VM roles

### VM-WAZUH-01 — 192.168.56.10 (Wazuh manager)

Central HIDS receiving alerts from the endpoint agents.

- `wazuh-manager` 4.x (APT from `packages.wazuh.com`)
- Auto-enrollment on port **1515**, encrypted agent channel on **1514/tcp**
- Self-signed `sslmanager.cert` generated at install time
- JSON alert logging enabled (`jsonout_output`, `logall_json`) — ready for Filebeat shipping to ELK
- Baseline `syscheck` (realtime) on `/etc/passwd`, `/etc/shadow`, `/etc/sudoers`, `/etc/ssh/sshd_config`
- `active-response → firewall-drop` on rule `5763` (SSH brute force)

Resources: 4 GB RAM, 2 vCPU.

### VM-ELK-01 — 192.168.56.20 (Elastic Stack) — *pending*

Will host Elasticsearch + Kibana. No provisioning script yet; tracked in [roadmap.md](roadmap.md).

Resources (planned): 6 GB RAM, 2 vCPU.

### VM-SURI-01 — 192.168.56.30 (Suricata NIDS)

Network IDS listening on `enp0s8` (the host-only NIC) in promiscuous mode (`--nicpromisc2 allow-all` set at VM create time).

- Suricata from the `oisf/suricata-stable` PPA
- `HOME_NET = 192.168.56.0/24`
- Rulesets: upstream `suricata.rules` + lab `custom.rules`:
  - `9000001` — SSH brute force (5/60s per src)
  - `9000002` — TCP SYN port scan (20/10s per src)
  - `9000003` — ICMP flood (50/10s per src)
  - `9000004` — `curl` User-Agent to `$HOME_NET`
- Outputs: `eve.json` (rich — alert/http/dns/tls/ssh/flow/files/stats) + `fast.log`
- DNP3 / Modbus rules disabled via `update.d/disable.conf` (no SCADA in this lab)

Resources: 2 GB RAM, 2 vCPU.

### VM-AI-01 — 192.168.56.40 (AI enrichment) — *pending*

Will host Ollama (local LLM) and a FastAPI gateway for alert enrichment, SOC chat, and report generation. No provisioning script yet.

Resources (planned): 6 GB RAM, 4 vCPU.

### VM-ENDP-01 / VM-ENDP-02 — 192.168.56.51 / 52 (endpoints)

Ubuntu hosts running the Wazuh agent, registered to the manager at `192.168.56.10`.

- `wazuh-agent` 4.x installed via APT, auto-enrolls on boot
- Hostname becomes the agent name
- `auditd` installed with lab rules (`/etc/audit/rules.d/wazuh.rules`):
  - Watches `/etc/passwd`, `/etc/shadow`, `/etc/sudoers` (w,a)
  - Logs every `execve` syscall (keyed `exec_commands`)
- Provisioning waits for the manager's `1515/tcp` before running (`nc -z 192.168.56.10 1515`), so ordering is safe regardless of `vagrant up` order

Resources: 1 GB RAM, 1 vCPU each.

## Data flow (current)

```
endpoints (auditd, syslog)         Suricata (af-packet on enp0s8)
          │                                   │
          │ 1514/tcp (encrypted)              │ eve.json (local)
          ▼                                   ▼
   Wazuh manager (1514/1515)          /var/log/suricata/
          │
          │ alerts.json, archives.json
          ▼
     /var/ossec/logs/
```

## Data flow (planned)

```
 Wazuh manager ──┐               ┌── Suricata
                 │ Filebeat      │ Filebeat
                 ▼               ▼
            Elasticsearch (VM-ELK-01)
                 │
      ┌──────────┼──────────┐
      ▼                     ▼
   Kibana            FastAPI (VM-AI-01)
                           │
                           ▼
                    Ollama (local LLM)
                    ── explain / remediate / chat / report
```

See [roadmap.md](roadmap.md) for the full target module layout.
