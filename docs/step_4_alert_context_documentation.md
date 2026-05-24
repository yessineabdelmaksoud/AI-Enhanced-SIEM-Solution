# Étape 4 — AlertService et ContextService

## 1. Objectif de l’étape

L’objectif de l’étape 4 est de passer d’une API qui vérifie seulement l’état du système à une API capable de lire une alerte réelle depuis Elasticsearch et de construire son contexte corrélé.

À la fin de cette étape, FastAPI doit pouvoir :

```text
1. Recevoir un alert_id.
2. Chercher cette alerte dans les index Wazuh et Suricata.
3. Normaliser les champs importants.
4. Identifier les entités corrélables : IP source, IP destination, host, user.
5. Chercher les événements proches dans le temps.
6. Retourner un contexte d’incident structuré.
```

La route principale ajoutée est :

```text
GET /debug/context/{alert_id}
```

---

## 2. Architecture logique

```text
Client / curl
    |
    v
FastAPI /debug/context/{alert_id}
    |
    v
routes_debug.py
    |
    |----> AlertService
    |          |
    |          v
    |       ElasticRepository.get_alert_by_id()
    |          |
    |          v
    |       Elasticsearch: wazuh-alerts-* + suricata-eve-*
    |
    v
ContextService
    |
    v
ElasticRepository.search_context()
    |
    v
Elasticsearch: recherche temporelle + entités communes
```

Cette étape introduit la première logique métier SOC dans l’API.

---

## 3. Fichiers créés ou modifiés

Pendant cette étape, les fichiers suivants sont créés ou modifiés :

```text
app/fastapi/app/models/alert.py
app/fastapi/app/repositories/elastic_repository.py
app/fastapi/app/services/alert_service.py
app/fastapi/app/services/context_service.py
app/fastapi/app/api/routes_debug.py
app/fastapi/app/main.py
```

---

## 4. Rôle des fichiers

### 4.1 `app/fastapi/app/models/alert.py`

Ce fichier contient les modèles Pydantic utilisés pour représenter les alertes et le contexte d’incident.

Il définit :

```text
AlertRef
Entity
AlertCore
ContextEvent
IncidentContext
```

#### `Entity`

Ce modèle représente les entités importantes extraites d’une alerte :

```text
source_ip
destination_ip
host_name
user_name
```

Ces entités sont utilisées pour construire la corrélation.

#### `AlertCore`

Ce modèle représente une alerte normalisée, qu’elle vienne de Wazuh ou de Suricata.

Champs principaux :

```text
id
index
timestamp
source_engine
rule_id
severity
description
mitre_id
mitre_tactic
entity
```

#### `ContextEvent`

Ce modèle hérite de `AlertCore` et ajoute :

```text
delta_seconds
```

`delta_seconds` représente l’écart temporel entre l’événement corrélé et l’alerte source.

#### `IncidentContext`

Ce modèle représente le résultat final de l’étape 4 :

```text
source_alert
related_events
occurrences
```

#### `from_es_doc()`

Cette fonction transforme un document Elasticsearch brut en `AlertCore`.

Elle gère deux types de documents :

```text
wazuh
suricata
```

Elle extrait les champs normalisés :

```text
wazuh.rule_id
wazuh.severity
wazuh.rule_description
suricata.rule_id
suricata.severity
suricata.signature
source.ip
destination.ip
host.name
user.name
```

Elle ajoute aussi des fallbacks pour les champs bruts :

```text
data.srcip
data.dstip
src_ip
dest_ip
agent.name
data.user
data.srcuser
data.dstuser
```

Le but de `alert.py` est d’avoir un format commun entre Wazuh et Suricata avant de faire la corrélation.

---

### 4.2 `app/fastapi/app/repositories/elastic_repository.py`

Ce fichier contient la classe `ElasticRepository`.

Elle centralise toute la communication avec Elasticsearch.

Fonctions importantes :

```text
connect()
close()
ping()
get_alert_by_id()
search_context()
```

#### `get_alert_by_id()`

Cette fonction cherche une alerte par son `_id` Elasticsearch.

Elle utilise une requête `ids` :

```json
{
  "ids": {
    "values": ["alert_id"]
  }
}
```

Cette méthode est plus fiable que de chercher `_id` avec un simple `term`.

#### `search_context()`

Cette fonction cherche les événements corrélés autour d’une alerte source.

Critères utilisés :

