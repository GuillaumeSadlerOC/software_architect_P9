# Orion MicroCRM

> Application full-stack de gestion de contacts et d'organisations, livrée avec
> une chaîne CI/CD industrialisée conforme aux standards DevSecOps.

[![CI — Backend](https://github.com/GuillaumeSadlerOC/software_architect_P9/actions/workflows/ci-backend.yml/badge.svg)](https://github.com/GuillaumeSadlerOC/software_architect_P9/actions/workflows/ci-backend.yml)
[![CI — Frontend](https://github.com/GuillaumeSadlerOC/software_architect_P9/actions/workflows/ci-frontend.yml/badge.svg)](https://github.com/GuillaumeSadlerOC/software_architect_P9/actions/workflows/ci-frontend.yml)
[![Security](https://github.com/GuillaumeSadlerOC/software_architect_P9/actions/workflows/security.yml/badge.svg)](https://github.com/GuillaumeSadlerOC/software_architect_P9/actions/workflows/security.yml)
[![Docker Build](https://github.com/GuillaumeSadlerOC/software_architect_P9/actions/workflows/docker-build.yml/badge.svg)](https://github.com/GuillaumeSadlerOC/software_architect_P9/actions/workflows/docker-build.yml)
[![Documentation](https://github.com/GuillaumeSadlerOC/software_architect_P9/actions/workflows/docs.yml/badge.svg)](https://github.com/GuillaumeSadlerOC/software_architect_P9/actions/workflows/docs.yml)

Ce dépôt est la livraison du **Projet 9 du parcours Architecte Logiciel d'OpenClassrooms** (option B — Scénario Orion). 
Il démontre l'industrialisation d'une chaîne d'intégration et de déploiement continu sur une application Spring Boot + Angular existante, sans modification du code applicatif.

## Table des matières

- [Stack technique](#stack-technique)
- [Architecture](#architecture)
- [Démarrage rapide](#démarrage-rapide)
- [Modes d'exécution](#modes-dexécution)
- [Observabilité — stack ELK](#observabilité--stack-elk)
- [Sauvegarde et restauration](#sauvegarde-et-restauration)
- [Pipeline CI/CD](#pipeline-cicd)
- [Vérification cryptographique des images](#vérification-cryptographique-des-images)
- [Documentation complète](#documentation-complète)
- [Licence](#licence)

## Stack technique

| Composant | Technologie | Version |
|-----------|-------------|---------|
| Back-end | Spring Boot / Java Temurin | 3.2.5 / 17 |
| Front-end | Angular / Node.js | 17.3 / 20 |
| Base de données (prod) | PostgreSQL | 16.4-alpine |
| Serveur statique | Nginx (unprivileged) | 1.27-alpine |
| Reverse proxy | Traefik | v3.6 |
| Orchestration locale | Docker Compose | v2.24+ |
| CI/CD | GitHub Actions | — |
| Qualité de code | SonarCloud | — |
| Sécurité | Trivy, Gitleaks, OWASP Dependency-Check, Checkov | — |
| Signature supply chain | Sigstore cosign (keyless OIDC) | v3 |
| Observabilité | Elastic Stack | 8.15 |

## Architecture

Déploiement local avec Docker Compose, trois réseaux segmentés :

```
                  ┌──────────────────────────────────────┐
                  │             Internet/Hôte            │
                  └─────────────────┬────────────────────┘
                                    │ :80/:443
                              ┌─────▼──────┐
                              │  Traefik   │  (edge-net)
                              │ (reverse   │
                              │  proxy)    │
                              └─────┬──────┘
                                    │
                      ┌─────────────┴─────────────┐
                      │                           │
                ┌─────▼──────┐              ┌─────▼──────┐
                │   Front    │              │    Back    │
                │ (Nginx +   │              │ (Spring    │
                │  Angular)  │──────────────│  Boot)     │ (app-net)
                │ unprivil.  │  REST calls  │ non-root   │
                │ read-only  │              │            │
                └────────────┘              └─────┬──────┘
                                                  │
                                            ┌─────▼──────┐
                                            │ PostgreSQL │  (db-net,
                                            │            │   internal: true)
                                            └────────────┘
```

Principaux durcissements :

- Utilisateurs non-root dans tous les conteneurs (uid 1001 back, uid 101 front).
- `security_opt: no-new-privileges` sur chaque service.
- Filesystem read-only sur le front, avec tmpfs pour les répertoires d'écriture nécessaires à Nginx.
- Réseau `db-net` déclaré `internal: true` — la base PostgreSQL ne peut ni émettre vers Internet ni être atteinte depuis l'hôte.

## Démarrage rapide

Prérequis : Docker 24+ et Docker Compose v2.24+.

```bash
git clone https://github.com/GuillaumeSadlerOC/software_architect_P9.git
cd software_architect_P9

# Copier le fichier d'exemple et le personnaliser
cp .env.example .env
# Éditer .env pour remplacer DB_PASSWORD au moins

# Lancer la stack en mode dev (HSQLDB en mémoire, build rapide)
docker compose up -d

# Accès
# Front       : http://localhost:8000
# Back        : http://localhost:8080
# Traefik UI  : http://localhost:8090
```

## Modes d'exécution

Trois fichiers Compose sont fournis. Ils se combinent selon le mode voulu :

| Mode | Commande | Base de données | TLS |
|------|----------|-----------------|-----|
| Dev | `docker compose up -d` | HSQLDB in-memory | non |
| Prod-like | `docker compose -f docker-compose.yml up -d` | PostgreSQL 16 | non |
| Prod réel | `docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d` | PostgreSQL 16 | Let's Encrypt ACME |

Le mode prod réel suppose la présence d'un domaine public et des variables `DOMAIN` et `ACME_EMAIL` dans `.env`.

Pour tout arrêter :

```bash
docker compose down          # conserve les volumes (données persistées)
docker compose down -v       # efface également les volumes
```

## Observabilité — stack ELK

Une stack Elastic (Elasticsearch + Logstash + Kibana + Filebeat) est fournie séparément pour la centralisation des logs applicatifs.

```bash
# Démarrer la stack ELK en parallèle de l'application
docker compose -f docker-compose-elk.yml up -d

# Accès
# Kibana         : http://localhost:5601
# Elasticsearch  : http://localhost:9200
```

Le back-end émet ses logs au format **ECS JSON** (Elastic Common Schema) en mode prod. Logstash parse les logs, promeut les champs utiles (`log_level`, `logger_name`, `service_name`) et indexe dans un index journalier `orion-microcrm-YYYY.MM.DD`.

Dans Kibana, créer un data view sur le pattern `orion-microcrm-*` puis filtrer sur `service_name: orion-microcrm-back` pour ne voir que les logs applicatifs. Un dashboard exemple avec répartition des niveaux, volume temporel et top loggers peut être importé depuis la documentation technique.

## Sauvegarde et restauration

Deux scripts opérationnels sont fournis pour la base PostgreSQL en production :

```bash
# Sauvegarde (format custom pg_dump -Fc, horodatée, rotation 7 jours)
./scripts/backup-db.sh

# Restauration avec smoke-test /actuator/health
./scripts/restore-db.sh ./backups/microcrm-YYYYMMDD-HHMMSS.dump
```

Le script de restauration arrête le back, recrée la base, charge le dump via `pg_restore`, redémarre le back et vérifie que l'endpoint santé répond UP avant de sortir. Il sort en erreur si la chaîne DB → back → HTTP n'est pas opérationnelle.

## Pipeline CI/CD

Cinq workflows GitHub Actions composent le pipeline :

| Workflow | Déclencheur | Rôle |
|----------|-------------|------|
| `ci-backend.yml` | push, PR sur `back/**` | build Gradle, JUnit, JaCoCo, scan SonarCloud |
| `ci-frontend.yml` | push, PR sur `front/**` | npm ci, Karma headless, coverage LCOV, scan SonarCloud |
| `security.yml` | push, PR, schedule | Trivy FS + image, Gitleaks, OWASP Dependency-Check, Checkov |
| `docker-build.yml` | push main, tags `v*.*.*`, après succès CI | build multi-arch, push GHCR, SBOM, cosign keyless |
| `nightly.yml` | cron 02:30 UTC | ré-exécution CI + Security + rapport de dérive des dépendances |
| `docs.yml` | push sur `docs/**` | conversion Markdown → PDF via Pandoc + XeLaTeX |

Les workflows sensibles (Trivy notamment, suite à la campagne de compromission de mars 2026) sont épinglés par **commit SHA** plutôt que par tag, pour garantir l'immutabilité des actions utilisées.

La publication d'une image sur GHCR **dépend mathématiquement** du succès des CI via le mécanisme `workflow_call` : il est impossible de publier une image issue d'un code qui n'a pas passé ses tests et son quality gate SonarCloud.

## Vérification cryptographique des images

Les images publiées sur GHCR sont signées en mode **keyless OIDC** par Sigstore cosign. Aucune clé privée n'est stockée : chaque run obtient un certificat éphémère (10 minutes) de l'autorité Fulcio, signe l'image avec, publie la signature sur le transparency log Rekor, puis détruit la clé éphémère.

N'importe qui peut vérifier qu'une image a bien été produite par ce dépôt :

```bash
# Installer cosign (Linux/macOS)
curl -L https://github.com/sigstore/cosign/releases/latest/download/cosign-linux-amd64 -o cosign
chmod +x cosign

# Vérifier la signature d'une image
./cosign verify ghcr.io/guillaumesadleroc/orion-microcrm-back:latest \
  --certificate-identity-regexp 'https://github.com/GuillaumeSadlerOC/software_architect_P9/.*' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

La commande affiche le certificat Fulcio, l'URL du workflow GitHub qui a produit l'image, et confirme que la signature est enregistrée dans Rekor.

## Documentation complète

La documentation technique du projet est maintenue dans `docs/documentation.md`. Un workflow `docs.yml` la convertit automatiquement en PDF à chaque modification via Pandoc + XeLaTeX.

Pour générer le PDF localement :

```bash
docker run --rm -v "$PWD":/data pandoc/latex:3.5 \
  docs/documentation.md \
  --output=dist/documentation.pdf \
  --pdf-engine=xelatex \
  --toc \
  --number-sections \
  --highlight-style=tango \
  -V linkcolor=NavyBlue \
  -V urlcolor=NavyBlue \
  -V geometry:margin=2.5cm
```

Le PDF généré en CI est également disponible :

- En tant qu'**artifact de workflow run** (rétention 90 jours)
- En tant que **release asset** sur les tags sémantiques

## Licence

Ce projet est dérivé du template open source MicroCRM fourni par OpenClassrooms dans le cadre du projet d'évaluation du parcours Architecte Logiciel. Licence d'origine conservée.