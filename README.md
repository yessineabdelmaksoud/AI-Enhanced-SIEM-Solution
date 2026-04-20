<<<<<<< HEAD
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
=======
# AI-Enhanced-SIEM-Solution

```
soc-ai-lab/
├─ README.md
├─ Vagrantfile
├─ .gitignore
├─ docs/
│  ├─ architecture/
│  │  ├─ architecture-overview.md
│  │  ├─ data-flow.md
│  │  └─ diagrams/
│  │     ├─ architecture.mmd
│  │     └─ attack-scenarios.mmd
│  ├─ design/
│  │  ├─ functional-spec.md
│  │  ├─ modules-spec.md
│  │  └─ implementation-plan.md
│  └─ operations/
│     ├─ deployment-guide.md
│     ├─ troubleshooting.md
│     └─ validation-checklist.md
│
├─ config/
│  ├─ vagrant/
│  │  ├─ machines.yaml
│  │  └─ networks.yaml
│  ├─ elasticsearch/
│  │  ├─ elasticsearch.yml
│  │  ├─ kibana.yml
│  │  ├─ index-templates/
│  │  │  └─ soc-ai-alerts-template.json
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
│  ├─ ai/
│  │  ├─ ollama-models.yaml
│  │  ├─ prompts/
│  │  │  ├─ explain_prompt.txt
│  │  │  ├─ remediation_prompt.txt
│  │  │  ├─ investigation_prompt.txt
│  │  │  ├─ chat_soc_prompt.txt
│  │  │  └─ report_prompt.txt
│  │  └─ schemas/
│  │     ├─ enrich_response.schema.json
│  │     ├─ chat_query.schema.json
│  │     └─ report_response.schema.json
│  └─ firewall/
│     ├─ wazuh.rules
│     ├─ suricata.rules
│     ├─ elk.rules
│     └─ ai.rules
│
├─ scripts/
│  ├─ common/
│  │  ├─ bootstrap.sh
│  │  ├─ system_prep.sh
│  │  ├─ users.sh
│  │  ├─ firewall.sh
│  │  ├─ certs.sh
│  │  ├─ wait_for_service.sh
│  │  └─ helpers.sh
│  ├─ provision/
│  │  ├─ provision_elk.sh
│  │  ├─ provision_wazuh.sh
│  │  ├─ provision_suricata.sh
│  │  ├─ provision_ai.sh
│  │  ├─ provision_agents.sh
│  │  └─ post_checks.sh
│  ├─ elk/
│  │  ├─ install_elasticsearch.sh
│  │  ├─ install_kibana.sh
│  │  ├─ configure_elasticsearch.sh
│  │  ├─ create_index_templates.sh
│  │  ├─ create_ingest_pipelines.sh
│  │  └─ create_api_keys.sh
│  ├─ wazuh/
│  │  ├─ install_wazuh.sh
│  │  ├─ configure_wazuh.sh
│  │  ├─ install_filebeat_wazuh.sh
│  │  └─ install_agent.sh
│  ├─ suricata/
│  │  ├─ install_suricata.sh
│  │  ├─ configure_suricata.sh
│  │  ├─ install_filebeat_suricata.sh
│  │  └─ validate_span_interface.sh
│  ├─ ai/
│  │  ├─ install_ollama.sh
│  │  ├─ pull_model.sh
│  │  ├─ install_fastapi.sh
│  │  ├─ configure_fastapi_service.sh
│  │  ├─ install_ui.sh
│  │  └─ configure_ui_service.sh
│  ├─ agents/
│  │  ├─ linux/
│  │  │  └─ install_linux_agent.sh
│  │  └─ windows/
│  │     └─ install_windows_agent.ps1
│  └─ tests/
│     ├─ test_wazuh.sh
│     ├─ test_suricata.sh
│     ├─ test_elasticsearch.sh
│     ├─ test_fastapi.sh
│     ├─ test_ui.sh
│     └─ smoke_test_end_to_end.sh
│
├─ app/
│  ├─ fastapi/
│  │  ├─ main.py
│  │  ├─ api/
│  │  │  ├─ routes_enrich.py
│  │  │  ├─ routes_chat.py
│  │  │  ├─ routes_report.py
│  │  │  └─ routes_health.py
│  │  ├─ core/
│  │  │  ├─ config.py
│  │  │  ├─ logging.py
│  │  │  └─ security.py
│  │  ├─ services/
│  │  │  ├─ alert_service.py
│  │  │  ├─ dedup_service.py
│  │  │  ├─ context_service.py
│  │  │  ├─ prompt_service.py
│  │  │  ├─ llm_gateway.py
│  │  │  ├─ validation_service.py
│  │  │  ├─ enrichment_service.py
│  │  │  ├─ chat_service.py
│  │  │  ├─ report_service.py
│  │  │  ├─ scoring_service.py
│  │  │  └─ timeline_service.py
│  │  ├─ models/
│  │  │  ├─ request_models.py
│  │  │  └─ response_models.py
│  │  ├─ repositories/
│  │  │  └─ elastic_repository.py
│  │  ├─ prompts/
│  │  └─ tests/
│  ├─ ui/
│  │  ├─ app.py
│  │  ├─ templates/
│  │  ├─ static/
│  │  ├─ services/
│  │  │  ├─ api_client.py
│  │  │  └─ elastic_client.py
│  │  └─ tests/
│  └─ requirements/
│     ├─ fastapi.txt
│     ├─ ui.txt
│     └─ dev.txt
│
├─ systemd/
│  ├─ soc-ai-fastapi.service
│  ├─ soc-ai-ui.service
│  └─ soc-ai-worker.service
│
├─ data/
│  ├─ samples/
│  │  ├─ eve-samples.json
│  │  ├─ wazuh-alert-samples.json
│  │  └─ attack-scenarios/
│  └─ seeds/
│
├─ logs/
│  └─ .gitkeep
│
└─ tests/
   ├─ integration/
   ├─ e2e/
   └─ fixtures/

```





      1 siem-ai-project/
      2 ├── Vagrantfile                    # Configuration des VMs
      3 ├── .env                           # Variables d'environnement (non 
        versionné)
      4 ├── .gitignore
      5 ├── README.md
      6 │
      7 ├── provision/                     # Scripts de provisioning Vagrant
      8 │   ├── common.sh                  # Packages communs
      9 │   ├── wazuh.sh
     10 │   ├── suricata.sh
     11 │   ├── elasticsearch.sh
     12 │   ├── filebeat.sh
     13 │   ├── ollama.sh
     14 │   └── fastapi.sh
     15 │
     16 ├── configs/                       # Fichiers de configuration
     17 │   ├── wazuh/
     18 │   │   ├── ossec.conf
     19 │   │   └── local_decoder.xml
     20 │   ├── suricata/
     21 │   │   └── suricata.yaml
     22 │   ├── elasticsearch/
     23 │   │   ├── elasticsearch.yml
     24 │   │   └── index-templates/
     25 │   │       ├── wazuh-alerts.json
     26 │   │       ├── suricata-events.json
     27 │   │       └── ai-enrichments.json
     28 │   └── filebeat/
     29 │       └── filebeat.yml
     30 │
     31 ├── api/                           # Application FastAPI
     32 │   ├── pyproject.toml
     33 │   ├── Dockerfile                 # Optionnel (si containerisation)
     34 │   ├── app/
     35 │   │   ├── __init__.py
     36 │   │   ├── main.py                # Point d'entrée FastAPI
     37 │   │   ├── config.py              # Settings
     38 │   │   ├── models/
     39 │   │   │   ├── alert.py
     40 │   │   │   ├── enrichment.py
     41 │   │   │   └── chat.py
     42 │   │   ├── services/
     43 │   │   │   ├── alert_service.py      # Récupération alertes
     44 │   │   │   ├── context_service.py    # Construction contexte
     45 │   │   │   ├── dedup_service.py      # Déduplication
     46 │   │   │   ├── score_service.py      # Calcul score risque
     47 │   │   │   ├── prompt_service.py     # Génération prompts
     48 │   │   │   ├── validation_service.py # Validation réponses LLM
     49 │   │   │   ├── enrichment_service.py # Écriture enrichissements
     50 │   │   │   ├── report_service.py     # Génération rapports
     51 │   │   │   └── chat_service.py       # Chat SOC
     52 │   │   ├── llm_gateway/
     53 │   │   │   ├── __init__.py
     54 │   │   │   ├── gateway.py            # Interface LLM
     55 │   │   │   └── ollama_client.py      # Client Ollama
     56 │   │   ├── api/
     57 │   │   │   ├── __init__.py
     58 │   │   │   ├── routes/
     59 │   │   │   │   ├── enrichment.py
     60 │   │   │   │   ├── chat.py
     61 │   │   │   │   └── reports.py
     62 │   │   │   └── middleware.py
     63 │   │   └── utils/
     64 │   │       ├── elasticsearch_client.py
     65 │   │       └── validators.py
     66 │   └── tests/
     67 │       ├── test_enrichment.py
     68 │       ├── test_chat.py
     69 │       └── test_validation.py
     70 │
     71 ├── frontend/                      # Interface web analyste
     72 │   ├── index.html
     73 │   ├── css/
     74 │   │   └── style.css
     75 │   └── js/
     76 │       ├── app.js
     77 │       ├── incidents.js
     78 │       ├── chat.js
     79 │       └── reports.js
     80 │
     81 ├── ollama/                        # Configuration IA
     82 │   ├── Modelfile                  # Custom model config
     83 │   └── prompts/
     84 │       ├── explanation_prompt.json
     85 │       ├── investigation_prompt.json
     86 │       ├── remediation_prompt.json
     87 │       └── chat_system_prompt.json
     88 │
     89 ├── docs/                          # Documentation
     90 │   ├── architecture.md
     91 │   ├── flux.md
     92 │   └── api-spec.yaml              # OpenAPI/Swagger
     93 │
     94 └── scripts/                       # Scripts utilitaires
     95     ├── init-indices.sh            # Création index ES
     96     ├── seed-data.sh               # Données de test
     97     └── health-check.sh
