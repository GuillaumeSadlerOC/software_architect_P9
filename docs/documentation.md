---
title: "Documentation technique — Orion MicroCRM"
subtitle: "Industrialisation du pipeline CI/CD d'une application full-stack"
author: "Guillaume Sadler"
option: "Option B — Scénario Orion"
date: \today
lang: fr
toc: true
toc-depth: 3
numbersections: true
geometry: margin=2.5cm
fontsize: 11pt
colorlinks: true
linkcolor: NavyBlue
urlcolor: NavyBlue
---

# Introduction

## Contexte du projet

Dans le cadre du scénario Orion, Maria m'a confié l'industrialisation du pipeline
CI/CD de **MicroCRM**, une application full-stack de gestion de contacts et
d'organisations. L'application existante se compose d'un back-end Spring Boot 3.2
(Java 17, Gradle) et d'un front-end Angular 17 (TypeScript, Karma), livrée dans
un monorepo GitHub avec des tests unitaires mais sans aucune automatisation :
builds manuels, aucune analyse de qualité, aucune signature d'artefacts,
aucun scan de vulnérabilités.

L'objectif de la mission est de **transformer ce dépôt en chaîne de livraison
industrialisée** conforme aux standards DevSecOps actuels, sans modifier le
code applicatif existant — ce qui permettra à SonarQube de détecter et de
documenter la dette technique héritée, matière première du plan de remédiation
présenté en section 5.

## Objectifs de l'industrialisation

| Objectif | Bénéfice attendu |
|----------|------------------|
| Automatiser la compilation et les tests back + front | Détection immédiate des régressions |
| Déclencher des analyses de qualité continues (SonarQube Cloud) | Visibilité sur la dette technique |
| Scanner vulnérabilités, secrets, CVE et misconfigurations | Defence-in-depth sécurité |
| Conteneuriser les services en images Docker minimales signées | Reproductibilité et traçabilité |
| Publier les artefacts signés sur GitHub Container Registry | Chaîne d'approvisionnement vérifiable |
| Centraliser les logs applicatifs dans une stack ELK locale | Observabilité et analyse d'incident |
| Mesurer la performance du pipeline via les métriques DORA | Pilotage continu par la donnée |

## Technologies principales

Le choix des technologies s'appuie sur les standards open source les plus
maintenus, avec une préférence systématique pour les versions stables récentes
et les distributions officielles.

- **Spring Boot 3.2.5 / Java 17 Temurin** — back-end, JVM LTS
- **Angular 17.3 / Node.js 20** — front-end, LTS
- **PostgreSQL 16.4-alpine** — base de données en production (HSQLDB en dev)
- **Nginx 1.27 (unprivileged)** — serveur statique du bundle front
- **Traefik v3.6** — reverse proxy avec auto-découverte Docker et TLS Let's Encrypt
- **Docker 29 / Docker Compose v2.24+** — conteneurisation et orchestration locale
- **GitHub Actions** — exécuteur du pipeline CI/CD
- **SonarQube Cloud** — analyse de qualité et sécurité SAST
- **Trivy / OWASP Dependency-Check / Gitleaks / Checkov** — scanners de sécurité complémentaires
- **Sigstore cosign** — signature keyless OIDC des artefacts
- **Elastic Stack 8.15** — centralisation des logs (Elasticsearch + Logstash + Kibana + Filebeat)

## Présentation rapide du pipeline CI/CD

Le pipeline mis en place comprend **cinq workflows GitHub Actions**, déclenchés
à des moments distincts pour offrir un feedback rapide aux développeurs sans
saturer la plateforme de runs inutiles.

1. **CI — Backend** (`ci-backend.yml`) : build Gradle, tests JUnit, couverture JaCoCo, analyse SonarQube. Déclenché sur push et PR touchant `back/**`.
2. **CI — Frontend** (`ci-frontend.yml`) : install npm, tests Karma headless, build de production, analyse SonarQube. Déclenché sur push et PR touchant `front/**`.
3. **Security** (`security.yml`) : Trivy filesystem + image, Gitleaks, OWASP Dependency-Check, Checkov IaC. Déclenché sur chaque push + exécution nocturne.
4. **Docker Build & Push** (`docker-build.yml`) : build multi-architecture, publication sur GHCR, génération SBOM SPDX, attestation de provenance SLSA, signature cosign keyless. Déclenché après succès des CI, sur push `main` et sur tags sémantiques.
5. **Nightly** (`nightly.yml`) : ré-exécution programmée des workflows CI + Security + rapport de dérive des dépendances. Déclenché chaque nuit à 02:30 UTC.

Cette séparation respecte le principe de moindre privilège (chaque workflow
déclare uniquement les permissions dont il a besoin) et fournit la granularité
nécessaire pour des métriques DORA exploitables.

\newpage

# Étapes de mise en œuvre du pipeline CI/CD

## Structure du pipeline

### Étapes principales et ordre d'exécution

Le pipeline est découpé en étapes clairement identifiables, chacune avec une
responsabilité unique. L'ordre d'exécution respecte la règle « **fail fast,
fail cheap** » : les étapes les plus rapides et les plus susceptibles d'échouer
sont placées en premier, de sorte qu'un développeur reçoive un feedback en
quelques secondes plutôt qu'en plusieurs minutes.

**Flux du workflow CI — Backend :**

```
checkout  →  setup JDK  →  setup Gradle + cache
              ↓
   build + tests + JaCoCo (1 commande Gradle)
              ↓
   upload artefacts (tests + coverage)
              ↓
   SonarCloud scan + quality gate wait
              ↓
   OK ou KO
```

**Flux du workflow CI — Frontend :**

```
checkout  →  setup Node.js 20 (cache npm intégré)
              ↓
   npm ci (install déterministe)
              ↓
   ng test (Karma headless + coverage LCOV)
              ↓
   upload coverage artifact
              ↓
   ng build production (smoke test build)
              ↓
   SonarCloud scan + quality gate wait
              ↓
   OK ou KO
```

**Flux du workflow Security :** cinq jobs parallèles indépendants — Trivy FS,
Gitleaks, OWASP Dependency-Check, Checkov, Trivy Image (matrice back+front).
Chacun remonte ses findings en SARIF vers l'onglet Security de GitHub,
catégorisés pour permettre le filtrage par outil.

**Flux du workflow Docker Build & Push :** ce workflow **dépend** du succès des
deux CI sur le même commit (via `workflow_call`), empêchant mathématiquement la
publication d'images construites sur du code non testé. Une fois cette gate
franchie, il exécute : build multi-arch → tag intelligent → push GHCR → SBOM →
provenance → cosign.

### Justification du choix des actions GitHub

Tous les composants externes sont sélectionnés selon trois critères : maintenance
active, documentation, sécurité. Les actions sensibles (scanners) sont **épinglées
par commit SHA** plutôt que par tag, suite à la campagne d'attaques
supply-chain de mars 2026 contre `aquasecurity/trivy-action` qui a démontré
qu'un tag peut être force-pushé vers un commit malveillant, alors qu'un SHA
est cryptographiquement immutable.

Table: Actions GitHub utilisées dans le pipeline, avec version et justification du choix.

+-----------------------------------+---------------------------------+-------------+----------------------------------------+
| Action                            | Rôle                            | Version     | Justification                          |
+===================================+=================================+=============+========================================+
| actions/checkout                  | Cloner le repo                  | v4          | Officielle GitHub, dernière majeure    |
+-----------------------------------+---------------------------------+-------------+----------------------------------------+
| actions/setup-java                | Installer JDK Temurin           | v4          | Officielle                             |
+-----------------------------------+---------------------------------+-------------+----------------------------------------+
| gradle/actions/setup-gradle       | Configurer Gradle + cache       | v4          | Officielle Gradle                      |
+-----------------------------------+---------------------------------+-------------+----------------------------------------+
| actions/setup-node                | Installer Node.js + cache npm   | v4          | Officielle                             |
+-----------------------------------+---------------------------------+-------------+----------------------------------------+
| SonarSource/sonarqube-scan-action | Scanner SonarCloud              | v6          | Officielle SonarSource,                |
|                                   |                                 |             | v5 dépréciée (CVE)                     |
+-----------------------------------+---------------------------------+-------------+----------------------------------------+
| aquasecurity/trivy-action         | Scanner vulnérabilités          | SHA du      | Seule version non compromise par       |
|                                   |                                 | tag v0.35.0 | l'attaque supply-chain de mars 2026    |
+-----------------------------------+---------------------------------+-------------+----------------------------------------+
| gitleaks/gitleaks-action          | Détection de secrets            | v2          | Maintenue, référence du domaine        |
+-----------------------------------+---------------------------------+-------------+----------------------------------------+
| dependency-check/                 | CVE Java vs NVD                 | main        | Officielle OWASP                       |
| Dependency-Check\_Action          |                                 |             |                                        |
+-----------------------------------+---------------------------------+-------------+----------------------------------------+
| bridgecrewio/checkov-action       | Misconfigurations IaC           | v12         | Officielle, standard du domaine        |
+-----------------------------------+---------------------------------+-------------+----------------------------------------+
| docker/build-push-action          | Build + push images             | v6          | Officielle Docker                      |
+-----------------------------------+---------------------------------+-------------+----------------------------------------+
| sigstore/cosign-installer         | Installer cosign                | v3          | Officielle Sigstore                    |
+-----------------------------------+---------------------------------+-------------+----------------------------------------+
| github/codeql-action/             | Remontée SARIF                  | v4          | Officielle GitHub, v3 dépréciée        |
| upload-sarif                      |                                 |             |                                        |
+-----------------------------------+---------------------------------+-------------+----------------------------------------+

## Scripts d'automatisation

### Scripts d'infrastructure (dans le repo)

Au-delà des workflows GitHub Actions, deux scripts shell ont été ajoutés pour
les opérations de reprise que GitHub ne peut pas orchestrer (actions locales
sur la base de données).

**`scripts/backup-db.sh`** — Sauvegarde de la base PostgreSQL en production.

