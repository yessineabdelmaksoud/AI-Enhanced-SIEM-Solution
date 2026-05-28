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
