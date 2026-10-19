# Raido sur AWS (raido.runeride.fr)

Module Terraform du calculateur de balade décrit dans `runeride/docs/itineraire.md` (§5.2 architecture sans serveur,
§5.5 coûts, §5.6 Terraform, §7.2 API) ; code Rust dans `runeride-carto/rust` (`docs/raido.md` : mesures du PoC).

> **Ce module n'a jamais été appliqué, ni même planifié.** Pas d'identifiants, aucun appel AWS. La seule vérification
> effectuée est `terraform fmt`, `terraform init -backend=false` et `terraform validate`. Cela contrôle la syntaxe, les
> types et les références, **pas** le comportement réel d'AWS.

## Ce que fait le module

| Fichier | Ressources |
|---|---|
| `stockage.tf` | Compartiment S3 privé du graphe (blocage d'accès public, SSE-S3, propriétaire imposé, purge des envois multipart, refus sans TLS). Lu par la seule fonction : ni CloudFront ni navigateur (spec O4). |
| `fonction.tf` | Lambda `calcul` (arm64, `provided.al2023`, zip `chemin_zip`), rôle de moindre privilège (`GetObject` sur `graphe/courant/*`, `ListBucket` restreint au préfixe, journaux), groupe de journaux, **Function URL en `AWS_IAM`**, permission `lambda:InvokeFunctionUrl` pour la seule distribution. |
| `cloudfront.tf` | Certificat ACM en `us-east-1`, **OAC de type `lambda`**, politique d'en-têtes (CORS `app.runeride.fr`, `runeride.fr`, dev local ; HSTS, nosniff), distribution avec deux comportements : `/v1/sante` (cache 30 s) et défaut (POST, `CachingDisabled`, `AllViewerExceptHostHeader`, compression). |
| `alarmes.tf` | 3 alarmes (erreurs, limitations, durée > 80 %), 4 avec `alarme_cloudfront` ; sujet SNS avec abonnement e-mail. |
| `budget.tf` | Budget mensuel de 5 $ filtré sur l'étiquette `composant = raido`, alertes à 80 % et 100 % du réel, 100 % de la prévision. |

## Ce qui n'est PAS créé

- Pas d'API Gateway (Function URL + OAC suffit et coûte 0), pas de VPC, pas de DynamoDB, pas de WAF.
- Pas de **délivrance** du jeton court : la fonction **vérifie** le JWT RS256 (`RAIDO_JETON=obligatoire`, JWKS
  `jwks_url`, `iss` et `aud` attendus) et applique ses revendications (`type` = `petite_boucle` → `/v1/balade` seul et
  distance ≤ `limite_km` ; `palier` ≠ `abonne` → découverte refusée), mais c'est le PHP de `app.runeride.fr` qui doit
  l'émettre (`POST /api/balade/jeton`, spec §7.1, jalon J4) avec `aud = raido`, `exp` court (15 min) et ces revendications.
  Sans ce point d'entrée PHP, aucun client légitime ne peut appeler l'API (elle répond `401`).
- Pas de publication du graphe : voir la sortie `publier_graphe` (`aws s3 sync`), à faire à la main avant la
  première invocation. Un graphe = un dossier ; une nouvelle version va dans un autre dossier puis `prefixe_graphe`
  change (nouveau déploiement de la fonction, donc nouveau cache `/tmp`).
- Pas d'enregistrement DNS (o2switch) : ils sont donnés en sortie.

## Le piège du POST derrière un OAC Lambda

CloudFront signe (SigV4) les requêtes vers la Function URL mais **ne calcule pas le condensé du corps** : pour un
`POST`, le client doit envoyer lui-même l'en-tête **`x-amz-content-sha256`** = SHA-256 hexadécimal du corps, sinon la
Function URL répond `403`. La PWA le fera avec `crypto.subtle.digest` (jalon J4). Essai à la main :

```sh
CORPS='{"depart":{"lat":45.1885,"lon":5.7245},"duree_min":180,"evitements":["autoroutes","peages","non_revetu"]}'
curl -s -X POST "https://<cloudfront>/v1/balade" \
  -H 'content-type: application/json' \
  -H "authorization: Bearer <jeton court délivré par app.runeride.fr>" \
  -H "x-amz-content-sha256: $(printf '%s' "$CORPS" | sha256sum | cut -d' ' -f1)" \
  --data "$CORPS"
```

`AllViewerExceptHostHeader` transmet cet en-tête à l'origine ; la politique CORS l'autorise en requête préalable.

## Ordre d'application recommandé (chaque étape demande un accord explicite)

1. Construire le zip : `runeride-carto/rust/tools/package-lambda.sh` (arm64, 1,3 Mo), puis le graphe :
   `raido-graphe construire <extrait>.osm.pbf <dossier>`.
2. `cp terraform.tfvars.example terraform.tfvars`, adapter ; `terraform init -backend-config=… -backend-config="key=raido/<env>.tfstate"` ; `terraform plan` (le lire : première fois).
3. `terraform apply -target=aws_acm_certificate.raido`, créer le CNAME de validation chez o2switch, attendre l'émission.
4. `terraform apply` (tout sauf le domaine), publier le graphe (`publier_graphe`), tester sur l'adresse CloudFront :
   `GET /v1/sante`, puis le `POST` ci-dessus ; lire les journaux (démarrage : source, version du graphe, tuiles).
5. Mesurer : démarrage à froid (chargement de `index.json` + tuiles depuis S3), `MaxMemoryUsed`, durée des boucles de
   120 et 200 km ; ajuster `memoire_mo` (vCPU) et `ephemere_mo`.
6. Quand le PHP délivre le jeton court (J4) : `certificat_valide = true`, `terraform apply`, CNAME `raido` vers CloudFront.
7. Réserver la concurrence (`concurrence_reservee = 10`) dès que le quota du compte le permet.

## Coût

Spec §5.5 (ESTIMATION) : franchise Lambda permanente (400 000 Go·s) non épuisée à 2 000 calculs par mois, S3 ≈ 0,1 $,
CloudFront dans le palier gratuit, soit **< 1 $ par mois**. Ce qui fait dépasser : une concurrence non réservée face à
un afflux (d'où le budget à 5 $ et l'alarme de limitations), un stockage éphémère de 10 Go, des journaux verbeux.

## Risques et réserves

- **Rien n'est validé contre AWS.** En particulier : l'OAC de type `lambda` avec `POST` (comportement de
  `x-amz-content-sha256`), la permission `lambda:InvokeFunctionUrl` avec `function_url_auth_type`, les identifiants des
  politiques gérées (`CachingDisabled`, `AllViewerExceptHostHeader`) écrits de mémoire, la condition `s3:prefix` sur
  `ListBucket` (non vérifiée sur ../meteo non plus).
- **Délai** : CloudFront attend 30 s l'origine (`origin_read_timeout`), la fonction est coupée à 29 s ; une boucle de
  200 km prend jusqu'à 7 s sur un vCPU. Monter `memoire_mo` plutôt que `timeout`.
- **Démarrage à froid** : lecture de `index.json` puis des tuiles de l'emprise (54 Mo pour 120 km en z9, mesuré sur
  disque local, pas sur S3) ; ESTIMATION 0,5 à 1 s depuis S3 en région. Le cache `/tmp` ne survit pas à un nouvel
  environnement d'exécution.
- **Quotas du compte neuf** : concurrence Lambda possiblement limitée à 10 (réservation refusée), mémoire à 3 008 Mo.
- **Alarmes** : 10 gratuites pour le compte, partagées avec ../meteo et ../deploiement.
- **TLS en Rust pur** (`rustls-rustcrypto` alpha, via `rw-aws`) face aux points de terminaison S3 d'AWS : non vérifié
  au 18/10/2026 ; le test jetable de runeride-weather (`tools/test-lambda-jetable.sh`) doit passer avant.
- **État Terraform** : `backend "s3"` partiel comme ../meteo ; le compartiment d'état doit exister.

## Validation effectuée

```sh
terraform fmt
terraform init -backend=false
terraform validate
```

Rien d'autre : pas de `plan`, pas d'`apply`, aucun appel AWS, aucun identifiant lu.