--------------------------------------------------

# 1. ELK en premier — génère le CA et les API keys
vagrant up elk

# 2. Wazuh — attend /vagrant/certs/ca.crt avant de lancer Filebeat
vagrant up wazuh

# 3. Suricata — idem
vagrant up suricata

# 4. Endpoints
vagrant up endp01 endp02

# 5. AI — plus tard
vagrant up ai

projet/
├── Vagrantfile
└── scripts/
    ├── elk/
    │   ├── install_elk.sh          ← ES + Kibana + CA + API keys + templates
    │   └── create_templates.sh     ← appelé par install_elk.sh
    ├── filebeat/
    │   ├── install_filebeat_wazuh.sh     ← sur VM-WAZUH-01
    │   └── install_filebeat_suricata.sh  ← sur VM-SURI-01
    ├── wazuh/
    │   ├── install_wazuh.sh
    │   └── install_agent.sh
    └── suricata/
        └── install_suricata.sh


Points de vérification post-déploiement
bash# Depuis VM-ELK-01
curl -sk -u elastic:SocSiem2024! \
  --cacert /etc/elasticsearch/certs/ca/ca.crt \
  https://192.168.56.20:9200/_cat/indices?v

# Résultat attendu après quelques minutes :
# wazuh-alerts-YYYY.MM.DD    green  1  0
# suricata-eve-YYYY.MM.DD    green  1  0

# Vérifier données Wazuh
curl -sk -u elastic:SocSiem2024! \
  --cacert /etc/elasticsearch/certs/ca/ca.crt \
  "https://192.168.56.20:9200/wazuh-alerts-*/_count"

# Vérifier données Suricata
curl -sk -u elastic:SocSiem2024! \
  --cacert /etc/elasticsearch/certs/ca/ca.crt \
  "https://192.168.56.20:9200/suricata-eve-*/_count"
>>>>>>> e55a584 (Add installation scripts and configuration for ELK stack and Filebeat)
