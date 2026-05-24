# Étape 3 — Squelette FastAPI, connexion Elasticsearch et health check

## 1. Objectif de l’étape

L’objectif de cette étape est de transformer la VM-AI en un vrai service backend capable de communiquer avec les deux briques principales du projet :

- **Elasticsearch**, qui contient les alertes Wazuh et Suricata.
- **Ollama**, qui exécute le modèle local Qwen3 14B.

À la fin de cette étape, l’API FastAPI doit exposer une route :

```text
GET /health
```

Cette route doit vérifier automatiquement :

```text
Elasticsearch accessible ?
Ollama accessible ?
Modèle configuré ?
Service FastAPI opérationnel ?
```

Résultat attendu :

```json
{
  "status": "ok",
  "elasticsearch": "ok",
  "ollama": "ok",
  "model": "qwen3:14b",
  "version": "0.1.0"
}
```

Cette étape ne fait pas encore l’enrichissement IA complet. Elle prépare la base technique pour les étapes suivantes : lecture des alertes, corrélation, appel LLM, validation JSON et persistance.

---

## 2. Architecture globale de l’étape 3

```text
Utilisateur / curl / navigateur
        |
        v
FastAPI sur vm-ai
http://10.110.188.66:8000
        |
        |------------------------------|
        |                              |
        v                              v
Elasticsearch                     Ollama
https://10.110.188.110:9200       http://localhost:11434
Wazuh + Suricata alerts           Qwen3 14B
```

FastAPI devient le point central entre le SIEM et l’IA.

---

## 3. Inventaire des VMs utilisées

| VM | IP | Rôle |
|---|---:|---|
| vm-elk | 10.110.188.110 | Elasticsearch + Kibana |
| vm-wazuh | 10.110.188.111 | Wazuh Manager |
| vm-suricata | 10.110.188.115 | Suricata NIDS |
| vm-endp1 | 10.110.188.114 | Wazuh Agent |
| vm-ai | 10.110.188.66 | Ollama + FastAPI |

---

## 4. Structure de fichiers de l’étape 3

Le projet est placé dans :

```bash
/home/vm-ai/soc-ai-lab/
```

Structure concernée par l’étape 3 :

```text
soc-ai-lab/
├── app/
│   └── fastapi/
│       ├── requirements.txt
│       ├── app/
│       │   ├── __init__.py
│       │   ├── main.py
│       │   ├── core/
│       │   │   ├── __init__.py
│       │   │   ├── config.py
│       │   │   └── logging.py
│       │   ├── api/
│       │   │   ├── __init__.py
│       │   │   └── routes_health.py
│       │   ├── repositories/
│       │   │   ├── __init__.py
│       │   │   └── elastic_repository.py
│       │   └── services/
│       │       ├── __init__.py
│       │       └── llm_gateway.py
│       └── tests/
│           └── __init__.py
│
├── config/
│   ├── .env.example
│   └── .env
│
├── certs/
│   └── ca.crt
│
├── systemd/
│   └── soc-ai-fastapi.service
│
└── scripts/
    └── ai/
        ├── 05_install_fastapi.sh
        └── 01_firewall_ai.sh
```

---

## 5. Préparation système

### 5.1 Création de l’arborescence

À exécuter sur **vm-ai** :

```bash
cd ~
mkdir -p ~/soc-ai-lab
cd ~/soc-ai-lab

mkdir -p config/ai/prompts/v1
mkdir -p config/ai/schemas/v1
mkdir -p certs
mkdir -p data/samples
mkdir -p logs
mkdir -p scripts/ai
mkdir -p systemd
mkdir -p docs
mkdir -p app/fastapi/app/{core,api,models,repositories,services,static/{css,js}}
mkdir -p app/fastapi/tests

touch app/fastapi/app/__init__.py
touch app/fastapi/app/{core,api,models,repositories,services}/__init__.py
touch app/fastapi/tests/__init__.py
```

### 5.2 Installation des paquets système

```bash
sudo apt update
sudo apt install -y \
  python3.11 \
  python3.11-venv \
  python3.11-dev \
  build-essential \
  tree \
  openssl \
  curl \
  jq \
  bc
```

