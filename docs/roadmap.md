# Roadmap

Where the project stands and what comes next.

## Done

- Vagrant lab topology (6 VMs, host-only network `192.168.56.0/24`)
- Wazuh manager provisioning ([`scripts/wazuh/install_wazuh.sh`](../scripts/wazuh/install_wazuh.sh))
- Wazuh agent provisioning with auditd rules ([`scripts/wazuh/install_agent.sh`](../scripts/wazuh/install_agent.sh))
- Suricata NIDS provisioning with lab custom rules ([`scripts/suricata/install_suricata.sh`](../scripts/suricata/install_suricata.sh))

## Next up

### 1. ELK VM (`VM-ELK-01`)

- `scripts/elk/install_elasticsearch.sh` — single-node ES, auth disabled for lab
- `scripts/elk/install_kibana.sh` — bound to `192.168.56.20:5601`
- Index templates for `wazuh-alerts-*` and `suricata-events-*`
- Ingest pipelines to normalize `eve.json` and Wazuh JSON

### 2. Ship logs

- Filebeat on the Wazuh manager (`alerts.json` → ES)
- Filebeat on Suricata (`eve.json` → ES)

### 3. AI VM (`VM-AI-01`)

- `scripts/ai/install_ollama.sh` — pull a small model (e.g. `llama3.1:8b-instruct-q4_K_M`)
- `scripts/ai/install_fastapi.sh` — enrichment gateway
- FastAPI service (`app/fastapi/`): `/enrich`, `/chat`, `/report`, `/health`
- Minimal analyst UI (`app/ui/`)

### 4. End-to-end smoke test

- Trigger SSH brute force from host → expect Wazuh rule + Suricata `9000001` alert → both in ES → FastAPI enrichment returns explanation/remediation

## Planned full layout

This is the target structure the project is moving toward. Not everything will be needed for the PFA milestone — treat it as a north star, not a checklist.

```
.
├─ Vagrantfile
├─ README.md
├─ .gitignore
│
├─ docs/
│  ├─ architecture.md
│  ├─ deployment.md
│  ├─ roadmap.md
│  └─ diagrams/
│     ├─ architecture.mmd
│     └─ attack-scenarios.mmd
│
├─ config/
│  ├─ elasticsearch/
│  │  ├─ elasticsearch.yml
│  │  ├─ kibana.yml
│  │  ├─ index-templates/
│  │  │  ├─ wazuh-alerts.json
│  │  │  └─ suricata-events.json
│  │  └─ ingest-pipelines/
│  │     ├─ wazuh-pipeline.json
│  │     └─ suricata-pipeline.json
│  ├─ filebeat/
│  │  ├─ wazuh-filebeat.yml
│  │  └─ suricata-filebeat.yml
│  ├─ suricata/
│  │  ├─ suricata.yaml
│  │  └─ custom-rules.rules
│  ├─ wazuh/
│  │  ├─ ossec.conf
│  │  ├─ local_rules.xml
│  │  └─ agent.conf
│  └─ ai/
│     ├─ ollama-models.yaml
│     └─ prompts/
│        ├─ explain_prompt.txt
│        ├─ remediation_prompt.txt
│        ├─ investigation_prompt.txt
│        ├─ chat_soc_prompt.txt
│        └─ report_prompt.txt
│
├─ scripts/
│  ├─ wazuh/            # done (manager + agent)
│  ├─ suricata/         # done (install)
│  ├─ elk/              # pending
│  ├─ ai/               # pending
│  └─ tests/            # pending — end-to-end smoke tests
│
├─ app/
│  ├─ fastapi/          # pending — enrichment gateway
│  │  ├─ main.py
│  │  ├─ api/           # routes: enrich, chat, report, health
│  │  ├─ services/      # alert, dedup, context, prompt, llm_gateway, validation, ...
│  │  └─ models/
│  └─ ui/               # pending — analyst UI
│
├─ systemd/             # service units for the AI VM
│  ├─ soc-ai-fastapi.service
│  └─ soc-ai-ui.service
│
└─ data/
   └─ samples/          # eve.json + wazuh alert samples for offline dev
```

## Open questions

- **Auth on Elastic:** lab is safe without it; production isn't. Decide before the PFA demo whether to enable basic auth + TLS or leave open.
- **Model choice:** smallest useful model that runs on 6 GB RAM for `VM-AI-01`. Candidates: `llama3.1:8b-q4`, `mistral:7b-instruct-q4`, `qwen2.5:7b-instruct-q4`.
- **Alert volume:** with the default Wazuh rules + Suricata full ruleset, expect thousands of events/day even in a quiet lab. Plan a dedup/score layer before the LLM so we don't enrich noise.