```text
@timestamp dans la fenêtre temporelle source.timestamp ± CONTEXT_WINDOW_MIN
au moins une entité commune
exclusion de l’alerte source
limite de 20 événements
tri par @timestamp ascendant
```

Entités utilisées pour la corrélation :

```text
source.ip
destination.ip
host.name
user.name
```

Fallbacks ajoutés pour les documents non normalisés :

```text
data.srcip
data.dstip
src_ip
dest_ip
wazuh.agent_name
agent.name
data.srcuser
data.dstuser
data.user
user_name
```

Le but de `ElasticRepository` est de fournir les données à la couche service sans exposer les détails Elasticsearch dans les routes API.

---

### 4.3 `app/fastapi/app/services/alert_service.py`

Ce fichier contient la classe `AlertService`.

Son rôle est de récupérer une alerte par ID sans que la route ait besoin de savoir si elle vient de Wazuh ou de Suricata.

Lorsqu’on appelle :

```python
get_alert(alert_id)
```

Le service cherche en parallèle dans :

```text
wazuh-alerts-*
suricata-eve-*
```

avec :

```python
asyncio.gather(...)
```

Si l’alerte est trouvée dans Wazuh :

```text
from_es_doc(wazuh_doc, "wazuh")
```

Si elle est trouvée dans Suricata :

```text
from_es_doc(suricata_doc, "suricata")
```

Si elle n’est pas trouvée :

```text
None
```

Le but de `AlertService` est de cacher la complexité multi-source. La route `/debug/context/{alert_id}` demande simplement une alerte, sans se préoccuper de son origine.

---

### 4.4 `app/fastapi/app/services/context_service.py`

Ce fichier contient la classe `ContextService`.

Son rôle est de construire le contexte corrélé autour d’une alerte source.

La fonction principale est :

```python
build_context(source: AlertCore)
```

Elle fait :

```text
1. Vérifie si l’alerte contient au moins une entité corrélable.
2. Prépare les entités : source_ip, destination_ip, host_name, user_name.
3. Cherche dans Wazuh + Suricata avec ElasticRepository.search_context().
4. Convertit chaque hit Elasticsearch en ContextEvent.
5. Calcule delta_seconds.
6. Calcule occurrences.
7. Retourne IncidentContext.
```

#### Cas sans entité corrélable

Si l’alerte ne contient aucune entité utile :

```text
source_ip = null
destination_ip = null
host_name = null
user_name = null
```

alors le service retourne :

```json
{
  "source_alert": "...",
  "related_events": [],
  "occurrences": 1
}
```

Ce n’est pas une erreur. Cela signifie simplement qu’il n’y a pas assez d’informations pour corréler.

#### Calcul `occurrences`

`occurrences` commence à 1 pour l’alerte source.

Pour chaque événement corrélé ayant le même `rule_id`, on incrémente `occurrences`.

Exemple :

```text
alerte source rule_id = 2013504
14 événements corrélés avec rule_id = 2013504
occurrences = 15
```

Le but de `ContextService` est de transformer une alerte isolée en mini-incident contextualisé.

---

### 4.5 `app/fastapi/app/api/routes_debug.py`

Ce fichier expose la route de debug :

```text
GET /debug/context/{alert_id}
```

Quand la route reçoit un `alert_id` :

```text
1. Elle appelle AlertService.get_alert(alert_id).
2. Si l’alerte n’existe pas, elle retourne 404.
3. Si l’alerte existe, elle appelle ContextService.build_context(alert).
4. Elle retourne un IncidentContext.
```

Si l’ID n’existe pas :

```json
{
  "detail": "Alert 'does-not-exist-1234' not found in wazuh-alerts-* or suricata-eve-*"
}
```

avec code HTTP :

```text
404
```

Cette route sert à valider visuellement l’étape 4 avant de passer à l’enrichissement IA.

---

### 4.6 `app/fastapi/app/main.py`

Ce fichier a été modifié pour ajouter les nouveaux services et la nouvelle route.

Ajouts réalisés :

```python
from app.api import routes_debug, routes_health
from app.services.alert_service import AlertService
from app.services.context_service import ContextService
```

Création des services dans le `lifespan` :

```python
app.state.alert_service = AlertService(es_repo, settings)
app.state.context_service = ContextService(es_repo, settings)
```

Ajout de la route debug :

```python
app.include_router(routes_debug.router, prefix="/debug", tags=["debug"])
```

`main.py` assemble maintenant :

```text
Health check
Elasticsearch repository
Ollama gateway
AlertService
ContextService
Debug route
```

---

