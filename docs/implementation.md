# Implémentation du Projet SOC-AI-Lab

Ce document décrit l'architecture et l'implémentation du projet AI-Enhanced SIEM (Security Information and Event Management).

## 0. Étapes d'implémentation (1 à 6)

- Étapes 1-2 : préparation et socle infra (voir [docs/plan.md](docs/plan.md)).
- Étape 3 : squelette FastAPI + health check (voir [docs/step_3_fastapi_health_documentation.md](docs/step_3_fastapi_health_documentation.md)).
- Étape 4 : AlertService + ContextService (voir [docs/step_4_alert_context_documentation.md](docs/step_4_alert_context_documentation.md)).
- Étape 5 : déduplication + scoring déterministe (voir [docs/step_5_dedup_scoring_documentation.md](docs/step_5_dedup_scoring_documentation.md)).
- Étape 6 : prompt builder + schémas JSON (voir [docs/step_6_prompt_builder_documentation.md](docs/step_6_prompt_builder_documentation.md)).

## 1. Architecture Infrastructure

### 1.1 Topologie des Machines Virtuelles

Le projet utilise Vagrant avec VirtualBox pour provisionner 6 machines virtuelles :

| VM | IP | Rôle | Mémoire | CPU |
|---|---|------|---------|-----|
| VM-WAZUH-01 | 192.168.56.10 | Wazuh Manager | 4 GB | 2 |
| VM-ELK-01 | 192.168.56.20 | Elasticsearch + Kibana | 6 GB | 2 |
| VM-SURI-01 | 192.168.56.30 | Suricata NIDS | 2 GB | 2 |
| VM-AI-01 | 192.168.56.40 | Ollama + FastAPI | 6 GB | 4 |
| VM-ENDP-01 | 192.168.56.51 | Endpoint Linux | 1 GB | 1 |
| VM-ENDP-02 | 192.168.56.52 | Endpoint Linux | 1 GB | 1 |

### 1.2 Réseau

- Réseau privé VirtualBox : 192.168.56.0/24
- Mode promiscuité activé sur VM-SURI-01 pour capture réseau

## 2. Composants de Sécurité

### 2.1 Wazuh (HIDS)

**Installation** : Script `scripts/wazuh/install_wazuh.sh`

**Configuration** :
- Manager écoutant sur ports 1514 (TCP) et 1515 (TCP)
- Authentification des agents activée
- Syscheck: surveillance fichiers `/etc/passwd`, `/etc/shadow`, `/etc/ssh/sshd_config`
- Analyse des logs `auth.log` et `syslog`
- Réponse active: `firewall-drop` pour blocages IOC 5763

**Agents** : Installés sur endpoints via `scripts/wazuh/install_agent.sh`

### 2.2 Suricata (NIDS)

**Installation** : Script `scripts/suricata/install_suricata.sh`

**Configuration** :
- Interface de capture: `enp0s8` (promiscuous)
- HOME_NET: 192.168.56.0/24
- Sorties: EVE-JSON (`eve.json`), Fast log (`fast.log`)
- Protocoles détectés: HTTP, DNS, TLS, SSH, FTP

**Règles custom** (SID 9000001-9000004) :
- SSH brute force (5 tentatives en 60s)
- Port scan (20 connexions en 10s)
- ICMP flood (50 paquets en 10s)
- User-Agent curl suspect

### 2.3 ELK Stack

**Installation** : Script `scripts/elk/install_elk.sh`

**Versions** : Elasticsearch 8.13.4, Kibana 8.13.4, Filebeat 8.13.4

**Sécurité** :
- TLS sur HTTP et Transport
- CA auto-générée via `elasticsearch-certutil`
- Authentification: utilisateur `elastic` (mot de passe: `SocSiem2024!`)
- API keys pour Filebeat avec privilèges segmentés par index

**Indices** :
- `wazuh-alerts-*` : alertes Wazuh
- `suricata-eve-*` : événements Suricata

## 3. Pipeline de Données

### 3.1 Flux de Logs

```
Endpoint (Wazuh Agent)
       │
       ▼tcp:1514
Wazuh Manager
       │
       ▼filebeat
Elasticsearch ────────▶ Kibana
       │
       ▼
Suricata (eve.json)
       │
       ▼filebeat
Elasticsearch
```

### 3.2 Filebeat

**Configuration** :
- `scripts/filebeat/install_filebeat_wazuh.sh` : lit `/var/ossec/logs/alerts/alerts.json`
- `scripts/filebeat/install_filebeat_suricata.sh` : lit `/var/log/suricata/eve.json`
- API key basée64: `id:api_key`

**Ingest Pipelines** :
- Normalisation champs timestamp
- Parsing JSON EVE
- Ajout champs metadata

## 4. Composants IA

### 4.1 Ollama

**Installation** : Script `scripts/ai/install_ollama.sh`

**Modèles** :
- llama2 ou mistral (configurable)
- Téléchargement via `ollama pull`

### 4.2 FastAPI

**Structure applicative** (`app/fastapi/`) :

