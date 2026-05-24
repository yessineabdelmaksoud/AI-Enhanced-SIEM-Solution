# Étape 6 — Prompt builder et schémas JSON

## 1. Objectif

Définir trois templates de prompts versionnés (explication, investigation, remédiation) avec leurs schémas JSON de sortie. Implémenter le service de construction de prompt qui injecte le contexte dans le template choisi.

---

## 2. Trois usages, trois prompts, trois schémas

| Usage | Prompt | Schéma de sortie |
|---|---|---|
| explain | config/ai/prompts/v1/explain_prompt.txt | config/ai/schemas/v1/explain_response.schema.json |
| investigate | config/ai/prompts/v1/investigate_prompt.txt | config/ai/schemas/v1/investigate_response.schema.json |
| remediate | config/ai/prompts/v1/remediate_prompt.txt | config/ai/schemas/v1/remediate_response.schema.json |

---

## 3. Principes de prompting

- Les données sont **toujours** dans un bloc JSON séparé du prompt système, jamais inline en texte libre.
- Instructions explicites : **répondre uniquement en JSON valide conforme au schéma**.
- Remédiation : liste fixe de 10 actions, le LLM choisit un `action_id` existant.
- Langue : **français** pour `explain` et `remediate`, **technique** pour `investigate` (KQL).

---

## 4. Liste fixe d’actions de remédiation

| action_id | Libellé |
|---|---|
| isolate_host | Isoler l'hôte du réseau via la règle firewall |
| block_source_ip | Bloquer l'IP source au niveau du pare-feu périmétrique |
| force_password_reset | Forcer la réinitialisation du mot de passe utilisateur |
| disable_user_account | Désactiver temporairement le compte utilisateur |
| review_file_integrity | Vérifier l'intégrité des fichiers critiques modifiés |
| increase_logging | Augmenter le niveau de logs sur l'hôte concerné |
| escalate_to_l2 | Escalader à l'analyste L2 pour investigation approfondie |
| collect_forensics | Collecter une image mémoire et logs système |
| monitor_no_action | Surveiller sans action (faux positif probable, à confirmer) |
| close_false_positive | Marquer comme faux positif après vérification |

---

## 5. Livrables

```text
config/ai/prompts/v1/explain_prompt.txt
config/ai/prompts/v1/investigate_prompt.txt
config/ai/prompts/v1/remediate_prompt.txt
config/ai/schemas/v1/explain_response.schema.json
config/ai/schemas/v1/investigate_response.schema.json
config/ai/schemas/v1/remediate_response.schema.json
config/ai/remediation_actions.json
app/fastapi/app/services/prompt_service.py
```

---

## 6. Validation

### 6.1 Critères de réussite

- Les 3 schémas JSON valident une instance d’exemple via `jsonschema`.
- `PromptService.build("explain", ctx)` retourne une chaîne contenant `<DATA>...</DATA>` avec le contexte JSON.
- `PromptService.build("remediate", ctx)` inclut la liste des 10 `action_id`.
- Aucune fuite de variable non substituée (pas de `{{...}}` restant dans la sortie).

---

## 7. Prompts agent IA (trace de génération)

### Prompt 6.A — Schémas JSON et liste de remédiations

Contexte : définir trois schémas JSON Schema (draft 2020-12) pour les sorties LLM.

Tâche 1 : générer `config/ai/schemas/v1/explain_response.schema.json` :

```json
{
  "type": "object",
  "required": ["summary", "severity_assessment", "key_iocs", "attack_phase"],
  "additionalProperties": false,
  "properties": {
    "summary": {"type": "string", "minLength": 50, "maxLength": 800},
    "severity_assessment": {"enum": ["low", "medium", "high", "critical"]},
    "key_iocs": {"type": "array", "items": {"type": "string"}, "maxItems": 10},
    "attack_phase": {"enum": ["reconnaissance", "initial_access", "execution", "persistence", "privilege_escalation", "defense_evasion", "credential_access", "discovery", "lateral_movement", "collection", "exfiltration", "impact", "unknown"]},
    "mitre_techniques": {"type": "array", "items": {"type": "string", "pattern": "^T[0-9]{4}(\\.[0-9]{3})?$"}, "maxItems": 5}
  }
}
```

Tâche 2 : générer `config/ai/schemas/v1/investigate_response.schema.json` :

```json
{
  "type": "object",
  "required": ["queries", "rationale"],
  "additionalProperties": false,
  "properties": {
    "queries": {
      "type": "array",
      "minItems": 1,
      "maxItems": 3,
      "items": {
        "type": "object",
        "required": ["title", "kql", "expected_findings"],
        "properties": {
          "title": {"type": "string", "maxLength": 100},
          "kql": {"type": "string", "maxLength": 500},
          "expected_findings": {"type": "string", "maxLength": 200}
        }
      }
    },
    "rationale": {"type": "string", "maxLength": 400}
  }
}
```