## 5. Communication complète de l’étape 4

Quand on exécute :

```bash
curl http://localhost:8000/debug/context/<ALERT_ID>
```

Le chemin complet est :

```text
curl
 |
 v
FastAPI routes_debug.py
 |
 v
AlertService.get_alert(alert_id)
 |
 |----> ElasticRepository.get_alert_by_id(alert_id, wazuh-alerts-*)
 |
 |----> ElasticRepository.get_alert_by_id(alert_id, suricata-eve-*)
 |
 v
from_es_doc()
 |
 v
AlertCore
 |
 v
ContextService.build_context(AlertCore)
 |
 v
ElasticRepository.search_context()
 |
 v
Elasticsearch recherche les événements corrélés
 |
 v
ContextEvent[]
 |
 v
IncidentContext
 |
 v
Réponse JSON
```

---

## 6. Tests réalisés

### 6.1 Redémarrage du service

Commande :

```bash
sudo systemctl restart soc-ai-fastapi
sleep 2
sudo systemctl status soc-ai-fastapi --no-pager
```

Résultat :

```text
Active: active (running)
```

Conclusion :

```text
Le service FastAPI démarre correctement.
```

---

### 6.2 Test `/health`

Commande :

```bash
curl -s http://localhost:8000/health | jq
```

Résultat :

```json
{
  "status": "ok",
  "elasticsearch": "ok",
  "ollama": "ok",
  "model": "qwen3:14b",
  "version": "0.1.0"
}
```

Conclusion :

```text
FastAPI communique correctement avec Elasticsearch et Ollama.
```

---

### 6.3 Récupération d’un ID Wazuh

Commande :

```bash
WAZUH_ID=$(curl -sk --cacert ~/soc-ai-lab/certs/ca.crt \
  -u elastic:'SocSiem2024!' \
  "https://10.110.188.110:9200/wazuh-alerts-*/_search?size=1&pretty" \
  -H 'Content-Type: application/json' \
  -d '{"sort":[{"@timestamp":{"order":"desc"}}]}' \
  | jq -r '.hits.hits[0]._id')

echo "Wazuh ID: $WAZUH_ID"
```

Résultat :

```text
Wazuh ID: ZrD8DJ4B-2SSazc-ul2r
```

---

### 6.4 Test `/debug/context` sur une alerte Wazuh

Commande :

```bash
curl -s "http://localhost:8000/debug/context/$WAZUH_ID" | jq
```

Résultat résumé :

```json
{
  "source_alert": {
    "id": "ZrD8DJ4B-2SSazc-ul2r",
    "index": "wazuh-alerts-2026.05.09",
    "timestamp": "2026-05-09T13:45:34.983000Z",
    "source_engine": "wazuh",
    "rule_id": "5501",
    "severity": 3,
    "description": "PAM: Login session opened.",
    "mitre_id": ["T1078"],
    "entity": {
      "source_ip": null,
      "destination_ip": null,
      "host_name": "vmwazuh-CloudStack-KVM-Hypervisor",
      "user_name": null
    }
  },
  "related_events": [],
  "occurrences": 1
}
```

Analyse :

```text
Le test Wazuh fonctionne.
L’alerte est correctement récupérée et normalisée.
Le contexte est vide, car l’alerte choisie est une simple ouverture de session PAM avec peu d’entités corrélables.
Ce n’est pas une erreur.
```

---

### 6.5 Récupération d’un ID Suricata

Commande :

```bash
SURI_ID=$(curl -sk --cacert ~/soc-ai-lab/certs/ca.crt \
  -u elastic:'SocSiem2024!' \
  "https://10.110.188.110:9200/suricata-eve-*/_search?size=1&pretty" \
  -H 'Content-Type: application/json' \
  -d '{"sort":[{"@timestamp":{"order":"desc"}}]}' \
  | jq -r '.hits.hits[0]._id')

echo "Suricata ID: $SURI_ID"
```

Résultat :

```text
Suricata ID: YrCCDJ4B-2SSazc-sl3a
```

---

### 6.6 Test `/debug/context` sur une alerte Suricata

Commande :

```bash
curl -s "http://localhost:8000/debug/context/$SURI_ID" | jq
```

Résultat résumé :