```
app/
├── main.py              # Point d'entrée
├── api/
│   ├── routes_enrich.py # Enrichissement alertes
│   ├── routes_chat.py  # Chat SOC
│   ├── routes_report.py# Génération rapports
│   └── routes_health.py
├── core/
│   ├── config.py       # Configuration
│   ├── logging.py     # Logging
│   └── security.py   # Sécurité
├── services/
│   ├── alert_service.py
│   ├── enrichment_service.py
│   ├── chat_service.py
│   ├── llm_gateway.py
│   └── report_service.py
└── models/
    ├── request_models.py
    └── response_models.py
```

**Endpoints** :
- `POST /enrich` : enrichissement alertes
- `POST /chat` : assistance analyste
- `POST /report` : génération rapports

### 4.3prompts

**Fichiers prompts** (`config/ai/prompts/`) :
- `explain_prompt.txt` : explication alertes
- `remediation_prompt.txt` : recommandations
- `investigation_prompt.txt` : investigation
- `chat_soc_prompt.txt` : assistance interactive
- `report_prompt.txt` : rapports

## 5. Déploiement

### 5.1 Ordre de Provisionnement

```bash
# 1. ELK en premier — génère le CA et les API keys
vagrant up elk

# 2. Wazuh — attend /vagrant/certs/ca.crt
vagrant up wazuh

# 3. Suricata — attend /vagrant/certs/ca.crt
vagrant up suricata

# 4. Endpoints
vagrant up endp01 endp02

# 5. AI
vagrant up ai
```

### 5.2 Dépendances

- **ELK** : aucun prérequis (génère CA)
- **Wazuh** : attend `/vagrant/certs/ca.crt`
- **Suricata** : attend `/vagrant/certs/ca.crt`
- **Endpoints** : attend port 1515 (Wazuh authd)
- **Filebeat** : attend credentials via `/vagrant/certs/`

### 5.3 Vérifications Post-Déploiement

```bash
# Indices ELK
curl -sk -u elastic:SocSiem2024! \
  --cacert /etc/elasticsearch/certs/ca/ca.crt \
  https://192.168.56.20:9200/_cat/indices?v

# Statut cluster
curl -sk -u elastic:SocSiem2024! \
  --cacert /etc/elasticsearch/certs/ca/ca.crt \
  https://192.168.56.20:9200/_cluster/health
```

## 6. Services Système

### 6.1 Unités Systemd

```ini
# soc-ai-fastapi.service
[Unit]
Description=SOC-AI FastAPI
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/home/yessine/soc-ai-lab/app/fastapi
ExecStart=/usr/local/bin uvicorn main:app --host 0.0.0.0 --port 8000

[Install]
WantedBy=multi-user.target
```

### 6.2 Ports

| Service | Port | Protocole |
|--------|------|----------|
| Elasticsearch | 9200 | HTTPS |
| Kibana | 5601 | HTTP |
| Wazuh Manager | 1514, 1515 | TCP |
| FastAPI | 8000 | HTTP |
| Suricata | (interface) | - |

## 7. Structure des Fichiers

```
soc-ai-lab/
├── Vagrantfile                    #Provision VMs
├── scripts/
│   ├── elk/
│   │   ├── install_elk.sh        #ES + Kibana
│   │   └── create_templates.sh
│   ├── wazuh/
│   │   ├── install_wazuh.sh      #Wazuh Manager
│   │   └── install_agent.sh      #Wazuh Agent
│   ├── suricata/
│   │   └── install_suricata.sh   #NIDS
│   ├── filebeat/
│   │   ├── install_filebeat_wazuh.sh
│   │   └── install_filebeat_suricata.sh
│   └── ai/
│       ├── install_ollama.sh
│       └── install_fastapi.sh
├── config/
│   ├── elasticsearch/
│   │   └── index-templates/
│   ├── wazuh/
│   ├── suricata/
│   │   └── suricata.yaml
│   └── ai/
│       ├── prompts/
│       └── schemas/
├── app/
│   ├── fastapi/
│   └── ui/
├── docs/
│   ├── architecture/
│   ├── design/
│   └── operations/
└── data/
    └── samples/
```

## 8. Sécurisation

### 8.1 TLS/SSL

- Elasticsearch: TLS 1.3 sur HTTP et Transport
- Filebeat → ES: API key + TLS
- Wazuh → ES: TLS via Filebeat

### 8.2 Pare-feu (UFW)

| VM | Ports Ouverts |
|----|---------------|
| ELK | 22, 9200, 9300, 5601 |
| Wazuh | 22, 1514, 1515 |
| Suricata | 22 |
| AI | 22, 8000 |

### 8.3 Bonnes Pratiques en Labo

- Mots de passe fixes pour reproductibilité
- API keys avec privilèges minimaux
- CA auto-signée (non validée en prod)
- Audit logs activés

## 9. Extensions Futures

### 9.1 Évolution Possible

- **SIEM tiers**: Splunk, QRadar, Microsoft Sentinel
- **SOAR**: Shuffle, TheHive, Cortex
- **Threat Intelligence**: OTX, MISP
- **ML**: détection anomalies

### 9.2 Améliorations

- Surveillance容器
- Intégration cloud (AWS, Azure)
- Haute disponibilité
- Vault pour secrets
- Vault pour secrets

---

Document généré automatiquement based on code.