Tâche 3 : générer `config/ai/schemas/v1/remediate_response.schema.json` :

```json
{
  "type": "object",
  "required": ["primary_action", "justification", "alternatives"],
  "additionalProperties": false,
  "properties": {
    "primary_action": {
      "enum": [
        "isolate_host",
        "block_source_ip",
        "force_password_reset",
        "disable_user_account",
        "review_file_integrity",
        "increase_logging",
        "escalate_to_l2",
        "collect_forensics",
        "monitor_no_action",
        "close_false_positive"
      ]
    },
    "justification": {"type": "string", "minLength": 30, "maxLength": 400},
    "alternatives": {
      "type": "array",
      "items": {
        "enum": [
          "isolate_host",
          "block_source_ip",
          "force_password_reset",
          "disable_user_account",
          "review_file_integrity",
          "increase_logging",
          "escalate_to_l2",
          "collect_forensics",
          "monitor_no_action",
          "close_false_positive"
        ]
      },
      "maxItems": 3,
      "uniqueItems": true
    },
    "confidence": {"type": "number", "minimum": 0, "maximum": 1}
  }
}
```

Tâche 4 : générer `config/ai/remediation_actions.json` (liste de 10 objets `{id, label_fr, description_fr}`).

Sortie : 4 fichiers complets, JSON valide.

---

### Prompt 6.B — Prompts versionnés

Contexte : trois templates de prompts pour Qwen3 14B. Le modèle reçoit un prompt système + un bloc DATA en JSON. Ne pas concaténer les valeurs des alertes en texte libre dans le prompt système (risque d’injection).

Tâche : générer les trois fichiers prompts. Format de chacun : un prompt système clair, suivi d’un placeholder `<DATA_PLACEHOLDER>` remplacé par `PromptService`.

- `config/ai/prompts/v1/explain_prompt.txt` :
  - rôle : analyste SOC senior
  - objectif : produire une explication contextualisée d’un incident
  - contraintes : JSON valide uniquement, conforme au schéma fourni
  - instructions : examiner `source_alert` + `related_events`, identifier la phase d’attaque, extraire les IoCs depuis les champs structurés
  - mapping MITRE si `rule.mitre.id` présent
  - réponse en français, ton technique mais clair
  - terminaison :
    ```text
    Réponds UNIQUEMENT avec un JSON valide. Voici le contexte de l’incident :
    <DATA_PLACEHOLDER>
    ```

- `config/ai/prompts/v1/investigate_prompt.txt` :
  - rôle : analyste SOC
  - objectif : proposer 1 à 3 requêtes KQL Elasticsearch
  - index disponibles : `wazuh-alerts-*`, `suricata-eve-*`
  - champs autorisés : `@timestamp`, `source.ip`, `destination.ip`, `host.name`, `user.name`, `wazuh.rule_id`, `suricata.rule_id`, `event.dataset`
  - contrainte : toujours filtrer sur `@timestamp`, max 500 caractères par requête
  - terminaison : `<DATA_PLACEHOLDER>`

- `config/ai/prompts/v1/remediate_prompt.txt` :
  - rôle : analyste SOC qui décide d’une action immédiate
  - objectif : choisir **UNE** action parmi la liste fixe (10 `action_id`)
  - la liste des 10 actions et leurs descriptions est incluse dans le prompt
  - justification en français (30 à 400 caractères)
  - alternatives : 0 à 3 autres `action_id`
  - confidence : estimation entre 0 et 1
  - terminaison : `<DATA_PLACEHOLDER>`

Sortie : 3 fichiers texte complets.

---

### Prompt 6.C — PromptService

Contexte : charger les prompts au démarrage et les remplir avec un `IncidentContext`.

Tâche : générer `app/fastapi/app/services/prompt_service.py` :

```python
class PromptService:
    def __init__(self, prompts_dir: Path)
    def _load_template(self, usage: str) -> str  # lit config/ai/prompts/v1/{usage}_prompt.txt, cache mémoire
    def build(self, usage: Literal["explain", "investigate", "remediate"], ctx: IncidentContext) -> str:
        # 1. charger le template
        # 2. sérialiser ctx en JSON compact (model_dump_json), champs utiles uniquement
        # 3. remplacer <DATA_PLACEHOLDER> par le JSON
        # 4. tronquer si > 6000 tokens estimés (1 token ~ 4 chars)
        # 5. retourner la chaîne finale

    def list_remediation_actions(self) -> list[dict]  # charge config/ai/remediation_actions.json
```

Contraintes :

- chargement paresseux + cache
- erreur explicite si placeholder manquant
- pas de Jinja, simple `str.replace`

Sortie : fichier complet.

---

## 8. Résultat attendu

Cette étape fournit :

- des **prompts versionnés** propres, sûrs et reproductibles,
- des **schémas JSON stricts** pour valider les sorties LLM,
- un **PromptService** prêt à injecter un contexte sans fuite de données sensibles,
- une base prête pour l’étape 7 (LLM Gateway complet).