```json
{
  "source_alert": {
    "id": "YrCCDJ4B-2SSazc-sl3a",
    "index": "suricata-eve-2026.05.09",
    "timestamp": "2026-05-09T11:32:19.155000Z",
    "source_engine": "suricata",
    "rule_id": "2013504",
    "severity": 3,
    "description": "ET INFO GNU/Linux APT User-Agent Outbound likely related to package management",
    "entity": {
      "source_ip": "10.110.188.115",
      "destination_ip": "185.125.190.81",
      "host_name": null,
      "user_name": null
    }
  },
  "related_events": [
    "14 événements corrélés"
  ],
  "occurrences": 15
}
```

Analyse :

```text
Le test Suricata est réussi.
Le service a trouvé plusieurs événements corrélés avec la même source IP, destination IP et rule_id.
La corrélation temporelle fonctionne.
Le compteur occurrences fonctionne.
```

---

## 7. Résultat validé

| Critère | Statut |
|---|---|
| `soc-ai-fastapi` démarre correctement | OK |
| `/health` répond 200 | OK |
| Elasticsearch répond via FastAPI | OK |
| Ollama répond via FastAPI | OK |
| Route `/debug/context/{alert_id}` disponible | OK |
| Une alerte Wazuh est récupérée par ID | OK |
| Une alerte Suricata est récupérée par ID | OK |
| Les champs sont normalisés en `AlertCore` | OK |
| Le contexte Suricata retourne des événements corrélés | OK |
| `occurrences` est calculé | OK |
| L’alerte inexistante doit retourner 404 | À tester |
| Corrélation Wazuh + Suricata sur brute force SSH | À tester |

---

## 8. Statut de l’étape 4

### Statut actuel

```text
Étape 4 : validée techniquement
```

La route fonctionne, le service démarre, les alertes sont récupérées, et la corrélation fonctionne au moins sur un cas Suricata réel.

### Validation complète restante

Pour valider pleinement l’étape 4 dans le contexte SOC, il reste à tester un scénario plus représentatif :

```text
SSH brute force
Wazuh rules: 5710, 5712, 5715, 5763
Suricata rule: SSH brute force / scan
```

L’objectif de ce test est d’obtenir :

```text
related_events > 0
context_engines contient wazuh et/ou suricata
context_rules contient plusieurs rule_id
```

---

## 9. Test recommandé avant de passer à l’étape 5

Chercher une alerte Wazuh SSH plus utile :

```bash
ID=$(curl -sk --cacert ~/soc-ai-lab/certs/ca.crt \
  -u elastic:'SocSiem2024!' \
  "https://10.110.188.110:9200/wazuh-alerts-*/_search" \
  -H 'Content-Type: application/json' \
  -d '{
    "size": 1,
    "query": {
      "bool": {
        "should": [
          {"terms": {"wazuh.rule_id": ["5710", "5712", "5715", "5763"]}},
          {"terms": {"rule.id": ["5710", "5712", "5715", "5763"]}}
        ],
        "minimum_should_match": 1
      }
    },
    "sort": [{"@timestamp": {"order": "desc"}}]
  }' | jq -r '.hits.hits[0]._id')

echo "SSH Wazuh ID: $ID"

time curl -s "http://localhost:8000/debug/context/$ID" | jq '{
  source: .source_alert,
  context_count: (.related_events | length),
  occurrences: .occurrences,
  engines: [.related_events[].source_engine] | unique,
  rules: [.related_events[].rule_id] | unique
}'
```

Si aucun ID n’est trouvé, générer quelques tentatives SSH échouées ou relancer le scénario Hydra.

---

## 10. Limites actuelles

Cette étape ne fait pas encore :

```text
Déduplication
Calcul de score de risque
Construction des prompts
Appel complet au LLM
Validation JSON des réponses IA
Persistance dans soc-ai-enrichments
Interface utilisateur
```

Ces éléments commencent à partir de l’étape 5.

---

## 11. Conclusion

Cette étape a ajouté la première vraie logique SOC au backend.

Avant cette étape, FastAPI vérifiait seulement que Elasticsearch et Ollama étaient disponibles.

Après cette étape, FastAPI peut :

```text
1. Lire une alerte réelle depuis Elasticsearch.
2. Détecter si elle vient de Wazuh ou Suricata.
3. Convertir le document en modèle commun AlertCore.
4. Extraire les entités importantes.
5. Chercher des événements corrélés dans une fenêtre temporelle.
6. Retourner un IncidentContext exploitable.
```

Cette étape prépare directement les prochaines briques :

```text
Étape 5 — Déduplication + score de risque
Étape 6 — Prompts + schémas JSON
Étape 7 — LLM Gateway complet
Étape 8 — Validation + persistance
```