Rôle : exécute `pg_dump` à l'intérieur du conteneur PostgreSQL (aucun outil
client requis côté hôte, la version du dump correspond toujours à celle du
serveur), écrit un fichier horodaté au format custom (`-Fc`, binaire
compressé) dans `./backups/`, puis purge les dumps de plus de 7 jours.

Exécution :

```bash
./scripts/backup-db.sh              # valeurs par défaut
BACKUP_DIR=/mnt/nas ./scripts/backup-db.sh    # override destination
```

**`scripts/restore-db.sh`** — Restauration de la base à partir d'un dump.

Rôle : stoppe le back-end (évite les écritures concurrentes), supprime et
recrée la base ciblée, charge le dump via `pg_restore`, redémarre le back, et
vérifie que l'endpoint `/actuator/health` répond `UP`. Le smoke-test final est
délibéré : un `pg_restore` peut retourner 0 tout en laissant la base dans un
état où le back ne peut pas se reconnecter (grants manquants, propriété
incorrecte, etc.). La chaîne complète DB → back → HTTP doit répondre.

Exécution :

```bash
./scripts/restore-db.sh ./backups/microcrm-20260421-020000.dump
FORCE=1 ./scripts/restore-db.sh ...           # pour automatisation (sans confirmation)
```

### Scripts applicatifs (intégrés aux workflows)

Le pipeline lui-même exécute les commandes standards des outils front et back,
sans wrapper custom :

| Action | Commande | Lieu de définition | Quand |
|--------|----------|--------------------|-------|
| Compiler + tester + coverage back | `./gradlew clean build jacocoTestReport` | `back/build.gradle` | CI back, nightly |
| Installer front déterministe | `npm ci --no-audit --no-fund` | workflow + `package-lock.json` | CI front, nightly |
| Tester front + coverage | `ng test --watch=false --browsers=ChromeHeadlessNoSandbox --code-coverage` | workflow + `angular.json` + `karma.conf.js` | CI front, nightly |
| Build prod front | `ng build --configuration production` | `angular.json` | CI front, docker-build |
| Build image back | `docker buildx build …` | `back/Dockerfile` | docker-build |
| Build image front | `docker buildx build …` | `front/Dockerfile` | docker-build |

Cette discipline — pas de script custom qui enrobe les outils — garantit que
chaque développeur peut **reproduire localement** l'intégralité du pipeline
avec les mêmes commandes, sans dépendre de GitHub Actions.

## Reproductibilité

### Comment relancer le pipeline

Le pipeline CI est entièrement déclaratif. Tout contributeur peut :

- **Déclencher un run CI** en poussant un commit sur une branche ou en
  ouvrant une pull request. Les workflows sélectionnent automatiquement ceux
  à lancer via les filtres `paths:` (un changement dans `back/**` ne déclenche
  que CI — Backend).
- **Déclencher manuellement** un workflow via l'onglet Actions → sélectionner
  le workflow → `Run workflow`. Tous nos workflows exposent `workflow_dispatch`
  pour cet usage.
- **Reproduire un run localement** en exécutant les commandes documentées dans
  la table ci-dessus, ce qui permet de diagnostiquer un échec sans re-push.

### Gestion des secrets

Aucun secret n'est stocké en clair dans le dépôt. Les variables sensibles sont
provisionnées dans `Settings → Secrets and variables → Actions` et injectées
dans les workflows via `${{ secrets.NOM }}`. Le fichier `.env.example` à la
racine du repo documente la liste des variables nécessaires, **sans valeurs**.

**Secrets utilisés :**

| Secret | Utilisation | Scope |
|--------|-------------|-------|
| `SONAR_TOKEN` | Scanner SonarCloud (User Token avec scope `Browse` + `Execute Analysis`) | CI back, CI front, nightly |
| `NVD_API_KEY` | OWASP Dependency-Check (lève le rate-limit NVD) | Security, nightly |
| `GITHUB_TOKEN` | Token natif GitHub (GHCR push, SARIF upload, OIDC) | tous |

**Principes appliqués :**

- Un secret révoqué/fuité peut être **rotaté en une minute** sans toucher au code.
- Le `GITHUB_TOKEN` suit strictement le **moindre privilège** : chaque workflow
  déclare ses `permissions:` (par exemple, `docker-build.yml` demande
  `packages: write` mais refuse `contents: write` — il ne peut pas modifier le
  repo même s'il est compromis).
- Le workflow `docker-build.yml` utilise **cosign en mode keyless OIDC** : aucune
  clé privée n'est stockée nulle part. Chaque run obtient un certificat
  éphémère (10 min) de l'autorité Fulcio, signe avec, publie la signature sur
  Rekor (transparency log), et détruit la clé. Il est mathématiquement
  impossible de voler cette clé puisqu'elle n'existe qu'en RAM, pendant 10
  minutes, dans un environnement éphémère.

\newpage

# Plan de conteneurisation et de déploiement

## Dockerfiles

Les deux composants applicatifs disposent de Dockerfiles dédiés, construits
selon les bonnes pratiques actuelles (multi-stage, utilisateur non-root,
images minimales officielles).

### `back/Dockerfile` — Spring Boot

Choix techniques principaux :

- **Image de base étage build** : `eclipse-temurin:17-jdk-jammy`
  Distribution officielle Adoptium (ex-AdoptOpenJDK), LTS 17, Ubuntu Jammy.
- **Image de base étage runtime** : `eclipse-temurin:17-jre-jammy`
  JRE seulement en runtime — ~40% plus petite que la JDK, surface d'attaque réduite.
- **Multi-stage** : le JAR est compilé dans l'étage build puis **copié** dans
  l'étage runtime. Le runtime final ne contient ni Gradle, ni sources, ni caches
  — uniquement le JAR et la JRE.
- **Utilisateur dédié non-root** : un user `spring` (uid/gid 1001) est créé et
  l'application tourne sous son identité. Empêche une éventuelle RCE d'obtenir
  des privilèges root dans le conteneur.
- **Init process `tini` en PID 1** : reap des processus zombies et propagation
  correcte des signaux (Spring ferme proprement sur SIGTERM, ce qui évite les
  connexions DB tronquées au rolling update).
- **HEALTHCHECK intégré** : appelle `/actuator/health` toutes les 30s. Docker
  Compose utilise ce healthcheck pour retarder le démarrage du front jusqu'à
  ce que le back soit réellement prêt (`depends_on: condition: service_healthy`).
- **OCI labels** : métadonnées `org.opencontainers.image.source`,
  `.revision`, `.version`, `.title`, `.licenses`. GHCR les affiche dans l'UI
  des packages, ce qui permet à n'importe qui de retrouver le commit Git exact
  qui a produit une image donnée.

### `front/Dockerfile` — Angular + Nginx

- **Étage build** : `node:20-alpine`. Node LTS, image Alpine minimale.
  Exécute `npm ci` puis `ng build --configuration production`.
- **Étage runtime** : `nginxinc/nginx-unprivileged:1.27-alpine`.
  Nginx officiel **en version non-privilégiée** (tourne sous user `nginx`
  uid 101, pas besoin de root pour bind sur les ports <1024). Empêche
  l'escalade de privilèges même si une CVE Nginx est découverte.
- **Configuration Nginx durcie** : voir `front/nginx.conf`. Inclut : `gzip` activé,
  cache long pour les assets hashés, fallback SPA vers `index.html`, et surtout
  une **Content-Security-Policy stricte** (`default-src 'self'`,
  `script-src 'self'`) qui bloque toute injection XSS.
- **Read-only filesystem** activé dans le compose (voir 3.2), avec trois
  `tmpfs:` pour les répertoires où Nginx a besoin d'écrire (`/var/cache/nginx`,
  `/var/run`, `/tmp`). Un attaquant qui obtient l'exécution de code ne peut
  pas modifier le contenu de l'image ni persister.

### Sécurité additionnelle (imposée dans `docker-compose.yml`)

- `security_opt: [no-new-privileges:true]` — désactive les bits `setuid` et
  empêche l'escalade par ce vecteur.
- Aucun port publié pour PostgreSQL (`ports:` absent) — la base n'est
  joignable **que** par le back, qui est lui-même sur le réseau `db-net`
  configuré en `internal: true`. La base ne peut donc ni recevoir de trafic
  depuis l'hôte, ni émettre de trafic vers Internet.
- Images scannées automatiquement par **Trivy** dans le workflow Security
  (voir section 5).

## `docker-compose.yml`

### Services définis

Le compose orchestre **quatre services** en mode prod, trois en mode dev.

| Service | Rôle | Exposition | Réseaux |
|---------|------|------------|---------|
| `traefik` | Reverse proxy, routage par labels | 80/443 | `edge-net` |
| `front` | Bundle Angular servi par Nginx | via Traefik uniquement | `edge-net` |
| `back` | API REST Spring Boot | `:8080` direct (dette documentée) | `app-net`, `db-net` |
| `postgres` | PostgreSQL 16 en mode prod uniquement | aucune (interne) | `db-net` (internal) |

### Segmentation réseau

Trois réseaux Docker isolent les flux :

