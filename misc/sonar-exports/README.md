# SonarCloud issue exports

Snapshot des findings remontés par SonarCloud sur les projets
`guillaumesadleroc_orion-microcrm-back` et
`guillaumesadleroc_orion-microcrm-front` au 22 avril 2026.

Ces exports JSON sont les **sources chiffrées** de la section 5 (Plan de
sécurité) de la documentation technique (`docs/documentation.md`). Les
chiffres cités dans la doc (5 issues back, 46 issues front, 1 security
hotspot, 104 minutes de dette) proviennent directement de ces fichiers.

## Fichiers

- `sonar-back-issues.json` — 5 code smells sur le projet Back
- `sonar-back-hotspots.json` — 0 security hotspot sur le projet Back
- `sonar-front-issues.json` — 46 issues sur le projet Front (effort 93 min)
- `sonar-front-hotspots.json` — 1 security hotspot sur le projet Front (SRI)

## Méthode de collecte

Récupérés via l'API publique SonarCloud. Les projets étant publics,
aucun token n'est nécessaire :

```bash
# Issues du back (limit 100, avec toutes les métadonnées utiles)
curl -s "https://sonarcloud.io/api/issues/search?componentKeys=guillaumesadleroc_orion-microcrm-back&ps=100&resolved=false" \
  | python3 -m json.tool > /tmp/sonar-back-issues.json

# Issues du front
curl -s "https://sonarcloud.io/api/issues/search?componentKeys=guillaumesadleroc_orion-microcrm-front&ps=100&resolved=false" \
  | python3 -m json.tool > /tmp/sonar-front-issues.json

# Security hotspots du back (endpoint séparé)
curl -s "https://sonarcloud.io/api/hotspots/search?projectKey=guillaumesadleroc_orion-microcrm-back&status=TO_REVIEW&ps=100" \
  | python3 -m json.tool > /tmp/sonar-back-hotspots.json

# Security hotspots du front
curl -s "https://sonarcloud.io/api/hotspots/search?projectKey=guillaumesadleroc_orion-microcrm-front&status=TO_REVIEW&ps=100" \
  | python3 -m json.tool > /tmp/sonar-front-hotspots.json
```

## Rôle dans l'audit

- **Traçabilité** : un jury peut vérifier que les chiffres de la doc
  correspondent bien à l'état réel de SonarCloud à la date de soumission.
- **Reproductibilité** : un audit ultérieur peut comparer un nouveau pull
  avec cette baseline pour mesurer l'évolution de la dette.
- **Transparence** : pratique typique des démarches DevSecOps matures, où
  les outputs bruts d'analyse sont archivés comme pièces justificatives.
