Voici un fichier `README.md` rédigé à partir de votre description de l’étape 7.  
Il explique l’objectif, les fichiers créés, le redémarrage, les tests de validation et les critères de succès.

```markdown
# Étape 7 – LLM Gateway : appels réels à Ollama (Qwen3 14B)

Cette étape rend opérationnel le circuit d’appel au LLM local (Ollama).  
Elle introduit :

- une classe `LlmGateway` avec gestion de concurrence, timeout et retry ;
- des exceptions métier propres ;
- un endpoint debug `/debug/llm` pour tester directement le LLM ;
- des logs structurés (latence, tokens/s, raison d’arrêt).

---

## 📁 Fichiers modifiés / créés

| Fichier | Action |
|---------|--------|
| `app/fastapi/app/services/exceptions.py` | Création |
| `app/fastapi/app/services/llm_gateway.py` | Réécriture complète |
| `app/fastapi/app/api/routes_debug.py` | Réécriture complète |

---

## 🚀 Mise en place

### 1. Créer les trois fichiers

```bash
nano ~/soc-ai-lab/app/fastapi/app/services/exceptions.py
nano ~/soc-ai-lab/app/fastapi/app/services/llm_gateway.py
nano ~/soc-ai-lab/app/fastapi/app/api/routes_debug.py
```

Copier‑coller le contenu fourni dans chacun.

### 2. Redémarrer le service FastAPI

```bash
sudo systemctl restart soc-ai-fastapi
sleep 3
sudo systemctl status soc-ai-fastapi --no-pager | head -10
sudo journalctl -u soc-ai-fastapi -n 20 --no-pager
```

Aucune erreur d’import ne doit apparaître.

---

## ✅ Tests de validation

### Test 1 – Healthcheck

```bash
curl -s http://localhost:8000/health | jq
```

Résultat attendu : `{"status":"ok","ollama":"ok"}`

### Test 2 – Premier appel LLM (JSON)

```bash
time curl -s -X POST http://localhost:8000/debug/llm \
  -H 'Content-Type: application/json' \
  -d '{
    "prompt": "Tu es un assistant. Réponds UNIQUEMENT avec ce JSON exact: {\"status\":\"ok\",\"value\":42}",
    "json_format": true
  }' | jq
```

Résultat attendu (après 30‑90 secondes) :

```json
{
  "status": "ok",
  "response": {
    "status": "ok",
    "value": 42
  }
}
```

### Test 3 – Logs structurés

```bash
sudo journalctl -u soc-ai-fastapi -n 10 --no-pager | grep "LLM generation complete"
```

Vous devez voir une ligne JSON contenant `duration_ms`, `eval_count`, `tokens_per_second`, `done_reason`.

### Test 4 – Limitation de concurrence (sémaphore)

Lancer deux requêtes simultanément :

```bash
for i in 1 2; do
  (time curl -s -X POST http://localhost:8000/debug/llm \
    -H 'Content-Type: application/json' \
    -d "{\"prompt\":\"Réponds UNIQUEMENT: {\\\"id\\\":$i}\"}" \
    > /tmp/llm_$i.json) &
done
wait
```

Dans les logs FastAPI, la deuxième requête doit produire :

```
LLM call waited for semaphore ... wait_ms=...
```

La valeur `wait_ms` doit être proche du temps d’exécution de la première requête (≥ 30 000 ms).

### Test 5 – Timeout (retour HTTP 504)

```bash
# Sauvegarde du .env
cp ~/soc-ai-lab/config/.env ~/soc-ai-lab/config/.env.bak

# Forcer un timeout très bas (2 secondes)
sed -i 's/^OLLAMA_TIMEOUT_S=.*/OLLAMA_TIMEOUT_S=2/' ~/soc-ai-lab/config/.env
sudo systemctl restart soc-ai-fastapi
sleep 3

# La requête doit échouer avec 504
curl -s -w "\nHTTP %{http_code}\n" -X POST http://localhost:8000/debug/llm \
  -H 'Content-Type: application/json' \
  -d '{"prompt":"Réponds UNIQUEMENT: {\"x\":1}"}'

# Restaurer
cp ~/soc-ai-lab/config/.env.bak ~/soc-ai-lab/config/.env
sudo systemctl restart soc-ai-fastapi
```

Résultat attendu :  
- Code HTTP = `504`  
- Message `LLM timeout: Ollama timeout after 2 attempts`

### Test 6 – Mode texte brut (`json_format=false`)

```bash
curl -s -X POST http://localhost:8000/debug/llm \
  -H 'Content-Type: application/json' \
  -d '{
    "prompt": "Réponds en une phrase: pourquoi le ciel est bleu?",
    "json_format": false
  }' | jq
```

Le champ `response` doit être une chaîne de caractères (texte libre), pas un objet JSON.

---

## 📊 Critères de validation (tout doit être vert)

| Critère | Statut |
|---------|--------|
| `/health` répond `ok` | ☐ |
| Premier appel LLM renvoie le JSON attendu (latence 30‑90s) | ☐ |
| Logs contiennent `LLM generation complete` avec métriques | ☐ |
| Deux requêtes simultanées : la seconde attend (log `wait_ms`) | ☐ |
| Timeout à 2s → HTTP 504 (pas 500) | ☐ |
| Logs montrent 2 tentatives (`attempt 1`, `attempt 2`) | ☐ |
| `json_format=false` retourne du texte brut | ☐ |
| `json_format=true` retourne un `dict` JSON | ☐ |
| Pas de OOM killer après plusieurs appels (`dmesg \| tail -20`) | ☐ |

---

## ⚙️ Ajustement mémoire (si OOM)

Si `dmesg | tail` montre `Out of memory: Killed process`, réduisez le contexte :

```bash
sed -i 's/"num_ctx": 8192/"num_ctx": 4096/' \
  ~/soc-ai-lab/app/fastapi/app/services/llm_gateway.py
sudo systemctl restart soc-ai-fastapi
```

Cela limite la mémoire vive consommée par Qwen3 14B, au prix d’un contexte plus court.

---

## 🔜 Étape suivante (8)

Une fois tous les tests validés, nous pourrons :

- intégrer `PromptService` + `LlmGateway` + `ValidationService` ;
- persister les enrichissements dans Elasticsearch (indice `soc-ai-enrichments-*`) ;
- exposer les endpoints d’enrichissement complets (`/enrich/{alert_id}/{usage}`).

---

**À renvoyer après exécution des tests :**

1. Latence du test 2 (premier appel JSON)
2. `wait_ms` constaté dans les logs (test 4)
3. Code HTTP du test 5 (doit être 504)
4. Extrait de `dmesg | tail -20` (s’il y a OOM)
```

Ce README servira de documentation pour l’étape 7 et de checklist de validation.