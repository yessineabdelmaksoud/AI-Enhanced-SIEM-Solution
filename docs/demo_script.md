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