Vérification :

```bash
python3.11 --version
```

Résultat attendu :

```text
Python 3.11.x
```

---

## 6. Certificat CA Elasticsearch

Elasticsearch utilise HTTPS. FastAPI doit donc utiliser le certificat CA pour se connecter proprement à Elasticsearch.

Sur **vm-elk**, le certificat est situé ici :

```text
/etc/elasticsearch/certs/ca/ca.crt
```

Comme le fichier appartient à `root:elasticsearch`, il faut le copier via `sudo`.

### 6.1 Copier le certificat depuis vm-elk vers vm-ai

À exécuter sur **vm-elk** :

```bash
sudo cp /etc/elasticsearch/certs/ca/ca.crt /tmp/ca.crt
sudo chmod 644 /tmp/ca.crt

ssh vm-ai@10.110.188.66 "mkdir -p ~/soc-ai-lab/certs"

scp /tmp/ca.crt vm-ai@10.110.188.66:~/soc-ai-lab/certs/ca.crt

rm /tmp/ca.crt
```

### 6.2 Vérifier le certificat sur vm-ai

À exécuter sur **vm-ai** :

```bash
ls -l ~/soc-ai-lab/certs/ca.crt
openssl x509 -in ~/soc-ai-lab/certs/ca.crt -noout -subject -issuer
```

Résultat attendu : OpenSSL affiche le `subject` et le `issuer`.

### 6.3 Tester Elasticsearch depuis vm-ai

```bash
curl --cacert ~/soc-ai-lab/certs/ca.crt \
  -u 'elastic:SocSiem2024!' \
  'https://10.110.188.110:9200/_cluster/health?pretty'
```

Résultat attendu :

```text
status: green ou yellow
```

Tester les index :

```bash
curl --cacert ~/soc-ai-lab/certs/ca.crt \
  -u 'elastic:SocSiem2024!' \
  'https://10.110.188.110:9200/_cat/indices?v'
```

Index attendus :

```text
wazuh-alerts-*
suricata-eve-*
```

Dans le lab, les index validés sont :

```text
wazuh-alerts-2026.05.07
wazuh-alerts-2026.05.08
suricata-eve-2026.05.07
suricata-eve-2026.05.08
```

---

## 7. Configuration `.env`

### 7.1 Fichier `config/.env.example`

Ce fichier est versionné et ne contient pas de vrai mot de passe.

```bash
cat > ~/soc-ai-lab/config/.env.example << 'EOF'
# Elasticsearch
ES_HOST=https://10.110.188.110:9200
ES_USER=elastic
ES_PASS=__REPLACE_ME__
ES_CA_CERT=/home/vm-ai/soc-ai-lab/certs/ca.crt
ES_INDEX_WAZUH=wazuh-alerts-*
ES_INDEX_SURICATA=suricata-eve-*
ES_INDEX_ENRICH=soc-ai-enrichments

# Ollama
OLLAMA_HOST=http://localhost:11434
OLLAMA_MODEL=qwen3:14b
OLLAMA_TIMEOUT_S=180

# FastAPI
FASTAPI_HOST=0.0.0.0
FASTAPI_PORT=8000
FASTAPI_LOG_LEVEL=INFO

# SOC-AI parameters
CONTEXT_WINDOW_MIN=15
DEDUP_TTL_MIN=30
LLM_MAX_CONCURRENT=1
EOF
```

### 7.2 Fichier `config/.env`

```bash
cp ~/soc-ai-lab/config/.env.example ~/soc-ai-lab/config/.env
nano ~/soc-ai-lab/config/.env
```

Remplacer :

```text
ES_PASS=__REPLACE_ME__
```

par :

```text
ES_PASS=SocSiem2024!
```

Sécuriser le fichier :

```bash
chmod 600 ~/soc-ai-lab/config/.env
```

Vérifier :

```bash
ls -la ~/soc-ai-lab/config/.env
grep ES_PASS ~/soc-ai-lab/config/.env
```

Résultat attendu :

```text
-rw------- 1 vm-ai vm-ai ...
ES_PASS=SocSiem2024!
```

