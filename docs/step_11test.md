Dernière étape. Je livre les 4 ensembles de fichiers. Adaptation à ton infra réelle : un seul endpoint (`vm-endp1` = 10.110.188.114), attaques lancées depuis `vm-ai`. Les scénarios Suricata nécessitent des règles locales déterministes (plus fiables que l'ETP ruleset pour une démo).

## 0. Création des dossiers

```bash
mkdir -p ~/soc-ai-lab/data/samples/scenarios
mkdir -p ~/soc-ai-lab/scripts/tests
mkdir -p ~/soc-ai-lab/docs
```

## 1. Prérequis

**Outils sur vm-ai :**
```bash
sudo apt-get install -y hydra nmap curl iputils-ping jq
printf 'admin\nroot\ntest\npassword\n123456\nqwerty\nletmein\n' > /tmp/wordlist.txt
```

**Règles Suricata locales (sur vm-suricata)** — fichier `/etc/suricata/rules/local.rules` :
```bash
sudo tee -a /etc/suricata/rules/local.rules > /dev/null << 'EOF'
alert tcp any any -> $HOME_NET 22 (msg:"LOCAL SSH brute force"; flow:to_server; flags:S; threshold:type both, track by_src, count 5, seconds 30; classtype:attempted-admin; sid:9000001; rev:1;)
alert tcp any any -> $HOME_NET any (msg:"LOCAL Port scan"; flags:S; threshold:type both, track by_src, count 20, seconds 10; classtype:attempted-recon; sid:9000002; rev:1;)
alert icmp any any -> $HOME_NET any (msg:"LOCAL ICMP flood"; itype:8; threshold:type both, track by_src, count 50, seconds 5; classtype:misc-activity; sid:9000003; rev:1;)
alert http any any -> any any (msg:"LOCAL Suspicious User-Agent EvilScanner"; flow:to_server; http.user_agent; content:"EvilScanner"; nocase; classtype:trojan-activity; sid:9000004; rev:1;)
EOF

# Vérifier que local.rules est inclus dans suricata.yaml (rule-files:) puis :
sudo suricata -T -c /etc/suricata/suricata.yaml && sudo systemctl restart suricata
```

Vérifie que `HOME_NET` inclut `10.110.188.0/24`. Pour la FIM (S3), `/etc` doit être surveillé en temps réel côté agent : `<directories realtime="yes">/etc</directories>` dans `ossec.conf`, sinon S3 dépassera le timeout (écart à documenter).

---

## 2. Scénarios

```bash
cat > ~/soc-ai-lab/data/samples/scenarios/S1.md << 'EOF'
# S1 — SSH brute force

**Objectif** : détecter une attaque par force brute SSH (Wazuh sshd + Suricata 9000001).

**Cible** : vm-endp1 (10.110.188.114:22)
**Attaquant** : vm-ai

## Simulation
```bash
hydra -l root -P /tmp/wordlist.txt -t 4 -f ssh://10.110.188.114 || true
```

## Détection attendue
- Wazuh : rule_id 5710 (utilisateur inexistant), 5712/5763 (brute force)
- Suricata : sid 9000001

## Vérification ES
```bash
curl -sk --cacert ~/soc-ai-lab/certs/ca.crt -u elastic:'SocSiem2024!' \
  "https://10.110.188.110:9200/wazuh-alerts-*/_search" -H 'Content-Type: application/json' \
  -d '{"size":1,"query":{"bool":{"must":[{"terms":{"wazuh.rule_id":["5763","5712","5710","5716"]}}],"filter":[{"range":{"@timestamp":{"gte":"now-3m"}}}]}},"sort":[{"@timestamp":{"order":"desc"}}]}' | jq '.hits.hits[0]._id'
```

## Enrichissement attendu
- explain : phase credential_access, MITRE T1110.001
- remediate : block_source_ip
- 3/3 validated=true
EOF
```

```bash
cat > ~/soc-ai-lab/data/samples/scenarios/S2.md << 'EOF'
# S2 — Port scan

**Objectif** : détecter une reconnaissance par balayage de ports (Suricata 9000002).

**Cible** : vm-endp1 (10.110.188.114)
**Attaquant** : vm-ai

## Simulation
```bash
sudo nmap -sS -p 1-1000 -T4 10.110.188.114 || true
```

## Détection attendue
- Suricata : sid 9000002 (≥20 SYN en 10s)

## Vérification ES
```bash
curl -sk --cacert ~/soc-ai-lab/certs/ca.crt -u elastic:'SocSiem2024!' \
  "https://10.110.188.110:9200/suricata-eve-*/_search" -H 'Content-Type: application/json' \
  -d '{"size":1,"query":{"bool":{"must":[{"term":{"event_type":"alert"}},{"term":{"alert.signature_id":9000002}}],"filter":[{"range":{"@timestamp":{"gte":"now-3m"}}}]}},"sort":[{"@timestamp":{"order":"desc"}}]}' | jq '.hits.hits[0]._id'
```

## Enrichissement attendu
- explain : phase reconnaissance, MITRE T1046
- 3/3 validated=true
EOF
```

```bash
cat > ~/soc-ai-lab/data/samples/scenarios/S3.md << 'EOF'
# S3 — Modification fichier système (FIM)

**Objectif** : détecter une altération de /etc/passwd (Wazuh syscheck).

**Cible** : vm-endp1 (10.110.188.114)

## Simulation (ajoute puis retire un utilisateur factice — réversible)
```bash
ssh root@10.110.188.114 'echo "fimtest:x:9999:9999::/tmp:/usr/sbin/nologin" >> /etc/passwd; sleep 1; sed -i "/^fimtest:/d" /etc/passwd'
```

## Détection attendue
- Wazuh syscheck : rule_id 550 (intégrité modifiée)
- Prérequis : FIM temps réel sur /etc

## Vérification ES
```bash
curl -sk --cacert ~/soc-ai-lab/certs/ca.crt -u elastic:'SocSiem2024!' \
  "https://10.110.188.110:9200/wazuh-alerts-*/_search" -H 'Content-Type: application/json' \
  -d '{"size":1,"query":{"bool":{"must":[{"terms":{"wazuh.rule_id":["550","553","554"]}}],"filter":[{"range":{"@timestamp":{"gte":"now-3m"}}}]}},"sort":[{"@timestamp":{"order":"desc"}}]}' | jq '.hits.hits[0]._id'
```

## Enrichissement attendu
- explain : phase persistence/privilege_escalation, MITRE T1098
- 3/3 validated=true
EOF
```

```bash
cat > ~/soc-ai-lab/data/samples/scenarios/S4.md << 'EOF'
# S4 — ICMP flood

**Objectif** : détecter un flood ICMP (Suricata 9000003).

**Cible** : vm-endp1 (10.110.188.114)
**Attaquant** : vm-ai

## Simulation
```bash
sudo ping -f -c 200 10.110.188.114 || true
```

## Détection attendue
- Suricata : sid 9000003 (≥50 echo en 5s)

## Vérification ES
```bash
curl -sk --cacert ~/soc-ai-lab/certs/ca.crt -u elastic:'SocSiem2024!' \
  "https://10.110.188.110:9200/suricata-eve-*/_search" -H 'Content-Type: application/json' \
  -d '{"size":1,"query":{"bool":{"must":[{"term":{"event_type":"alert"}},{"term":{"alert.signature_id":9000003}}],"filter":[{"range":{"@timestamp":{"gte":"now-3m"}}}]}},"sort":[{"@timestamp":{"order":"desc"}}]}' | jq '.hits.hits[0]._id'
```

## Enrichissement attendu
- explain : phase impact, MITRE T1498
- 3/3 validated=true
EOF
```

```bash
cat > ~/soc-ai-lab/data/samples/scenarios/S5.md << 'EOF'
# S5 — User-Agent suspect

**Objectif** : détecter un UA malveillant en clair (Suricata 9000004).

**Cible** : service HTTP visible par Suricata (vm-endp1:80 ou équivalent)
**Attaquant** : vm-ai

## Simulation
```bash
curl -s -A "EvilScanner/1.0" http://10.110.188.114/ -m 5 || true
```

## Détection attendue
- Suricata : sid 9000004 (UA contient EvilScanner)
- Prérequis : trafic HTTP (port 80) traversant l'interface surveillée

## Vérification ES
```bash
curl -sk --cacert ~/soc-ai-lab/certs/ca.crt -u elastic:'SocSiem2024!' \
  "https://10.110.188.110:9200/suricata-eve-*/_search" -H 'Content-Type: application/json' \
  -d '{"size":1,"query":{"bool":{"must":[{"term":{"event_type":"alert"}},{"term":{"alert.signature_id":9000004}}],"filter":[{"range":{"@timestamp":{"gte":"now-3m"}}}]}},"sort":[{"@timestamp":{"order":"desc"}}]}' | jq '.hits.hits[0]._id'
```

## Enrichissement attendu
- explain : phase command_and_control/reconnaissance, MITRE T1071.001
- 3/3 validated=true
EOF
```

---

## 3. `scripts/tests/e2e_run_scenario.sh`

```bash
cat > ~/soc-ai-lab/scripts/tests/e2e_run_scenario.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

ES_HOST="https://10.110.188.110:9200"
ES_USER="elastic"
ES_PASS="SocSiem2024!"
CA="$HOME/soc-ai-lab/certs/ca.crt"
API="http://localhost:8000"
ENDPOINT="10.110.188.114"
POLL_INTERVAL=5
POLL_TIMEOUT=60

SCENARIO="${1:-}"
[ -z "$SCENARIO" ] && { echo "Usage: $0 <S1|S2|S3|S4|S5>" >&2; exit 2; }

es_query() {
  curl -sk --cacert "$CA" -u "$ES_USER:$ES_PASS" \
    "$ES_HOST/$1/_search" -H 'Content-Type: application/json' -d "$2"
}

enrich() { curl -s -X POST "$API/enrich/$1/$2"; }

poll_alert() {
  local index="$1" query="$2" elapsed=0 resp hits id
  while [ "$elapsed" -lt "$POLL_TIMEOUT" ]; do
    resp=$(es_query "$index" "$query")
    hits=$(echo "$resp" | jq -r '.hits.total.value // 0')
    if [ "$hits" -gt 0 ]; then
      echo "$resp" | jq -r '.hits.hits[0]._id'
      return 0
    fi
    sleep "$POLL_INTERVAL"
    elapsed=$((elapsed + POLL_INTERVAL))
  done
  return 1
}

TIME_FILTER='{"range":{"@timestamp":{"gte":"now-3m"}}}'
case "$SCENARIO" in
  S1)
    DESC="SSH brute force"
    SIM_CMD="hydra -l root -P /tmp/wordlist.txt -t 4 -f ssh://$ENDPOINT"
    INDEX="wazuh-alerts-*"
    QUERY='{"size":1,"query":{"bool":{"must":[{"terms":{"wazuh.rule_id":["5763","5712","5710","5716"]}}],"filter":['"$TIME_FILTER"']}},"sort":[{"@timestamp":{"order":"desc"}}]}'
    ;;
  S2)
    DESC="Port scan"
    SIM_CMD="sudo nmap -sS -p 1-1000 -T4 $ENDPOINT"
    INDEX="suricata-eve-*"
    QUERY='{"size":1,"query":{"bool":{"must":[{"term":{"event_type":"alert"}},{"term":{"alert.signature_id":9000002}}],"filter":['"$TIME_FILTER"']}},"sort":[{"@timestamp":{"order":"desc"}}]}'
    ;;
  S3)
    DESC="FIM /etc/passwd"
    SIM_CMD="ssh root@$ENDPOINT 'echo \"fimtest:x:9999:9999::/tmp:/usr/sbin/nologin\" >> /etc/passwd; sleep 1; sed -i \"/^fimtest:/d\" /etc/passwd'"
    INDEX="wazuh-alerts-*"
    QUERY='{"size":1,"query":{"bool":{"must":[{"terms":{"wazuh.rule_id":["550","553","554"]}}],"filter":['"$TIME_FILTER"']}},"sort":[{"@timestamp":{"order":"desc"}}]}'
    ;;
  S4)
    DESC="ICMP flood"
    SIM_CMD="sudo ping -f -c 200 $ENDPOINT"
    INDEX="suricata-eve-*"
    QUERY='{"size":1,"query":{"bool":{"must":[{"term":{"event_type":"alert"}},{"term":{"alert.signature_id":9000003}}],"filter":['"$TIME_FILTER"']}},"sort":[{"@timestamp":{"order":"desc"}}]}'
    ;;
  S5)
    DESC="Suspicious User-Agent"
    SIM_CMD="curl -s -A 'EvilScanner/1.0' http://$ENDPOINT/ -m 5"
    INDEX="suricata-eve-*"
    QUERY='{"size":1,"query":{"bool":{"must":[{"term":{"event_type":"alert"}},{"term":{"alert.signature_id":9000004}}],"filter":['"$TIME_FILTER"']}},"sort":[{"@timestamp":{"order":"desc"}}]}'
    ;;
  *) echo "Unknown scenario: $SCENARIO" >&2; exit 2 ;;
esac

echo "[*] $SCENARIO — $DESC" >&2
echo "[*] Simulation..." >&2
eval "$SIM_CMD" >/dev/null 2>&1 || true

echo "[*] Polling ES (max ${POLL_TIMEOUT}s)..." >&2
if ! ALERT_ID=$(poll_alert "$INDEX" "$QUERY"); then
  echo "[FAIL] $SCENARIO: aucune alerte détectée" >&2
  jq -nc --arg s "$SCENARIO" '{scenario:$s, alert_id:null, validated_count:0, error:"no_alert_detected"}'
  exit 1
fi
echo "[*] Alerte: $ALERT_ID" >&2

EX=$(enrich "$ALERT_ID" explain)
EX_VALID=$(echo "$EX" | jq -r '.validated // false')
EX_LEN=$(echo "$EX" | jq -r '(.response.summary // "") | length')
EX_LAT=$(echo "$EX" | jq -r '.latency_ms // 0')
EX_ID=$(echo "$EX" | jq -r '.enrichment_id // ""')

IN=$(enrich "$ALERT_ID" investigate)
IN_VALID=$(echo "$IN" | jq -r '.validated // false')
IN_LAT=$(echo "$IN" | jq -r '.latency_ms // 0')
IN_ID=$(echo "$IN" | jq -r '.enrichment_id // ""')

RE=$(enrich "$ALERT_ID" remediate)
RE_VALID=$(echo "$RE" | jq -r '.validated // false')
RE_LAT=$(echo "$RE" | jq -r '.latency_ms // 0')
RE_ID=$(echo "$RE" | jq -r '.enrichment_id // ""')

VC=0
[ "$EX_VALID" = "true" ] && VC=$((VC+1))
[ "$IN_VALID" = "true" ] && VC=$((VC+1))
[ "$RE_VALID" = "true" ] && VC=$((VC+1))

jq -nc \
  --arg scenario "$SCENARIO" --arg alert_id "$ALERT_ID" \
  --arg ex_id "$EX_ID" --arg in_id "$IN_ID" --arg re_id "$RE_ID" \
  --argjson ex_lat "$EX_LAT" --argjson in_lat "$IN_LAT" --argjson re_lat "$RE_LAT" \
  --argjson vc "$VC" --argjson ex_len "$EX_LEN" \
  '{scenario:$scenario, alert_id:$alert_id,
    enrichment_ids:{explain:$ex_id, investigate:$in_id, remediate:$re_id},
    latencies_ms:{explain:$ex_lat, investigate:$in_lat, remediate:$re_lat},
    validated_count:$vc, explain_summary_len:$ex_len}'

if [ "$VC" -eq 3 ] && [ "$EX_LEN" -ge 50 ]; then exit 0; else exit 1; fi
EOF
chmod +x ~/soc-ai-lab/scripts/tests/e2e_run_scenario.sh
```

---

## 4. `scripts/tests/e2e_full.sh`

```bash
cat > ~/soc-ai-lab/scripts/tests/e2e_full.sh << 'EOF'
#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS=()
PASS=0
FAIL=0
START=$(date +%s)

for S in S1 S2 S3 S4 S5; do
  echo "==================== $S ===================="
  OUT=$("$SCRIPT_DIR/e2e_run_scenario.sh" "$S" 2>&1)
  RC=$?
  echo "$OUT"
  JSON=$(echo "$OUT" | grep -E '^\{' | tail -1 || echo '{}')
  RESULTS+=("$JSON")
  if [ "$RC" -eq 0 ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi
done

END=$(date +%s); DUR=$((END-START))

echo ""
echo "==================== SUMMARY ===================="
printf '%s\n' "${RESULTS[@]}" | jq -s '
  (map(.latencies_ms.explain?, .latencies_ms.investigate?, .latencies_ms.remediate?)
    | map(select(. != null and . > 0)) | sort) as $lat
  | {
      scenarios: length,
      total_validated: (map(.validated_count // 0) | add),
      max_possible: (length * 3),
      latency_count: ($lat | length),
      latency_min_ms: ($lat | min),
      latency_mean_ms: (if ($lat|length)>0 then (($lat|add)/($lat|length)|floor) else 0 end),
      latency_max_ms: ($lat | max),
      latency_p95_ms: (if ($lat|length)>0 then $lat[(((($lat|length)|tonumber)*0.95)|ceil)-1] else 0 end),
      latencies_sorted_ms: $lat
    }'

echo ""
echo "Scenarios OK: $PASS / 5   |   KO: $FAIL"
echo "Durée totale: ${DUR}s ($((DUR/60))m$((DUR%60))s)"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
EOF
chmod +x ~/soc-ai-lab/scripts/tests/e2e_full.sh
```

---

## 5. `docs/demo_script.md`

```bash
cat > ~/soc-ai-lab/docs/demo_script.md << 'EOF'
# Déroulé de soutenance — 10 minutes

## 0:00–2:00 · Architecture (2 min)
- Problème : un SOC génère un volume d'alertes que l'analyste L1 doit trier manuellement. Le coût n'est pas la détection mais la **compréhension** et la **décision**.
- Solution : une couche d'enrichissement IA **post-détection**, sans toucher au pipeline existant.
- Trois couches séparées :
  1. **Détection** : Wazuh (HIDS/FIM) + Suricata (NIDS) → Elasticsearch.
  2. **Enrichissement** : FastAPI corrèle le contexte (±15 min), score le risque, interroge **Qwen3 14B local (Ollama)**, valide la sortie contre un schéma JSON, persiste.
  3. **Restitution** : UI web (liste d'incidents, détail, 3 actions IA).
- Choix Qwen3 14B local : souveraineté des données (aucune fuite vers un cloud), coût nul, latence acceptable sur CPU (~60–90s). Sorties contraintes par grammaire → JSON toujours conforme.

## 2:00–3:00 · Attaque live (1 min)
```bash
hydra -l root -P /tmp/wordlist.txt -t 4 -f ssh://10.110.188.114
```
Annoncer : « Je simule une force brute SSH contre l'endpoint. Wazuh va détecter les tentatives. »

## 3:00–5:00 · Alerte détectée (2 min)
- Kibana : ouvrir `wazuh-alerts-*`, montrer les rule_id 5710/5712/5763 qui apparaissent.
- UI : `http://10.110.188.66:8000/` → l'incident remonte en tête, badge de catégorie, score de risque, occurrences.
- Cliquer l'incident → page détail : alerte source + contexte corrélé.

## 5:00–7:00 · Enrichissement IA (2 min)
- Onglet **Explication** → Générer. Spinner ~60–90s. Lire à voix haute le `summary` généré : résumé en français, phase d'attaque, techniques MITRE.
- Onglet **Investigation** → 1 à 3 requêtes KQL prêtes à copier dans Kibana.
- Onglet **Remédiation** → action recommandée (`block_source_ip`), justification, niveau de confiance.

## 7:00–8:30 · Cache & score (1 min 30)
- Re-cliquer/recharger l'incident : les onglets se rechargent **instantanément** (cache dédup + persistance ES). Souligner l'économie de calcul LLM.
- Expliquer le score de risque : combinaison sévérité (0.4) + occurrences log (0.3) + récence (0.2) + bonus MITRE (0.1).

## 8:30–10:00 · Résultats d'évaluation (1 min 30)
- Protocole : 15 alertes, 2 analystes, mesure du temps de compréhension avec/sans enrichissement, double ordre.
- Annoncer le gain relatif moyen (%) et la significativité (Wilcoxon, p < 0.10).
- Montrer 1 exemple où l'enrichissement a directement orienté la décision.
- Conclure : la valeur n'est pas la détection (déjà couverte) mais la **réduction du temps de triage** et la **standardisation de la décision**.

## Plan B (si le LLM est lent ou une VM tombe)
- Avoir 3 incidents **déjà enrichis** la veille : ouvrir directement, les onglets se chargent depuis ES sans appel LLM.
- Captures d'écran de secours dans `docs/screenshots/`.
EOF
```

---

## 6. `docs/evaluation.md`

```bash
cat > ~/soc-ai-lab/docs/evaluation.md << 'EOF'
# Protocole d'évaluation

## Objectif
Mesurer si l'enrichissement IA réduit le temps de compréhension d'une alerte et améliore la qualité perçue de la décision.

## Hypothèses
- **H1** : le temps de compréhension *avec* enrichissement est inférieur au temps *sans*.
- **H0** : aucune différence de temps entre les deux conditions.
- Test apparié (les mêmes alertes sont vues dans les deux conditions) → **test de Wilcoxon signé**.

## Méthode
- **15 alertes** représentatives : 5 par catégorie de gravité (low/medium/high — ou critical), mix Wazuh/Suricata.
- **2 analystes** familiers du SOC.
- **2 conditions** : SANS enrichissement (alerte brute Kibana) / AVEC enrichissement (UI + sortie IA).
- **Double ordre (contrebalancement)** : l'analyste A traite la moitié des alertes SANS puis AVEC, l'autre moitié AVEC puis SANS ; l'analyste B fait l'inverse. Neutralise l'effet d'apprentissage.
- **Mesures par alerte** :
  - temps de compréhension en **secondes** (chronomètre, de l'affichage à l'énoncé de l'hypothèse d'attaque + action proposée) ;
  - **score d'auto-évaluation /5** de la confiance dans la compréhension.

## Tableau des 15 alertes (à remplir)
| # | Index | rule_id / sid | Catégorie | Scénario |
|---|-------|---------------|-----------|----------|
| 1 | wazuh | 5763 | high | S1 |
| 2 | suricata | 9000002 | medium | S2 |
| 3 | wazuh | 550 | high | S3 |
| 4 | suricata | 9000003 | medium | S4 |
| 5 | suricata | 9000004 | low | S5 |
| 6 | | | | |
| … | | | | |
| 15 | | | | |

## Tableau de mesures (à remplir)
| Analyste | Alerte # | Condition | Ordre | Temps (s) | Score /5 |
|----------|----------|-----------|-------|-----------|----------|
| A | 1 | SANS | 1 | | |
| A | 1 | AVEC | 2 | | |
| … | | | | | |

## Traitement statistique
Par condition : moyenne, médiane, écart-type. Puis :
- **Gain relatif (%)** = (temps_SANS − temps_AVEC) / temps_SANS × 100.
- **Intervalle de confiance 90%** de la différence moyenne.
- **Test de Wilcoxon signé** (paires SANS/AVEC). Rejet de H0 si p < 0.10.

### Script de calcul
```python
# docs/evaluation_stats.py
import numpy as np
from scipy import stats

# Coller les paires (temps_sans, temps_avec) en secondes
pairs = [
    # (sans, avec),
]
sans = np.array([p[0] for p in pairs], dtype=float)
avec = np.array([p[1] for p in pairs], dtype=float)
diff = sans - avec

print(f"n paires           : {len(pairs)}")
print(f"Moyenne SANS / AVEC: {sans.mean():.1f}s / {avec.mean():.1f}s")
print(f"Médiane SANS / AVEC: {np.median(sans):.1f}s / {np.median(avec):.1f}s")
print(f"Écart-type SANS/AVEC: {sans.std(ddof=1):.1f} / {avec.std(ddof=1):.1f}")
print(f"Gain relatif moyen : {(diff.mean()/sans.mean())*100:.1f}%")

# IC 90% de la différence moyenne
se = diff.std(ddof=1) / np.sqrt(len(diff))
t = stats.t.ppf(0.95, len(diff)-1)
print(f"IC90% diff moyenne : [{diff.mean()-t*se:.1f}, {diff.mean()+t*se:.1f}]s")

# Wilcoxon
w, p = stats.wilcoxon(sans, avec)
print(f"Wilcoxon W={w:.1f}, p={p:.4f} -> {'H0 rejetée' if p<0.10 else 'H0 non rejetée'}")
```

## Résultats (à compléter dans le rapport PFA)
| Métrique | SANS | AVEC | Gain |
|----------|------|------|------|
| Temps moyen (s) | | | |
| Temps médian (s) | | | |
| Score moyen /5 | | | |
| p (Wilcoxon) | — | — | |
EOF
```

---

## 7. Exécution + validation

```bash
# Un scénario isolé
~/soc-ai-lab/scripts/tests/e2e_run_scenario.sh S1

# Suite complète
~/soc-ai-lab/scripts/tests/e2e_full.sh
```

| Critère Étape 11 | Cible |
|---|---|
| `e2e_full.sh` termine sans erreur | exit 0 |
| Durée totale | < 15 min |
| Enrichissements validés | 15/15 (ou écart documenté) |
| Latence P95 | < 90 000 ms |
| Chaque scénario : détecté → enrichi → persisté → visible UI | 5/5 |
| `demo_script.md` couvre 2+6+2 min | ✓ |
| `evaluation.md` : protocole + tableaux + Wilcoxon | ✓ |

---

**Lance `e2e_full.sh` et donne-moi le bloc SUMMARY** (total_validated, latency_p95_ms, durée, PASS/KO). Trois cas :

1. **5/5 PASS, P95 < 90s** → MVP bouclé, étape 11 validée, projet complet.
2. **Scénarios Suricata KO (S2/S4/S5)** → règles locales non chargées ou trafic non vu par la sonde. Vérifie `sudo suricata -T` + que `local.rules` est dans `rule-files:` de `suricata.yaml`, et que la sonde voit le trafic vm-ai→endpoint.
3. **S3 timeout** → FIM pas en temps réel. Documente l'écart ou active `realtime="yes"` sur `/etc`.

Reporte le résultat et on traite les écarts un par un. Une fois `e2e_full.sh` vert, tu as les 11 étapes terminées et tout le matériel de soutenance.