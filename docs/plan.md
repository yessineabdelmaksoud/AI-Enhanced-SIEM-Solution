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
      3 ├── .env                           # Variables d'environnement (non versionné)
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



```
pfa
├─ AI-Enhanced-SIEM-Solution
│  ├─ data
│  │  └─ samples
│  │    └─ benchmark_prompt.txt
│  │     └── scenarios/                        [étape 11]
│  │         ├── S1_brute_force.md
│  │         ├── S2_port_scan.md
│  │         ├── S3_file_modify.md
│  │         ├── S4_icmp_flood.md
│  │         └── S5_user_agent.md
│  ├─ scripts
│  │  ├─ ai
│  │  │  ├─ 02setup_ollama_vm.sh
│  │  │  ├─ 03_pull_model.sh
│  │  │  └─ 04_benchmark_llm.sh
│  │  ├─ elk
│  │  │  ├─ create_templates.sh
│  │  │  └─ install_elk.sh
│  │  ├─ filebeat
│  │  │  ├─ install_filebeat_suricata.sh
│  │  │  └─ install_filebeat_wazuh.sh
│  │  ├─ suricata
│  │  │  └─ install_suricata.sh
│  │  └─ wazuh
│  │     ├─ install_agent.sh
│  │     └─ install_wazuh.sh
├── systemd/
│   └── soc-ai-fastapi.service                [TODO étape 3]
├── logs/
│   ├── benchmark_*.txt                       ✓ existe
│   └── benchmark_*.csv                       ✓ existe
├── app/
│   └── fastapi/
│       ├── requirements.txt                  [TODO étape 3]
│       ├── app/
│       │   ├── __init__.py
│       │   ├── main.py                       [TODO étape 3]
│       │   ├── core/
│       │   │   ├── config.py                 [TODO étape 3]
│       │   │   └── logging.py                [TODO étape 3]
│       │   ├── api/
│       │   │   ├── routes_health.py          [TODO étape 3]
│       │   │   ├── routes_debug.py           [étape 4]
│       │   │   ├── routes_enrich.py          [étape 9]
│       │   │   └── routes_incidents.py       [étape 9]
│       │   ├── models/
│       │   │   └── alert.py                  [étape 4]
│       │   ├── repositories/
│       │   │   └── elastic_repository.py     [TODO étape 3]
│       │   ├── services/
│       │   │   ├── llm_gateway.py            [TODO étape 3 stub, étape 7 complet]
│       │   │   ├── exceptions.py             [étape 7]
│       │   │   ├── alert_service.py          [étape 4]
│       │   │   ├── context_service.py        [étape 4]
│       │   │   ├── dedup_service.py          [étape 5]
│       │   │   ├── scoring_service.py        [étape 5]
│       │   │   ├── prompt_service.py         [étape 6]
│       │   │   ├── validation_service.py     [étape 8]
│       │   │   └── enrichment_service.py     [étape 8]
│       │   └── static/                       [étape 10]
│       │       ├── index.html
│       │       ├── incident.html
│       │       ├── health.html
│       │       ├── css/style.css
│       │       └── js/
│       │           ├── api.js
│       │           ├── incidents.js
│       │           └── detail.js
│       └── tests/
│           ├── conftest.py                   [étape 5]
│           └── test_scoring.py               [étape 5]
├── README.md                                 [TODO]
├── .gitignore                                [TODO]
│
├── config/                                   [TODO étape 3]
│   ├── .env.example                          # versionné
│   ├── .env                                  # git-ignoré
│   └── ai/
│       ├── prompts/v1/
│       │   ├── explain_prompt.txt            [étape 6]
│       │   ├── investigate_prompt.txt        [étape 6]
│       │   └── remediate_prompt.txt          [étape 6]
│       ├── schemas/v1/
│       │   ├── explain_response.schema.json  [étape 6]
│       │   ├── investigate_response.schema.json
│       │   └── remediate_response.schema.json
│       └── remediation_actions.json          [étape 6]
│
├── certs/
│   └── ca.crt                                [TODO étape 3 - copier de vm-elk]
```