---

## 8. Fichier `.gitignore`

Le fichier `.gitignore` empêche de versionner les secrets, les certificats et les fichiers temporaires.

```bash
cat > ~/soc-ai-lab/.gitignore << 'EOF'
# Secrets
config/.env
certs/*.crt
certs/*.key

# Python
__pycache__/
*.pyc
*.pyo
.venv/
.pytest_cache/

# Logs and runtime
logs/*.json
logs/*.csv
logs/*.txt
*.log

# IDE
.vscode/
.idea/
*.swp

# OS
.DS_Store
Thumbs.db
EOF
```

---

## 9. Les 10 fichiers créés dans l’étape 3

### 9.1 `app/fastapi/requirements.txt`

#### Rôle

Ce fichier contient les dépendances Python nécessaires au backend FastAPI.

Contenu :

```text
fastapi==0.115.6
uvicorn[standard]==0.32.1
pydantic==2.10.4
pydantic-settings==2.7.0
elasticsearch[async]==8.13.2
httpx==0.27.2
python-json-logger==2.0.7
jsonschema==4.23.0
```

#### But

Il rend l’environnement reproductible.

```bash
pip install -r requirements.txt
```

---

### 9.2 `app/fastapi/app/core/config.py`

#### Rôle

Ce fichier charge la configuration depuis :

```text
/home/vm-ai/soc-ai-lab/config/.env
```

Il utilise `pydantic-settings` pour transformer les variables d’environnement en objet Python `Settings`.

#### Variables lues

```text
ES_HOST
ES_USER
ES_PASS
ES_CA_CERT
ES_INDEX_WAZUH
ES_INDEX_SURICATA
ES_INDEX_ENRICH
OLLAMA_HOST
OLLAMA_MODEL
OLLAMA_TIMEOUT_S
FASTAPI_HOST
FASTAPI_PORT
FASTAPI_LOG_LEVEL
```

#### Communication

```text
config.py
   |
   |--> elastic_repository.py
   |--> llm_gateway.py
   |--> routes_health.py
   |--> main.py
```

#### But

Éviter les valeurs codées en dur dans le code Python.

---

### 9.3 `app/fastapi/app/core/logging.py`

#### Rôle

Ce fichier configure les logs JSON.

Exemple de log attendu :

```json
{
  "timestamp": "2026-05-08T13:00:00Z",
  "level": "INFO",
  "logger": "app.main",
  "message": "Application initialized"
}
```

#### But

Avoir des logs exploitables dans un environnement SOC/SIEM.

#### Communication

```text
main.py
   |
   v
configure_logging()
   |
   v
logs JSON dans journalctl
```

---

### 9.4 `app/fastapi/app/repositories/elastic_repository.py`

#### Rôle

Ce fichier contient la classe `ElasticRepository`.

Elle gère la connexion vers Elasticsearch :

```text
https://10.110.188.110:9200
```

avec :

```text
utilisateur: elastic
certificat: /home/vm-ai/soc-ai-lab/certs/ca.crt
```

#### Fonctions principales

```text
connect()
close()
ping()
get_alert_by_id()
search_context()
```

À l’étape 3, seule la fonction `ping()` est réellement utilisée par `/health`.

#### But

Centraliser l’accès à Elasticsearch au lieu de faire des appels Elasticsearch directement dans les routes FastAPI.

#### Communication

```text
routes_health.py
    |
    v
ElasticRepository.ping()
    |
    v
Elasticsearch HTTPS
```

---

### 9.5 `app/fastapi/app/services/llm_gateway.py`

#### Rôle

Ce fichier contient la classe `LlmGateway`.

Elle gère la communication avec Ollama :

```text
http://localhost:11434
```

#### Fonctions principales

```text
ping()
generate()
close()
```

À l’étape 3 :

```text
ping() vérifie Ollama avec /api/version
generate() n’est pas encore implémentée
```

#### But

Isoler la logique LLM dans un seul service.

#### Communication

```text
routes_health.py
    |
    v
LlmGateway.ping()
    |
    v
Ollama /api/version
```

Plus tard :