- **`edge-net`** — Traefik  —  front. Seul réseau avec une sortie vers l'hôte.
- **`app-net`** — back. Séparé d'edge-net parce que le front ne parle pas
  directement au back (et, techniquement, parce que le front actuel tape
  `http://localhost:8080` en dur dans le navigateur — dette applicative
  documentée comme telle pour que SonarQube l'identifie).
- **`db-net`** — back  —  postgres, `internal: true`. **La base ne peut ni
  émettre vers Internet, ni être contactée depuis l'extérieur**, même si un
  opérateur se trompe dans les firewalls.

### Trois fichiers pour trois environnements

- **`docker-compose.yml`** — base commune à tous les environnements.
- **`docker-compose.override.yml`** — appliqué **automatiquement** par
  `docker compose up`. Contient la configuration **dev** : HSQLDB au lieu de
  PostgreSQL, Traefik en HTTP nu sur 8000, dashboard Traefik exposé sur 8090.
- **`docker-compose.prod.yml`** — appliqué **explicitement**. Ajoute TLS
  Let's Encrypt (résolveur ACME TLS-ALPN-01), limites de ressources CPU/RAM,
  profil Spring `prod` (force PostgreSQL).

### Commandes pour lancer l'application localement

```bash
# Dev (HSQLDB en mémoire, pas de base, démarre rapide)
docker compose up -d

# Prod-like (PostgreSQL + tous les durcissements)
docker compose -f docker-compose.yml up -d

# Prod réel (avec TLS Let's Encrypt — nécessite un DOMAIN valide)
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d

# Stopper et nettoyer
docker compose down                     # conserve les volumes
docker compose down -v                  # efface les données
```

\newpage

# Plan de testing périodique

## Types de tests automatisés

Le pipeline exécute automatiquement **cinq familles de tests**, chacune avec un
objectif distinct et un critère d'alerte propre.

### Tests unitaires back

- **Outil** : JUnit 5 (framework fourni par Spring Boot).
- **Périmètre** : tests existants dans `back/src/test/java/`.
- **Commande** : `./gradlew test`.
- **Couverture mesurée par** : JaCoCo → rapport XML fourni à SonarCloud.
- **Critère d'alerte** : tout test rouge bloque le pipeline.

### Tests unitaires front

- **Outil** : Karma + Jasmine (frameworks par défaut Angular CLI).
- **Exécuteur** : ChromeHeadlessNoSandbox (sandbox Chrome désactivé car indisponible dans les runners GitHub).
- **Commande** : `ng test --watch=false --code-coverage`.
- **Couverture mesurée par** : Karma coverage reporter → rapport LCOV fourni à SonarCloud.
- **Critère d'alerte** : tout test rouge bloque le pipeline.

### Analyse statique de qualité (SonarCloud)

- **Outil** : SonarCloud, projets séparés back et front en mode monorepo.
- **Périmètre** : 100 % des sources.
- **Règles appliquées** : profil "Sonar way" par défaut (standard de l'industrie), complété par les règles par défaut de Sonar pour Java et TypeScript.
- **Quality gate** : profil "Sonar way", qui évalue le **new code** (code ajouté/modifié dans la fenêtre de 30 jours). Un gate RED bloque le pipeline.
- **Métriques suivies** : bugs, vulnerabilities, security hotspots, code smells, couverture, duplications, complexité.

### Analyse de sécurité (workflow Security)

Composé de **cinq scanners complémentaires**, dont la redondance est volontaire
(chaque outil a ses propres sources de données et profils de faux positifs) :

| Scanner | Cible | Remonte |
|---------|-------|---------|
| Trivy FS | Sources + dépendances déclarées | CVE dans libs npm et Gradle |
| Trivy Image | Images construites (matrice back+front) | CVE dans couches OS (Ubuntu, Nginx, JRE) |
| Gitleaks | Historique git complet | Secrets commités (clés, tokens, passwords) |
| OWASP Dependency-Check | Dépendances Gradle | CVE croisées avec NVD (données indépendantes de Trivy) |
| Checkov | Dockerfiles, compose, workflows GitHub | Misconfigurations IaC |

Tous les findings sont centralisés dans l'onglet **Security** de GitHub, catégorisés par outil, avec historique et possibilité d'assignation.

### Scan périodique (Nightly)

- Ré-exécute la CI complète + le workflow Security chaque nuit à 02:30 UTC.
- Ajoute un rapport de **dérive des dépendances** (`npm outdated`, `gradle dependencies`).
- Objectif : détecter les CVE publiées dans la nuit (les bases de données NVD et Trivy DB sont mises à jour quotidiennement) et les nouvelles versions disponibles.

## Fréquence d'exécution

La cadence est calibrée pour offrir un feedback immédiat aux développeurs tout
en couvrant les risques passifs (CVE, dérive).

| Déclencheur | Workflows exécutés | Objectif |
|-------------|-------------------|----------|
| Push sur `main` ou `develop`, sur path `back/**` | CI — Backend, Security | Feedback rapide dev + scan complet |
| Push sur `main` ou `develop`, sur path `front/**` | CI — Frontend, Security | Idem côté front |
| Pull Request | CI concerné + Security | Bloquer les merges risqués |
| Push sur `main` | + Docker Build & Push (si CI verts) | Publication de l'image signée |
| Tag Git `v*.*.*` | Docker Build & Push (avec tag semver) | Release versionnée |
| Schedule 02:30 UTC | Nightly (CI × 2 + Security + drift) | Détection passive de dérive |
| Manuel (`workflow_dispatch`) | N'importe lequel | Debugging, replay |

## Objectifs des tests

Les tests servent trois objectifs distincts dans le cycle de vie :

**1. Qualité du code (pendant le dev)**
Le développeur reçoit un feedback en quelques minutes : ses tests passent-ils ?
SonarCloud voit-il son code comme acceptable ?

**2. Non-régression (avant merge)**
Aucun commit ne peut rejoindre `main` sans que l'intégralité des workflows soit
au vert — les pull requests sont protégées en ce sens (règle de branche à
activer côté GitHub).

**3. Vérification avant déploiement (avant publication)**
Le workflow `docker-build.yml` **dépend** de la réussite des CI via
`workflow_call`. Il est donc impossible de publier une image construite à partir
d'un code qui n'a pas passé ses tests. La gate est mathématique, pas
conventionnelle.

La fréquence **nightly** couvre un quatrième objectif : garantir qu'un dépôt
inactif ne devient pas silencieusement vulnérable (nouvelle CVE publiée, image
de base patchée, dépendance deprecated).

\newpage

# Plan de sécurité

Cette section synthétise l'état de sécurité du projet à la date de rédaction,
en agrégeant les findings de **trois sources complémentaires** : SonarCloud
(SAST), Trivy + OWASP Dependency-Check (supply chain / CVE), et l'analyse
architecturale (risques non détectés par les outils automatiques).

La complémentarité de ces trois sources est volontaire : chaque outil a son
angle mort. SonarCloud voit les défauts de code statique ; Trivy voit les CVE
dans les dépendances et images ; l'analyse humaine voit les choix de conception
(authentification manquante, CORS permissifs) qu'aucun SAST ne remonterait
sans configuration spécifique.

## Résultats SonarCloud

### Vue d'ensemble consolidée

Table: Indicateurs SonarCloud — projets Orion MicroCRM Back et Front au 21/04/2026.

| Projet    | Bugs | Vulnerabilities | Security Hotspots | Code Smells | Effort | Quality Gate |
|-----------|------|-----------------|-------------------|-------------|--------|--------------|
| Back      | 0    | 0               | 0                 | 5           | 11 min | PASSED       |
| Front     | 0    | 0               | 1                 | 46          | 93 min | PASSED       |
| **Total** | 0    | 0               | 1                 | **51**      | **104 min** | —       |

Le profil par défaut « Sonar way » appliqué aux deux projets ne remonte
aucun bug ni vulnérabilité stricto sensu. Les 51 findings relèvent de la
maintenabilité et de l'accessibilité. Cette observation est importante : elle
signifie que les risques les plus pénalisants du projet (absence
d'authentification, CORS permissifs, CVE dans les dépendances)
**ne sont pas détectés par le SAST** et nécessitent les autres sources
d'analyse présentées plus bas.

Les deux projets passent actuellement le Quality Gate car celui-ci évalue
uniquement le **new code** (code ajouté ou modifié dans les 30 derniers jours),
et les fichiers applicatifs d'origine ont précédé cette fenêtre. La dette
historique reste visible dans l'onglet « Overall Code » et est analysée
ci-dessous.

![Vue d'ensemble SonarCloud — projet Back (Quality Gate PASSED, 5 code smells, 0 bug, 0 vulnérabilité)](misc/screenshots/01-sonar-back-dashboard.png){width=100%}

![Vue d'ensemble SonarCloud — projet Front (Quality Gate PASSED, 46 code smells, 1 security hotspot)](misc/screenshots/02-sonar-front-dashboard.png){width=100%}

### Répartition front par règle

Le front cumule 46 issues distribuées sur 10 règles. Deux règles concentrent
plus de la moitié des findings :

Table: Top 10 des règles violées côté front, triées par fréquence.

+---------------------------------------------+----------+-----+----------------------------------------------+
| Règle                                       | Sévérité | Nb. | Description résumée                          |
+=============================================+==========+=====+==============================================+
| typescript:S4123                            | CRITICAL | 14  | `await` sur valeur non-Promise (Observable)  |
+---------------------------------------------+----------+-----+----------------------------------------------+
| typescript:S2933                            | MAJOR    | 12  | Champ jamais réassigné à marquer `readonly`  |
+---------------------------------------------+----------+-----+----------------------------------------------+
| Web:S6853                                   | MAJOR    | 6   | Label non associé à un contrôle (a11y)       |
+---------------------------------------------+----------+-----+----------------------------------------------+
| css:S4667                                   | MAJOR    | 4   | Fichier CSS vide                             |
+---------------------------------------------+----------+-----+----------------------------------------------+
| typescript:S3626                            | MINOR    | 4   | Redundant jump / return                      |
+---------------------------------------------+----------+-----+----------------------------------------------+
| typescript:S7773                            | MINOR    | 2   | Préférer `Number.parseInt` à `parseInt`      |
+---------------------------------------------+----------+-----+----------------------------------------------+
| typescript:S1128                            | MINOR    | 1   | Import inutilisé (`Router`)                  |
+---------------------------------------------+----------+-----+----------------------------------------------+
| Web:MouseEventWithoutKeyboardEquivalent     | MINOR    | 1   | Span cliquable non accessible clavier (a11y) |
+---------------------------------------------+----------+-----+----------------------------------------------+
| Web:S5256                                   | MAJOR    | 1   | Tableau sans en-têtes `<th>` (a11y)          |
+---------------------------------------------+----------+-----+----------------------------------------------+
| typescript:S7059                            | CRITICAL | 1   | Opération asynchrone dans un constructeur    |
+---------------------------------------------+----------+-----+----------------------------------------------+

Les deux règles dominantes révèlent des **anti-patterns Angular** hérités du
code initial : l'utilisation de `await` sur des `Observable` RxJS (qui ne sont
pas des `Promise`) et l'absence de `readonly` sur les dépendances injectées.
Ces choix ne cassent pas le fonctionnement à l'exécution mais compliquent la
maintenance et peuvent masquer des bugs subtils.

Les 8 issues d'**accessibilité** (règles `Web:*`) sont significatives :
en pratique l'application n'est pas utilisable au clavier ni par un lecteur
d'écran sur certains parcours. Ce type de défaut est invisible aux tests
fonctionnels classiques mais bloquant pour une mise en conformité RGAA.

### Répartition back

Table: Issues SonarCloud côté back.

| Règle       | Sévérité | Fichier                          | Message (résumé)                              |
|-------------|----------|----------------------------------|-----------------------------------------------|
| java:S1186  | CRITICAL | MicroCRMApplicationTests.java:10 | Méthode de test vide sans assertion           |
| java:S1170  | MINOR    | InitialDataFixture.java:15       | Final field à rendre static                   |
| java:S1170  | MINOR    | InitialDataFixture.java:18       | Final field à rendre static                   |
| java:S2293  | MINOR    | Organization.java:35             | Utiliser l'opérateur diamond `<>`             |
| java:S2293  | MINOR    | Organization.java:43             | Utiliser l'opérateur diamond `<>`             |

La seule issue CRITICAL est révélatrice : le projet possède **une unique
classe de test** qui charge le contexte Spring sans exécuter aucune
assertion. Elle vérifie uniquement que l'application démarre — utile, mais
insuffisant pour prétendre à de la couverture métier.

![Liste détaillée des issues SonarCloud sur le projet Back](misc/screenshots/03-sonar-issues-back.png){width=100%}

### Security Hotspot identifié (front)

Table: Hotspot sécurité signalé par SonarCloud.

| Règle     | Fichier        | Ligne | Probabilité | Message                                                       |
|-----------|----------------|-------|-------------|---------------------------------------------------------------|
| Web:S5725 | src/index.html | 9     | LOW         | Ressource externe chargée sans attribut `integrity` (SRI)     |

Le projet ne consomme plus de CDN externes après la migration vers une
dépendance Bulma packagée (commit 8). Le hotspot subsistera tant que Sonar
n'aura pas réanalysé la version courante de `index.html` sans CDN — il
devrait disparaître automatiquement à la prochaine analyse.

### Fichiers les plus impactés (front)

Table: Top des fichiers concentrant le plus d'issues.

| Nombre d'issues | Fichier                                                |
|-----------------|--------------------------------------------------------|
| 12              | `src/app/organization.service.ts`                      |
| 8               | `src/app/person.service.ts`                            |
| 7               | `src/app/person-details/person-details.component.html` |
| 6               | `src/app/person-details/person-details.component.ts`   |
| 5               | `src/app/organization-details/organization-details.component.ts` |

Les deux services (`organization.service.ts` et `person.service.ts`)
concentrent à eux seuls **43 % des findings**. Une refonte ciblée de ces deux
fichiers réduirait substantiellement la dette technique globale du front.

### Couverture des tests

La couverture de tests mesurée par Sonar est actuellement de **0 % côté back**
(tests existants sans assertions métier — voir CRITICAL java:S1186) et non
significative côté front (tests réduits aux fixtures Angular par défaut).

C'est une **limite héritée du code pédagogique** : le projet est conçu pour
démontrer une industrialisation, pas pour fournir un gisement de couverture.
Le plan de remédiation (section 5.3) priorise l'ajout de tests d'intégration
via Testcontainers en P2.

## Analyse des risques

### Risques applicatifs (au-delà du SAST)

Trois catégories de risques réels ne sont pas remontées par SonarCloud et
doivent être documentées explicitement :

Table: Risques applicatifs non détectés par le SAST, classés OWASP Top 10.

+--------------------------------------+----------------------------------------------+---------+
| Catégorie OWASP                      | Observation dans le code                     | Gravité |
+======================================+==============================================+=========+
| A01:2021 Broken Access Control       | `CorsConfiguration.allowedOrigins("*")`      | Élevée  |
|                                      | + pas de filtre sur les endpoints REST       |         |
+--------------------------------------+----------------------------------------------+---------+
| A05:2021 Security Misconfiguration   | Spring Security absent. Tous les endpoints   | Critique|
|                                      | API sont publics par défaut.                 |         |
+--------------------------------------+----------------------------------------------+---------+
| A08:2021 Software & Data Integrity   | Aucun SRI sur les CDN (voir hotspot Sonar).  | Faible  |
|                                      | Corrigé au commit 8, nouveau scan requis.    |         |
+--------------------------------------+----------------------------------------------+---------+
| A09:2021 Security Logging Failures   | Aucun journal d'audit : créations, suppres-  | Moyenne |
|                                      | sions ou accès ne sont tracés.               |         |
+--------------------------------------+----------------------------------------------+---------+

Ces observations proviennent d'une lecture du code source, pas d'un outil.
Elles illustrent la limite intrinsèque d'une chaîne CI/CD reposant uniquement
sur des scanners automatiques : les **décisions de conception** échappent à
la détection statique.

### Risques de la supply chain (Trivy + OWASP Dependency-Check)

Les scanners de dépendances remontent **133 findings ouverts** à la date de
rédaction. Ils se répartissent entre :

- **Dépendances Java** (Tomcat embarqué par Spring Boot, libs transitives)
- **Dépendances npm** (outils de build, polyfills)
- **Couches OS des images Docker** (Ubuntu Jammy, Alpine)

Exemple emblématique : **CVE-2025-55754** (Tomcat embed-core 10.1.x), severity
MEDIUM, concerne l'échappement des séquences ANSI dans les logs — permettant
en théorie la manipulation d'une console Windows qui afficherait ces logs.
Le fix est disponible en Tomcat 10.1.45 ; le projet utilise aujourd'hui une
version inférieure embarquée par Spring Boot 3.2.5.

Ces CVE ne sont pas critiques en urgence (aucune n'expose le projet à une
RCE directe dans son contexte), mais leur accumulation indique que le projet
n'a pas été maintenu activement côté dépendances. Le plan de remédiation P2
prévoit l'upgrade progressif.

![Vue d'ensemble des findings remontés dans l'onglet GitHub Security (Trivy, Checkov, OWASP Dependency-Check)](misc/screenshots/05-github-security-overview.png){width=100%}

![Détail d'un finding Trivy : CVE-2025-55754 sur tomcat-embed-core embarqué par Spring Boot 3.2.5](misc/screenshots/06-github-security-trivy.png){width=100%}

### Risques liés au pipeline

Table: Risques inhérents à la chaîne CI/CD et mitigations en place.

+-------------------------------------+----------------------------------------------------------+
| Risque                              | Mitigation                                               |
+=====================================+==========================================================+
| Secrets en clair dans le code       | .gitignore + GitHub Secrets + Gitleaks sur l'historique  |
+-------------------------------------+----------------------------------------------------------+
| Dépendance obsolète ou vulnérable   | Trivy FS + OWASP Dependency-Check + nightly drift        |
+-------------------------------------+----------------------------------------------------------+
| Image Docker compromise en amont    | SHA-pin de trivy-action post-attaque mars 2026 ;         |
|                                     | images de base officielles uniquement                    |
+-------------------------------------+----------------------------------------------------------+
| Compromission d'un tag GHCR         | Signature cosign keyless + transparency log Rekor        |
+-------------------------------------+----------------------------------------------------------+
| Escalade de privilège conteneur     | User non-root (uid 1001 back, uid 101 front),            |
|                                     | no-new-privileges, réseau db-net internal,               |
|                                     | filesystem read-only (front)                             |
+-------------------------------------+----------------------------------------------------------+
| Injection via workflow GitHub       | Permissions GITHUB_TOKEN minimales par workflow          |
|                                     | (moindre privilège explicite)                            |
+-------------------------------------+----------------------------------------------------------+
| Exécution de code sans tests        | Docker Build & Push dépend du succès des CI via          |
|                                     | workflow_call (gate mathématique, pas conventionnelle)   |
+-------------------------------------+----------------------------------------------------------+

## Plan de remédiation

Le plan s'organise en trois horizons temporels, avec une priorisation qui
pondère **gravité × probabilité × coût de remédiation**. Les actions sont
ensuite regroupées pour optimiser le temps de développement.

### Actions immédiates (P1 — sprint courant)

Les actions P1 ciblent les risques à **gravité critique** ou à **coût faible
et bénéfice élevé** (quick wins). Effort global estimé : **1 à 2 jours**.

Table: Plan d'action P1.

+-----------------------------------------------+---------+--------+---------------+
| Action                                        | Gravité | Effort | Source        |
+===============================================+=========+========+===============+
| Ajouter une assertion réelle à                | Critique| 15 min | Sonar S1186   |
| `MicroCRMApplicationTests` (ou nouveau test)  |         |        |               |
+-----------------------------------------------+---------+--------+---------------+
| Refactor des 14 occurrences `await` sur       | Critique| 2 h    | Sonar S4123   |
| Observable : retourner l'Observable et        |         |        |               |
| `subscribe` côté appelant                     |         |        |               |
+-----------------------------------------------+---------+--------+---------------+
| Ajouter `readonly` aux 12 champs injectés     | Moyenne | 20 min | Sonar S2933   |
+-----------------------------------------------+---------+--------+---------------+
| Restreindre `allowedOrigins` aux domaines     | Élevée  | 30 min | OWASP A01     |
| front autorisés (env-driven)                  |         |        |               |
+-----------------------------------------------+---------+--------+---------------+
| Supprimer les 4 fichiers CSS vides            | Faible  | 5 min  | Sonar S4667   |
+-----------------------------------------------+---------+--------+---------------+
| Supprimer l'import `Router` inutilisé         | Faible  | 1 min  | Sonar S1128   |
+-----------------------------------------------+---------+--------+---------------+

### Actions à court terme (P2 — sous 1 à 3 mois)

Les actions P2 visent la **robustesse** et l'**élévation du niveau de
conformité**. Effort global estimé : **1 à 2 sprints**.

- **Authentification de l'API** — Introduction de Spring Security avec
  authentification JWT ou session. Couvre les risques OWASP A01 et A05
  résiduels.
- **Corriger les 8 issues d'accessibilité** (Web:S6853, Web:S5256,
  MouseEventWithoutKeyboardEquivalent) pour permettre une utilisation au
  clavier et par lecteur d'écran. Incontournable pour une conformité RGAA.
- **Tests d'intégration avec Testcontainers** sur les repositories
  (PostgreSQL réel, pas HSQLDB in-memory). Objectif : atteindre 60 % de
  couverture back, ligne de flottaison acceptable à court terme.
- **Mise à jour Spring Boot 3.2.5 → 3.4.x** pour bénéficier de la structured
  logging native et résoudre la CVE-2025-55754 (Tomcat embarqué).
- **Activation de Dependabot** pour l'automatisation des bumps de
  dépendances et des actions GitHub, en respectant le SHA-pinning sur les
  actions sensibles.
- **Règles de protection de branche** sur `main` : require PR, require CI
  pass, require review avant merge.

### Actions à long terme (P3 — roadmap)

Les actions P3 relèvent de **choix architecturaux** qui sortent du cadre d'un
seul sprint.

- **Migration du front vers un client API correctement configuré** —
  remplacement du `http://localhost:8080` codé en dur par une configuration
  d'environnement injectée à la build ou à l'exécution, routée via Traefik.
- **Journalisation d'audit** (OWASP A09) — un journal applicatif
  indépendant des logs techniques, tracé en base ou en file d'attente, pour
  les créations, modifications et suppressions d'entités.
- **Tests end-to-end** (Playwright ou Cypress) sur les parcours métier
  critiques. Exécution en nightly sur la dernière image buildée.
- **CSP Nginx stricte** — passer de `default-src 'self'` à
  `default-src 'none'` avec whitelisting explicite, pour durcir davantage
  le front.
- **WAL-archiving PostgreSQL** (`pgBackRest` ou `wal-g`) si le RPO de 24 h
  imposé par la sauvegarde quotidienne devient insuffisant pour les usages
  métier.
- **Alerting Kibana** sur les pics d'erreurs ou les latences anormales —
  actuellement le monitoring est exploratoire (dashboards), pas réactif.

\newpage

# Monitoring, métriques & KPI

Ce chapitre consolide trois familles d'indicateurs qui couvrent l'ensemble du
cycle : **métriques DORA** pour la performance du pipeline de livraison (source
GitHub Actions), **KPI applicatifs** pour le comportement de l'application en
cours d'exécution (source ELK), et **KPI qualité** pour la santé statique du
code (source SonarCloud).

Cette partition est volontairement alignée sur la distinction recommandée par
l'énoncé pédagogique : « distinguer les métriques issues du pipeline (CI/CD)
et celles issues de l'application (ELK) ».

## Métriques DORA

Les métriques DORA (DevOps Research and Assessment) sont les quatre
indicateurs historiques de performance d'une chaîne de livraison continue.
Elles couvrent collectivement **vitesse** (Lead Time, Deployment Frequency),
**fiabilité** (MTTR) et **qualité** (Change Failure Rate).

### Lead Time for Changes — Délai de mise en production

**Définition.** Temps moyen entre le moment où un commit est poussé sur
`main` et le moment où l'image Docker correspondante devient disponible sur
GHCR, signée par cosign.

**Méthode de calcul.** Pour chaque run réussi de `docker-build.yml` observé
sur la période, écart entre le timestamp d'auteur du commit déclencheur
(`commit.author.date`) et le timestamp de fin du run
(`completed_at` de l'API GitHub Actions). Moyenne arithmétique sur un
échantillon de minimum 3 runs conformément à la recommandation pédagogique.

**Source des données.** Onglet Actions de GitHub pour consultation
interactive ; pour un relevé programmé, l'API
`/repos/{owner}/{repo}/actions/runs`.

**Valeur observée.** **~12 min 50 s** en moyenne, calculé comme la somme du
temps maximal des deux CI parallèles (back = 1m34, front = 1m26) et de la
durée du Docker Build & Push dépendant (11m16). Le commit `workflow_call`
garantit que Docker Build ne démarre qu'après succès des deux CI, donc la
dépendance est réelle.

**Interprétation selon la grille DORA.** Avec un Lead Time sous les 60
minutes, le projet se classe en niveau **Elite**. Ce résultat est attendu
dans notre contexte — pipeline enchaîné automatiquement après CI, sans
validation humaine intermédiaire, et surtout sans étape de recette
utilisateur.

### Deployment Frequency — Fréquence de déploiement

**Définition.** Nombre de publications d'images sur GHCR par unité de temps.
Dans notre contexte, chaque run réussi de `docker-build.yml` correspond à une
nouvelle image publiée, signée cosign et attachée d'un SBOM — donc à un
déploiement au sens le plus strict de l'industrie.

**Méthode de calcul.** Comptage des runs réussis de `docker-build.yml` sur
une fenêtre connue (dates de premier et dernier runs de la période
d'observation).

**Valeur observée.** **~3,5 runs réussis par jour ouvré** en moyenne sur la
période d'observation (7 runs `docker-build.yml` réussis entre le 21/04 à
15:56 et le 22/04 à 10:01 UTC, soit ~18 heures d'activité).

**Interprétation.** Le chiffre absolu reflète la phase d'industrialisation
active du projet : les commits sont fréquents parce que le pipeline
lui-même est en cours de mise en place. Sur la grille DORA, 3,5
déploiements par jour ouvré place l'équipe en niveau **Elite**. En régime
stable avec une équipe produit, une fréquence de 1 à 3 déploiements par
jour est plus représentative.

### Mean Time to Restore (MTTR) — Temps moyen de rétablissement

**Définition.** Temps moyen nécessaire pour restaurer le pipeline à un état
vert après un échec, mesuré workflow par workflow.

**Méthode de calcul.** Pour chaque run échoué d'un workflow, écart entre son
timestamp et le timestamp du premier run suivant réussi sur le même
workflow. Moyenne des écarts sur l'échantillon observé.

**Valeur observée.** Sur l'échantillon de régime nominal (17 runs réussis
récents), aucun échec n'est survenu. Pour constituer une base de calcul du
MTTR, on se rapporte aux incidents notables de la phase d'industrialisation :

- **Incident SonarCloud HTTP 500 du 22/04 au matin.** Résolu par simple
  attente (service tiers indisponible), délai observé **~15 minutes**.
- **Bug `workflow_call` manquant dans security.yml (Nightly invalide).**
  Correctif poussé et vérifié en **~10 minutes** après détection.
- **Erreur de config Checkov (framework `docker_compose` inexistant).**
  Correctif poussé en **~15 minutes** après détection.
- **Incompatibilité arm64 QEMU sur front.** Correctif (désactivation de la
  cible arm64 pour le front) en **~25 minutes**.

**MTTR moyen estimé : ~16 minutes.**

**Interprétation.** Un MTTR sous l'heure place le projet en niveau **Elite** —
cohérent avec un pipeline dont les échecs sont détectés immédiatement
(feedback CI < 3 min) et où les corrections sont le plus souvent des bumps
d'action ou des corrections de config. Illustration intéressante : le MTTR
dépend aussi de la disponibilité des tiers (SonarCloud), indépendante de
la qualité du pipeline lui-même.

### Change Failure Rate — Taux d'échec des changements

**Définition.** Pourcentage de runs du pipeline qui échouent, rapporté au
total des runs sur la période.

**Méthode de calcul.** Pour chaque workflow :
`(runs en status failure) / (runs en status failure + runs en status success) × 100`.
Les runs en status `cancelled` sont exclus car il s'agit de préemption
(mécanisme `concurrency: cancel-in-progress`) et non d'échecs applicatifs.

**Valeur observée.** **0 %** sur l'échantillon de régime stable (17 runs
récents tous réussis).

Une lecture plus large incluant la phase d'industrialisation (premiers
essais de configuration, bumps d'actions, corrections de fichiers compose)
donnerait un taux historique de **30 à 40 %**. Cette distinction est
assumée : les échecs de la phase de mise en place ne sont **pas** des
incidents de production mais des artefacts de construction, documentés
comme tels dans l'historique Git.

**Interprétation.** Le régime nominal actuel (0 %) place le projet en
niveau **Elite**. Ce chiffre n'est crédible que parce qu'on l'affiche dans
son contexte : une fois le pipeline stabilisé, les runs actuels valident
uniquement du code métier et des modifications documentaires, peu
susceptibles d'échouer. Un taux qui remonterait signalerait soit une
dépendance externe instable, soit l'entrée dans une nouvelle phase
d'évolution du pipeline.

### Synthèse des métriques DORA

Table: Tableau récapitulatif des quatre métriques DORA observées sur la période.

| Métrique              | Valeur observée             | Niveau DORA |
|-----------------------|-----------------------------|-------------|
| Lead Time for Changes | ~12 min 50 s                | Elite       |
| Deployment Frequency  | ~3,5 runs / jour ouvré      | Elite       |
| MTTR                  | ~16 minutes (incidents)     | Elite       |
| Change Failure Rate   | 0 % (régime nominal)        | Elite       |
|                       | 30–40 % (phase industrielle)| Medium      |

## KPI personnalisés

### KPI applicatifs (source : stack ELK)

Les KPI applicatifs sont extraits d'Elasticsearch par agrégations sur les
logs applicatifs indexés (pattern `orion-microcrm-*`, service
`orion-microcrm-back`). Ils caractérisent le comportement de l'application
en cours d'exécution, par opposition à la santé du pipeline.

**Échantillon.** 4146 événements de log indexés sur une fenêtre d'observation
de 6 heures de trafic (commandes `curl` variées sur les endpoints back,
mélange de requêtes valides, d'erreurs 400/404/405 et d'injections
malformées).

Table: Répartition par niveau de log sur l'échantillon d'observation.

| Niveau | Nombre | Ratio   |
|--------|--------|---------|
| INFO   | ~4143  | 99,93 % |
| WARN   | 3      | 0,07 %  |
| ERROR  | 0      | 0 %     |

**Lecture.** Le ratio des niveaux est caractéristique d'une application
fonctionnant nominalement. L'absence d'ERROR ne signifie pas absence
d'erreurs HTTP — les réponses 4xx (requêtes invalides) sont traitées par le
`DispatcherServlet` et remontées en INFO. Un niveau ERROR remonterait soit
une exception non catchée dans le code métier, soit une indisponibilité de
la base de données. L'observation de ce ratio au fil du temps est donc plus
informative qu'une valeur absolue : un glissement brutal vers WARN ou ERROR
est le signal d'alerte clé.

Table: Top 5 des loggers les plus actifs (sur 4146 événements).

| Logger                                                     | Événements | % total |
|------------------------------------------------------------|------------|---------|
| `org.springframework.web.servlet.DispatcherServlet`        | 1668       | 40 %    |
| `HttpEntityMethodProcessor` (Spring MVC)                   | 1367       | 33 %    |
| `RequestResponseBodyMethodProcessor` (Spring MVC)          | 791        | 19 %    |
| `ExceptionHandlerExceptionResolver`                        | 80         | 2 %     |
| `SimpleUrlHandlerMapping`                                  | 41         | 1 %     |

**Lecture.** Les trois premiers loggers (92 % du volume total) correspondent
au pipeline HTTP cœur de Spring MVC : routage, parsing des requêtes,
sérialisation JSON. Cette distribution est le profil attendu d'une
application API REST en charge normale. Le quatrième logger,
`ExceptionHandlerExceptionResolver`, est précieux comme indicateur
métier — ses 80 événements correspondent exactement aux erreurs 400/404/405
provoquées volontairement pendant le test. Un déplacement significatif du
ratio vers ce logger signalerait des requêtes malformées en provenance de
clients, qu'il faudrait investiguer.

Table: Volume de logs par heure (fenêtre d'observation).

| Plage horaire UTC        | Événements |
|--------------------------|------------|
| 05:00–06:00 (démarrage)  | 1085       |
| 06:00–07:00              | 595        |
| 07:00–08:00              | 600        |
| 08:00–09:00              | 600        |
| 09:00–10:00              | 600        |
| 10:00–11:00              | 603        |

**Lecture.** Hors pic de démarrage (1085 événements incluant le bootstrap
Spring), le rythme nominal est de **~600 événements/heure**. Un écart
significatif à la hausse ou à la baisse doit être investigué : chute =
service en panne ; pic = incident métier ou attaque DDoS. Cette variable
peut servir de fondation pour des alertes Kibana futures (seuil bas / seuil
haut sur une agrégation glissante).

![Dashboard Kibana composite consolidant les trois visualisations applicatives (répartition des niveaux, volume horaire, top loggers) — voir annexe D.5 pour la vue en pleine largeur.](misc/screenshots/15-kibana-dashboard-complet.png){width=100%}

### KPI pipeline (source : GitHub Actions)

Les durées des workflows sont relevées depuis l'onglet Actions, sur un
échantillon de 3 runs réussis minimum (conformément à la recommandation
pédagogique).

Table: Temps moyens d'exécution par workflow du pipeline.

| Workflow                | Runs observés | Durée moyenne |
|-------------------------|---------------|---------------|
| CI — Backend            | 3             | 1 min 34 s    |
| CI — Frontend           | 4             | 1 min 26 s    |
| Security                | 2             | 1 min 14 s    |
| Docker Build & Push     | 6             | 11 min 16 s   |
| Nightly                 | 2             | 1 min 43 s    |

**Lecture.** Les deux CI (back et front) s'exécutent sous les 2 minutes
grâce au cache de dépendances (Gradle + npm). Docker Build & Push est
nettement plus long (~11 min) à cause du build multi-architecture
(amd64 + arm64 pour le back via QEMU), de la génération de SBOM SPDX et de
la signature cosign. Le workflow Security tourne en ~1 min 14 s — les jobs
s'exécutent en parallèle (Trivy FS, Gitleaks, OWASP, Checkov, Trivy image
back, Trivy image front) et le temps wall-clock reflète le plus long des
jobs, pas leur somme. Nightly prend ~1 min 44 s parce qu'il relance les
workflows déjà cachés.

![Vue d'ensemble des workflows dans GitHub Actions, source des métriques DORA et des KPI pipeline — voir annexes C.1 et C.2.](misc/screenshots/08-github-actions-workflows.png){width=100%}

### KPI qualité (source : SonarCloud)

Les indicateurs de qualité statique sont déjà détaillés en section 5.1.
Rappel synthétique pour la vue d'ensemble monitoring :

Table: Synthèse des KPI qualité issus de SonarCloud.

| KPI                         | Back              | Front              | Total   |
|-----------------------------|-------------------|--------------------|---------|
| Code smells                 | 5                 | 46                 | 51      |
| Bugs                        | 0                 | 0                  | 0       |
| Vulnerabilities             | 0                 | 0                  | 0       |
| Security Hotspots           | 0                 | 1                  | 1       |
| Dette technique (minutes)   | 11                | 93                 | 104     |
| Quality Gate                | PASSED            | PASSED             | —       |
| Couverture tests            | 0 % (tests vides) | non significative  | —       |

La couverture nulle côté back est une limite pédagogique connue du code
fourni — action P2 du plan de remédiation (Testcontainers + tests
d'intégration).

## Analyse synthétique du monitoring

### Tendances observées

Trois observations majeures émergent de la consolidation des trois sources
de métriques :

1. **Le pipeline est mathématiquement fiable** — une image publiée sur
   GHCR est garantie d'avoir passé les CI et le Quality Gate SonarCloud,
   grâce à la dépendance via `workflow_call`. Les échecs s'accumulent donc
   en amont (tests, analyse), pas en publication : exactement ce qu'on veut
   d'une chaîne CI/CD.
2. **L'application est nominale** — 99,93 % INFO, aucun ERROR. Les
   erreurs HTTP côté client sont correctement canalisées vers le handler
   Spring sans remonter en exception non-catchée. La variance du volume
   horaire (~600/h hors pic) est faible, signe de stabilité.
3. **Le vrai risque est temporel, pas instantané** — les 133 findings
   Trivy, les 11 warnings de dépréciation Node.js 20 sur les actions
   GitHub, les dépendances Spring Boot à monter en version — tous
   s'accumulent lentement. Le workflow nightly est dimensionné pour les
   détecter ; la maintenance régulière (plan P2) est la réponse.

### Points forts

- **Observabilité effective** — on peut, en une requête, répondre à :
  « est-ce que l'application a des erreurs inhabituelles en ce moment ? »
  (agrégation par `log_level`), « quels sont ses endpoints les plus
  sollicités ? » (agrégation par `logger_name`), « à quelle heure les pics
  se produisent-ils ? » (agrégation par `@timestamp`).
- **Supply-chain vérifiable** — chaque image publiée est tracée par son
  commit Git (labels OCI), son SBOM SPDX, et sa signature cosign dans le
  transparency log Rekor. Un tiers peut indépendamment prouver que l'image
  a été produite par le pipeline de ce dépôt, sans avoir accès à aucune
  infrastructure privée.
- **Quality Gate bloquant** — aucune image ne peut être publiée sans que
  SonarCloud ait validé le *new code* selon le profil Sonar way. Les
  régressions sont mathématiquement interceptées à la CI.

### Points à améliorer

- **Pas d'alerting en production** — le monitoring est actuellement
  exploratoire (dashboards Kibana). Aucune alerte ne se déclenche en cas
  de pic d'ERROR ou de chute du volume. La mise en place d'alertes
  Kibana (`Rules and Connectors`) ou d'une brique ElastAlert est listée
  en action P3.
- **Couverture de tests nulle côté back** — conséquence de la structure
  pédagogique du code OpenClassrooms. Mise en place de Testcontainers
  prévue en P2.
- **Pas d'instrumentation de latence** — les métriques applicatives
  actuelles sont volumétriques (comptages). L'ajout de `Micrometer` +
  Prometheus donnerait des histogrammes de temps de réponse et de
  latences SQL, un cran au-dessus en observabilité. Hors scope du projet
  mais action P3 envisageable.
- **Dépréciation Node.js 20 sur actions GitHub** — les warnings émis
  lors du dernier run Security annoncent la bascule forcée vers Node.js 24
  au 2 juin 2026. Dependabot activé (P2) gèrera les bumps.

### Dashboards

Un dashboard Kibana intitulé **Orion MicroCRM — Application Logs** compose
les trois visualisations Lens en une vue unique. Le filtre global
`service_name: orion-microcrm-back` isole le trafic applicatif parmi
l'ensemble des logs indexés (infrastructure ELK incluse). La capture de
ce dashboard figure en annexe D.5.

### Alertes

Aucune règle d'alerting n'est configurée à ce jour. Cette absence est
délibérée à ce stade du projet : l'objectif de la brique ELK était de
démontrer la capacité d'analyse *post hoc* (Discover + visualisations) plus
que la réactivité opérationnelle. L'ajout d'alertes nécessiterait :

- Un seuil bas sur le volume total de logs (détecter un back en panne)
- Un seuil haut sur le ratio ERROR ou sur `ExceptionHandlerExceptionResolver`
- Un canal de notification (e-mail, Slack, webhook)

Ces éléments sont listés comme action P3 dans le plan de remédiation.

\newpage

# Plan de sauvegarde des données

## Ce qui doit être sauvegardé

Conformément au principe « sauvegarder uniquement ce qui ne peut être
reconstruit », le périmètre de sauvegarde est **strictement limité à la base
PostgreSQL** en production. Tout le reste est reproductible ou déjà versionné.

| Élément | Sauvegardé ? | Justification |
|---------|:-:|---------------|
| Base PostgreSQL (prod) | oui | Seul état utilisateur durable, non reconstructible |
| Base HSQLDB (dev) | non | In-memory, éphémère par conception |
| Code source | non | Versionné dans Git (GitHub) |
| Images Docker | non | Publiées sur GHCR, reproduites depuis le code |
| Secrets GitHub Actions | non | Externes au pipeline, rotation prévue |
| Certificats Let's Encrypt | non | Regénérés automatiquement par Traefik |
| Logs ELK | non | Stack locale de développement, éphémère |
| Configuration compose | non | Versionnée dans Git |
| Fichiers `.env` | non | Secrets non versionnés, gérés hors pipeline |

## Procédure de sauvegarde

### Format technique

- **Format** : PostgreSQL custom (`pg_dump -Fc`) — binaire compressé.
- **Pourquoi pas SQL texte** : custom est ~5 à 10 fois plus petit qu'un dump
  SQL, permet la restauration **sélective** (une seule table, juste les
  données sans le schéma), et permet la restauration **parallèle** (`-j 4`).
- **Nommage** : `microcrm-YYYYMMDD-HHMMSS.dump` (horodatage UTC, tri
  alphabétique = tri chronologique).

### Fréquence recommandée

| Environnement | Cadence | Rétention |
|---------------|---------|-----------|
| Production | Quotidienne, pendant la fenêtre de faible trafic (02:00-04:00 locale) | 7 jours en local + 30 jours archivés (coffre externe) |
| Staging | Hebdomadaire | 4 semaines |
| Dev | Aucune (HSQLDB éphémère) | — |

### Outil

Le script `scripts/backup-db.sh` (voir §2.2) s'exécute hors pipeline CI/CD :
ELK et les backups sont des opérations **locales/opérationnelles**, pas des
étapes de build. L'orchestration (cron, systemd timer, CronJob Kubernetes)
relève de l'environnement de déploiement cible et n'est pas imposée par ce
document.

Exemple d'entrée cron sur un serveur Linux :

```cron
# Backup quotidien à 02:30 locale
30 2 * * * cd /opt/orion-microcrm && ./scripts/backup-db.sh >> /var/log/orion-backup.log 2>&1
```

## Procédure de restauration

### Scénario d'incident typique

Un déploiement a introduit une migration Flyway/Liquibase corrompue qui a
détruit une table. Le back plante au démarrage, l'UI affiche des erreurs 500.
Le dump de la veille (02:30) est intact dans `./backups/`.

### Étapes pour revenir à une version stable

Le script `scripts/restore-db.sh` automatise l'intégralité de la procédure :

```bash
# Depuis le serveur de production
cd /opt/orion-microcrm
./scripts/restore-db.sh ./backups/microcrm-20260421-023000.dump
```

Le script enchaîne :

1. **Confirmation interactive** (sautable avec `FORCE=1` pour les runs
   non-interactifs).
2. **Arrêt du back** (évite les écritures concurrentes pendant la reprise).
3. **Drop + recréation de la base cible** (la base est remise à blanc pour
   éviter les conflits avec les objets existants).
4. **Chargement du dump** via `pg_restore --no-owner --verbose`.
5. **Redémarrage du back** via `docker compose up -d back`.
6. **Smoke-test HTTP** — interroge `/actuator/health` jusqu'à recevoir
   `"status":"UP"` ou timeout à 60 secondes.

Si le smoke-test échoue, le script sort en code 1 : `pg_restore` peut
techniquement réussir tout en laissant la base dans un état où le back ne
peut pas se connecter (grants manquants, propriété incorrecte…). Le
smoke-test valide la chaîne complète.

### Limitations connues

- Une restauration restaure **la base entière**. La restauration partielle
  (une seule table) est possible mais non couverte par le script — nécessite
  un `pg_restore --table=` manuel.
- Les données produites **entre la fin du dump et le début de l'incident**
  sont perdues. Le RPO (Recovery Point Objective) avec une cadence quotidienne
  est donc de 24 heures. Si nécessaire, un dump plus fréquent ou un mécanisme
  WAL-archiving (`pgBackRest`, `wal-g`) peut être mis en place — hors
  périmètre de ce projet.

\newpage

# Plan de mise à jour

## Mise à jour de l'application

### Dépendances Gradle (back)

- Les versions sont pinnées dans `back/build.gradle`.
- **Détection de dérive** : le workflow Nightly exécute `gradle dependencies`
  et archive le rapport comme artefact (30 jours de rétention).
- **Détection de CVE** : Trivy FS et OWASP Dependency-Check (nightly) remontent
  les vulnérabilités dans l'onglet Security de GitHub.
- **Processus recommandé** : incréments MINOR d'abord, tests complets, puis
  MAJOR planifiés en sprint dédié.

### Dépendances npm (front)

- Versions pinnées dans `front/package.json` + lockfile `package-lock.json`.
- `npm ci` (commande utilisée par le pipeline) **échoue** si le lockfile et
  package.json divergent — garantie anti-surprise.
- **Détection de dérive** : Nightly exécute `npm outdated --json` et archive
  le rapport.
- **Processus recommandé** : similaire au back, avec une vigilance
  particulière pour Angular dont les upgrades MAJOR peuvent nécessiter des
  migrations de schéma (ng update).

### Mises à jour Angular / Spring Boot

- **Angular** : utiliser `ng update` (outil officiel de migration). Planifier
  une session dédiée par version MAJOR car Angular peut déprécier des APIs
  (ex: RxJS, Ivy, standalone components).
- **Spring Boot** : consulter le Release Notes et le Migration Guide
  (`spring.io/projects/spring-boot`). Les tests d'intégration (à ajouter en
  P2 du plan de remédiation) deviennent essentiels pour valider sans régression.

### Mises à jour des images Docker

- Toutes les images de base sont **pinnées à une version précise** (ex:
  `eclipse-temurin:17-jre-jammy`, `postgres:16.4-alpine`,
  `nginxinc/nginx-unprivileged:1.27-alpine`). Aucune n'utilise `:latest` (qui
  rompt la reproductibilité).
- **Détection de CVE** : Trivy Image (nightly) scanne les images buildées.
- **Processus recommandé** : revue mensuelle des CVE sur les images de base,
  bump en priorisant les CVE CRITICAL/HIGH.

## Mise à jour du pipeline CI/CD

### Versions des actions GitHub

- Les actions tierces critiques (`aquasecurity/trivy-action`) sont
  **épinglées par commit SHA** suite à l'attaque supply-chain de mars 2026.
  Ce n'est pas une convention, c'est une défense technique : un SHA est
  immuable, un tag peut être force-pushé vers un commit malveillant.
- Les actions officielles GitHub (`actions/*`) sont épinglées par version
  majeure (`@v4`), considérées de confiance suffisante.
- **Automatisation future** : Dependabot (P2 du plan de remédiation) peut
  proposer des PR de bump automatique tout en respectant le SHA-pinning.

### Versions des scripts

- Les scripts shell (`backup-db.sh`, `restore-db.sh`) sont versionnés dans le
  repo. Toute modification passe par une PR et est tracée.
- Les commandes invoquées (Gradle, npm, docker, pg_dump) sont fournies par
  les images de base Docker — leur version est liée à celle de l'image,
  donc au tag précis utilisé.

### Maintenance du workflow

- **Logs de chaque run** : conservés 90 jours par défaut par GitHub Actions.
- **Artefacts** : conservés 7 jours pour les outputs de test, 30 jours pour
  les rapports de sécurité et de drift.
- **Revue régulière** : consulter l'onglet Security de GitHub au moins une
  fois par sprint.

## Fréquence & bonnes pratiques

| Type de mise à jour | Cadence recommandée | Déclenchement |
|--------------------|---------------------|---------------|
| Dépendances PATCH (ex: lib 1.2.3 → 1.2.4) | Automatique via Dependabot | PR auto |
| Dépendances MINOR | Mensuelle | PR groupée |
| Dépendances MAJOR | Trimestrielle, sprint dédié | Planifié |
| Image de base (OS) | CVE CRITICAL/HIGH : immédiat, sinon mensuel | Manual / Dependabot |
| Actions GitHub tierces | Revue trimestrielle + immédiate sur advisory | SHA rotation |
| Spring Boot / Angular majeurs | Annuelle, sprint dédié | Planifié |

**Bonnes pratiques transverses :**

- Ne jamais déployer un vendredi soir.
- Toujours faire un backup avant un upgrade majeur.
- Toujours avoir un run CI vert sur la version cible avant de merger.
- Vérifier les **Release Notes** et **Migration Guides** — pas uniquement les numéros de version.
- Conserver un historique des décisions d'upgrade (pourquoi telle version a été sautée, etc.) soit dans `CHANGELOG.md`, soit dans les descriptions de PR.

\newpage

# Conclusion

## Résumé des améliorations apportées

Le dépôt livré par Maria était un projet applicatif fonctionnel mais sans
aucune industrialisation : pas de tests automatiques, pas d'analyse de
qualité, pas d'images reproductibles, pas de traçabilité. En l'état, il était
impossible de livrer en continu tout en garantissant un niveau de qualité et
de sécurité satisfaisant.

Au terme de la mission, le dépôt dispose d'une **chaîne de livraison complète**
qui couvre :

- **Intégration continue** — build et tests automatiques sur chaque changement
  de code, avec feedback en moins de 5 minutes.
- **Analyse qualité** — SonarCloud intégré en mode monorepo, quality gate
  bloquant le pipeline sur régression.
- **Sécurité defence-in-depth** — cinq scanners complémentaires (Trivy × 2,
  Gitleaks, OWASP, Checkov) remontant leurs findings dans l'onglet Security
  de GitHub pour tri centralisé.
- **Conteneurisation durcie** — Dockerfiles multi-stage, utilisateurs
  non-root, filesystem read-only, réseau DB isolé en `internal: true`.
- **Supply-chain sécurisée** — images multi-arch signées par cosign keyless
  (OIDC GitHub), SBOM SPDX attaché, attestation de provenance SLSA.
- **Observabilité** — stack ELK locale pour centraliser les logs applicatifs
  en format ECS JSON.
- **Reprise après incident** — scripts de backup/restore PostgreSQL avec
  smoke-test automatique de l'endpoint `/actuator/health`.
- **Cadence régulière** — workflow Nightly qui ré-exerce l'intégralité du
  pipeline chaque nuit pour détecter la dérive passive (nouvelles CVE,
  dépendances obsolètes).

## Gains observés

**Fiabilité** — Aucune image ne peut être publiée sans avoir passé les tests et
le quality gate SonarCloud. Aucune image ne peut atteindre l'utilisateur sans
être signée par le workflow GitHub Actions qui l'a produite, signature
vérifiable publiquement via cosign + Rekor.

**Rapidité** — Le feedback d'un commit individuel est livré en quelques
minutes. La publication d'une release versionnée (tag `v*.*.*`) déclenche
automatiquement la chaîne complète — aucune étape manuelle.

**Qualité** — Chaque changement est analysé par SonarCloud, qui bloque toute
régression sur le new code.

**Sécurité** — La surface d'attaque est réduite au minimum (images minimales
officielles, utilisateurs non-root, réseau segmenté, pas de secret en clair).
Les CVE sont détectées automatiquement par Trivy et OWASP, et la chaîne
d'approvisionnement est attestable cryptographiquement.

**Traçabilité** — Chaque image possède des labels OCI qui pointent vers le
commit Git exact qui l'a produite. Chaque signature cosign est enregistrée
dans le transparency log Rekor, accessible publiquement.

## Recommandations pour les itérations suivantes

La liste n'est pas limitative — elle reflète les pistes identifiées au cours
de ce projet et consolidées par l'analyse SonarCloud et les findings de la
section 5.

**Priorité haute (prochain sprint)**

- Activer les règles de protection de branche sur `main` (require PR, require
  CI pass, require review).
- Ajouter Dependabot pour automatiser les bumps de dépendances et d'actions.
- Traiter les vulnérabilités CRITICAL et HIGH identifiées par SonarCloud
  (CORS `*`, absence d'auth sur les endpoints API).

**Priorité moyenne (trimestre en cours)**

- Ajouter Spring Security avec authentification JWT ou session.
- Corriger la dépendance JPA dupliquée dans `build.gradle`.
- Atteindre 80 % de couverture sur le back via des tests d'intégration
  (Testcontainers + PostgreSQL).
- Refactorer le front pour supprimer le `localhost:8080` hardcodé et
  router l'API à travers Traefik.

**Priorité basse (roadmap moyen terme)**

- Introduire des tests end-to-end (Playwright ou Cypress) sur les parcours
  métier critiques.
- Mettre en place un alerting basé sur les logs ELK (Kibana Alerting ou
  ElastAlert) sur les pics d'erreurs, les latences anormales, etc.
- Étudier la migration vers un runtime Kubernetes si les contraintes de
  scalabilité le justifient.
- Ajouter du WAL archiving PostgreSQL (pgBackRest) si le RPO de 24h devient
  insuffisant pour les usages métier.

Le pipeline livré n'est pas un état final mais une **fondation** : chaque
itération future bénéficie d'un terrain où les contrôles automatiques sont
déjà en place. Les prochaines évolutions pourront se concentrer sur la
valeur métier, en confiance.

\newpage

# Annexes

Les annexes regroupent l'ensemble des captures d'écran produites pendant
l'exploitation de la chaîne CI/CD, du SAST et de la stack d'observabilité.
Elles sont organisées par source (SonarCloud, GitHub Security, GitHub
Actions, Kibana) pour faciliter la consultation ciblée.

Chaque capture reste accessible directement dans le dépôt sous
`misc/screenshots/` avec un nommage numéroté qui reflète l'ordre de
présentation.

## Annexe A — Captures SonarCloud

![A.1 — Dashboard SonarCloud du projet Back. Quality Gate PASSED sur le *new code*, aucun bug ni vulnérabilité détectés, 5 code smells de faible à critique sévérité.](misc/screenshots/01-sonar-back-dashboard.png){width=100%}

![A.2 — Dashboard SonarCloud du projet Front. Quality Gate PASSED, 46 code smells (effort 1h33), 1 security hotspot (absence de SRI).](misc/screenshots/02-sonar-front-dashboard.png){width=100%}

![A.3 — Liste détaillée des issues sur le projet Back, triées par sévérité.](misc/screenshots/03-sonar-issues-back.png){width=100%}

![A.4 — Security Hotspots sur le projet Back. Aucun hotspot détecté à ce jour.](misc/screenshots/04-sonar-hotspots-back.png){width=100%}

\newpage

## Annexe B — Captures GitHub Security

![B.1 — Vue d'ensemble de l'onglet GitHub Security / Code Scanning. Findings remontés par Trivy, Checkov et OWASP Dependency-Check centralisés en un seul endroit.](misc/screenshots/05-github-security-overview.png){width=100%}

![B.2 — Détail d'un finding Trivy : CVE-2025-55754 sur tomcat-embed-core. La vulnérabilité concerne l'échappement des séquences ANSI et est corrigée à partir de Tomcat 10.1.45.](misc/screenshots/06-github-security-trivy.png){width=100%}

![B.3 — Détail d'un finding Checkov : misconfiguration sur un Dockerfile ou un fichier Compose. Les règles Checkov couvrent les bonnes pratiques CIS sur les conteneurs et l'infrastructure-as-code.](misc/screenshots/07-github-security-checkov.png){width=100%}

\newpage

## Annexe C — Captures GitHub Actions et GHCR

![C.1 — Vue d'ensemble des cinq workflows du pipeline CI/CD dans l'onglet Actions de GitHub.](misc/screenshots/08-github-actions-workflows.png){width=100%}

![C.2 — Détail d'un run réussi du workflow Docker Build & Push. Les jobs dépendants (CI back, CI front, build matrix, SBOM, signature cosign) sont visibles dans le graphe d'exécution.](misc/screenshots/09-github-actions-run-detail.png){width=100%}

![C.3 — Page des packages GHCR. Les images orion-microcrm-back et orion-microcrm-front sont publiées avec leurs tags, leurs architectures multi-plateformes et leurs labels OCI qui pointent vers le commit Git d'origine.](misc/screenshots/10-github-packages.png){width=100%}

\newpage

## Annexe D — Captures Kibana (observabilité applicative)

![D.1 — Vue Discover de Kibana filtrée sur `service_name: orion-microcrm-back`. Chaque ligne est un événement ECS JSON émis par Spring Boot : log_level, logger_name, message.](misc/screenshots/11-kibana-discover.png){width=100%}

![D.2 — Visualisation Lens : répartition des niveaux de log (INFO, WARN, ERROR, DEBUG) sur la période observée. Permet de détecter immédiatement une dérive anormale vers le rouge.](misc/screenshots/12-kibana-pie-log-levels.png){width=100%}

![D.3 — Visualisation Lens : volume de logs sur le temps, segmenté par niveau. Permet d'identifier les pics d'activité et les fenêtres d'erreurs groupées.](misc/screenshots/13-kibana-histogram-volume.png){width=100%}

![D.4 — Visualisation Lens : top 5 des loggers les plus actifs. Utile pour repérer les classes Java qui produisent le plus de trafic, souvent un indicateur d'endpoints à fort trafic ou de boucles à examiner.](misc/screenshots/14-kibana-top-loggers.png){width=100%}

![D.5 — Dashboard composite Orion MicroCRM — Application Logs. Assemble les trois visualisations précédentes dans une vue unique, filtrable globalement par service_name ou par plage horaire.](misc/screenshots/15-kibana-dashboard-complet.png){width=100%}

\newpage

## Annexe E — Extraits de workflows

Les workflows complets sont disponibles dans le répertoire `.github/workflows/`
du dépôt :

- `ci-backend.yml` — intégration continue back-end
- `ci-frontend.yml` — intégration continue front-end
- `security.yml` — chaîne de scanners de sécurité
- `docker-build.yml` — publication d'images signées sur GHCR
- `nightly.yml` — ré-exécution programmée et analyse de dérive
- `docs.yml` — génération PDF de la documentation via Pandoc

## Annexe F — Commandes utiles

```bash
# Cloner le projet
git clone https://github.com/GuillaumeSadlerOC/software_architect_P9.git
cd software_architect_P9

# Lancer la stack dev (HSQLDB en mémoire)
docker compose up -d

# Lancer la stack prod-like (PostgreSQL)
docker compose -f docker-compose.yml up -d

# Lancer la stack ELK en parallèle
docker compose -f docker-compose-elk.yml up -d

# Accès
# UI MicroCRM       http://localhost:8000
# API back          http://localhost:8080
# Traefik dashboard http://localhost:8090
# Kibana            http://localhost:5601
# Elasticsearch     http://localhost:9200

# Backup / Restore
./scripts/backup-db.sh
./scripts/restore-db.sh ./backups/microcrm-YYYYMMDD-HHMMSS.dump

# Vérifier la signature cosign d'une image GHCR
cosign verify ghcr.io/guillaumesadleroc/orion-microcrm-back:latest \
  --certificate-identity-regexp 'https://github.com/GuillaumeSadlerOC/software_architect_P9/.*' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com

# Générer le PDF de la documentation localement
docker run --rm -v "$PWD":/data pandoc/latex:3.5 \
  docs/documentation.md \
  --output=dist/documentation.pdf \
  --pdf-engine=xelatex \
  --toc \
  --number-sections \
  --highlight-style=tango \
  --include-in-header=docs/header.tex \
  -V linkcolor=NavyBlue \
  -V urlcolor=NavyBlue \
  -V geometry:margin=2.5cm
```