```text
EnrichmentService
    |
    v
LlmGateway.generate(prompt)
    |
    v
Ollama Qwen3 14B
```

---

### 9.6 `app/fastapi/app/api/routes_health.py`

#### Rôle

Ce fichier crée la route :

```text
GET /health
```

#### Fonctionnement

La route vérifie en parallèle :

```text
Elasticsearch
Ollama
```

avec :

```python
asyncio.gather(
    es_repo.ping(),
    llm_gw.ping(),
)
```

#### Réponse si tout est OK

```json
{
  "status": "ok",
  "elasticsearch": "ok",
  "ollama": "ok",
  "model": "qwen3:14b",
  "version": "0.1.0"
}
```

#### Réponse si un service est indisponible

```json
{
  "status": "degraded",
  "elasticsearch": "ok",
  "ollama": "down",
  "model": "qwen3:14b",
  "version": "0.1.0"
}
```

avec code HTTP :

```text
503
```

#### But

Valider rapidement l’état du backend SOC-AI.

---

### 9.7 `app/fastapi/app/main.py`

#### Rôle

C’est le point d’entrée principal de l’application.

Uvicorn lance :

```text
app.main:app
```

#### Ce que fait `main.py`

Au démarrage :

```text
1. Configure les logs JSON.
2. Charge les settings.
3. Crée le client Elasticsearch.
4. Crée le client Ollama.
5. Stocke les objets dans app.state.
6. Enregistre la route /health.
```

#### Communication

```text
main.py
   |
   |--> configure_logging()
   |--> get_settings()
   |--> ElasticRepository(settings)
   |--> LlmGateway(settings)
   |--> routes_health.router
```

#### But

Assembler toute l’application FastAPI.

---

### 9.8 `systemd/soc-ai-fastapi.service`

#### Rôle

Ce fichier permet de lancer FastAPI comme un service Linux.

Commandes utiles :

```bash
sudo systemctl start soc-ai-fastapi
sudo systemctl restart soc-ai-fastapi
sudo systemctl status soc-ai-fastapi
sudo journalctl -u soc-ai-fastapi -f
```

#### But

Rendre l’API professionnelle et persistante :

```text
démarrage automatique
redémarrage après erreur
logs dans journalctl
```

#### Communication

```text
systemd
   |
   v
uvicorn app.main:app
   |
   v
FastAPI écoute sur port 8000
```

---

### 9.9 `scripts/ai/05_install_fastapi.sh`

#### Rôle

Script d’installation automatique de FastAPI.

Il fait :

```text
1. Vérifie que config/.env existe.
2. Vérifie que requirements.txt existe.
3. Vérifie que le fichier systemd existe.
4. Crée le venv Python.
5. Installe les dépendances.
6. Copie le service systemd.
7. Active et démarre soc-ai-fastapi.
```

#### But

Rendre l’installation reproductible en une seule commande :

```bash
./scripts/ai/05_install_fastapi.sh
```

---

### 9.10 `scripts/ai/01_firewall_ai.sh`

#### Rôle

Script de configuration UFW pour la VM-AI.

Il autorise :

```text
SSH 22 depuis 10.110.188.0/24
FastAPI 8000 depuis 10.110.188.0/24
```

Il n’ouvre pas Ollama.

#### But

Sécuriser la VM-AI :

```text
FastAPI exposée
Ollama reste local
Elasticsearch reste protégé
```

---

## 10. Communication complète lors d’un `/health`

Quand on exécute :

```bash
curl http://localhost:8000/health
```

Le chemin est :

```text
curl
 |
 v
systemd lance uvicorn
 |
 v
main.py initialise FastAPI
 |
 |--> config.py lit .env
 |--> logging.py configure les logs
 |--> ElasticRepository se connecte à ES
 |--> LlmGateway prépare le client Ollama
 |
 v
routes_health.py reçoit /health
 |
 |--> ElasticRepository.ping()
 |        |
 |        v
 |     Elasticsearch HTTPS 10.110.188.110:9200
 |
 |--> LlmGateway.ping()
          |
          v
       Ollama localhost:11434/api/version
```

Réponse finale :

```json
{
  "status": "ok",
  "elasticsearch": "ok",
  "ollama": "ok",
  "model": "qwen3:14b",
  "version": "0.1.0"
}
```

---

## 11. Installation FastAPI

### 11.1 Donner les permissions au script

```bash
cd ~/soc-ai-lab
chmod +x scripts/ai/05_install_fastapi.sh
chmod +x scripts/ai/01_firewall_ai.sh
```

### 11.2 Installer FastAPI comme service systemd

```bash
./scripts/ai/05_install_fastapi.sh
```

### 11.3 Firewall

Optionnel si CloudStack Security Groups sont utilisés.

```bash
./scripts/ai/01_firewall_ai.sh
```

Si l’accès SSH ne vient pas du réseau `10.110.188.0/24`, ne pas exécuter UFW immédiatement.

---

## 12. Tests de validation

### 12.1 Tester `/health` localement

```bash
curl -s http://localhost:8000/health | jq
```

Résultat attendu :

```json
{
  "status": "ok",
  "elasticsearch": "ok",
  "ollama": "ok",
  "model": "qwen3:14b",
  "version": "0.1.0"
}
```

### 12.2 Tester depuis une autre machine

```bash
curl -s http://10.110.188.66:8000/health | jq
```

### 12.3 Lire les logs systemd

```bash
sudo journalctl -u soc-ai-fastapi -n 50 --no-pager
```

### 12.4 Tester la dégradation Ollama

```bash
sudo docker stop ollama
curl -s http://localhost:8000/health | jq
```

Résultat attendu :

```json
{
  "status": "degraded",
  "elasticsearch": "ok",
  "ollama": "down",
  "model": "qwen3:14b",
  "version": "0.1.0"
}
```

Puis redémarrer Ollama :

```bash
sudo docker start ollama
sleep 5
curl -s http://localhost:8000/health | jq
```

### 12.5 Documentation FastAPI

Dans un navigateur :

```text
http://10.110.188.66:8000/docs
```

---

## 13. Critères de validation de l’étape 3

| Critère | Statut attendu |
|---|---|
| Structure projet créée | OK |
| Python 3.11 disponible | OK |
| Certificat CA présent sur vm-ai | OK |
| Elasticsearch répond en HTTPS depuis vm-ai | OK |
| `.env` existe avec permission 600 | OK |
| `.venv` FastAPI créé | OK |
| Dépendances installées | OK |
| `soc-ai-fastapi` actif dans systemd | OK |
| `/health` retourne un JSON valide | OK |
| `elasticsearch: ok` | OK |
| `ollama: ok` | OK |
| `model: qwen3:14b` | OK |
| Logs en JSON | OK |
| Aucun secret visible dans les logs | OK |
| Service redémarre après `systemctl restart` | OK |

---

## 14. Résultat attendu de l’étape 3

À la fin de cette étape, on peut déclarer :

```text
La VM-AI dispose d’un backend FastAPI opérationnel. Le service est lancé par systemd, lit sa configuration depuis un fichier .env sécurisé, communique avec Elasticsearch en HTTPS à l’aide du certificat CA, vérifie la disponibilité d’Ollama localement, et expose une route /health utilisée pour valider l’état global de la couche SOC-AI.
```

---

## 15. Limites de cette étape

Cette étape ne fait pas encore :

```text
Lecture réelle d’une alerte par ID
Corrélation Wazuh + Suricata
Calcul du score de risque
Déduplication
Construction du prompt IA
Appel complet à Qwen3
Validation JSON de la réponse LLM
Persistance dans soc-ai-enrichments
Interface utilisateur
```

Ces éléments seront ajoutés dans les étapes suivantes.

---

## 16. Prochaine étape

Après validation de l’étape 3, on passe à :

```text
Étape 4 — Service Alertes + ContextService
```

Objectifs de l’étape 4 :

```text
1. Lire une alerte Wazuh ou Suricata par ID.
2. Normaliser les champs essentiels.
3. Construire un contexte corrélé autour de l’alerte.
4. Exposer une route de debug :
   GET /debug/context/{alert_id}
```

Cette étape permettra de passer de la simple vérification technique à la première logique métier SOC.