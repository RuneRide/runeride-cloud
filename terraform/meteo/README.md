# Météo de RuneRide sur AWS (weather-data.runeride.fr)

Module Terraform de la chaîne météo décrite dans `runeride-weather/docs/architecture-aws.md` (§3, §4.3, §6, §7 et surtout
§10 « Variante lancement < 1 $/mois ») et `runeride-weather/docs/poc-rust/lambda.md` (§4 variables, §10 IAM et réglages,
§3 clés S3).

> **Ce module n'a jamais été appliqué, ni même planifié.** Pas d'identifiants, aucun appel AWS. La seule vérification
> effectuée est `terraform fmt`, `terraform init -backend=false` et `terraform validate` (succès, fournisseur aws 6.69.1,
> Terraform 1.15.9). Cela contrôle la syntaxe, les types et les références, **pas** le comportement réel d'AWS.

## Ce que fait le module

| Fichier | Ressources |
|---|---|
| `stockage.tf` | Compartiment S3 privé (blocage d'accès public, SSE-S3, propriétaire imposé, versionnage jamais activé), CORS, cycle de vie (expiration à `retention_jours` = 2 sur `v1/arome/`, `v1/arome-hd/`, `v1/isobares/` et `v1/_poller/`, jamais sur `manifest.json`, `sante.json` ni `basemap/` ; purge des envois multipart abandonnés), politique : lecture par la seule distribution de `v1/*` et `basemap/*`, **refus explicite des dossiers `_*`**, refus sans TLS |
| `cloudfront.tf` | Certificat ACM en `us-east-1` (validation DNS), OAC, politique d'en-têtes (CORS limité à `weather.runeride.fr` et au viewer local `localhost:8187`, HSTS, nosniff), politique de cache du manifeste (TTL 30 s, max 60 s, gzip/brotli), distribution (alias `weather-data.runeride.fr`, `PriceClass_100`, HTTP/3) avec cinq comportements : `*/_*` (jamais servi), `v1/isobares/*` (compressé), `manifest.json`, `sante.json`, défaut = `.pmtiles` et `basemap/*` (cache `CachingOptimized` qui respecte `Cache-Control: immutable`, pas de compression, `Range` natif) |
| `file.tf` | File SQS des tâches (visibilité `max(720, 6 × timeout)` s, redrive vers la file de rebut après 5 réceptions) et file de rebut |
| `worker.tf` | Lambda `worker` (arm64, `provided.al2023`, zip fourni par `chemin_zip_worker`), rôle IAM de moindre privilège (politique d'exemple de `lambda.md` §10.1), groupe de journaux (7 jours), mapping SQS `BatchSize 1` + `ReportBatchItemFailures` + `MaximumConcurrency` réglable, filtre de métrique sur `"classe":"definitive"` |
| `alarmes.tf` | 7 alarmes (9 avec poller et manifeste) : rebut non vide, erreurs, limitations, durée > 80 %, âge de la file > 30 min, erreurs définitives, 5xx CloudFront > 1 % ; sujets SNS (eu-north-1 et us-east-1) avec abonnement e-mail |
| `budget.tf` | Budget mensuel de 1 $ (paramétrable), alertes à 80 % et 100 % du réel, 100 % de la prévision |
| `forfait.tf` | **Facultatif, désactivé** : ACL WAF + forfait CloudFront (voir plus bas) |
| `planification.tf` | **Facultatif, désactivé** : poller + EventBridge Scheduler, manifeste + file d'événements S3 |

## Ce qui n'est PAS créé

- **Poller et manifeste** : le code existe (`rw-poller`, `rw-manifeste`, `docs/poc-rust/poller-manifeste.md`), testé en
  local seulement. Avec `activer_poller` / `activer_manifeste` à `false` (défaut), rien ne les concerne. À `true`,
  `planification.tf` crée fonction, rôle, journaux, Scheduler toutes les 5 min, file et notification S3 du manifeste.
  Droits IAM et variables d'environnement ont été relus contre le code (opérations S3/SQS émises, variables lues), pas
  contre AWS. Zips : `rust/tools/package-lambda.sh arm64 tout` (le workflow `release.yml` ne construit PAS ces deux-là :
  il cherche un binaire nommé `bootstrap`). Le poller n'écrit pas `sante.json`. Sans poller, **rien n'alimente la file**.
- Pas de DynamoDB (l'état d'échéance est dans S3, comme dans `lambda.md`), pas de WAF payant, pas de NAT/VPC, pas de
  Secrets Manager, pas d'API point/itinéraire, pas de métrique « âge du dernier tirage » (elle viendrait du poller).
- Pas d'enregistrement DNS (o2switch) : ils sont donnés en sortie.
- Pas de `moved`/import : tout est nouveau.

## Forfait CloudFront (vérifié dans le fournisseur)

Le fournisseur aws 6.69.1 n'a **aucun** attribut de forfait sur `aws_cloudfront_distribution`, mais il a une
ressource `aws_pricingplanmanager_subscription` (`plan_family = "CloudFront"`, `plan_tier` = FREE/PRO/BUSINESS/PREMIUM,
exactement une distribution et une ACL WAF). `forfait.tf` l'utilise si `forfait_cloudfront` est renseignée.
**Défaut : désactivé**, la distribution est à l'usage (palier gratuit 1 To / 10 M de requêtes) et le forfait Free se
souscrit dans la console, comme pour `../tuiles`. Non essayé : éligibilité du compte (le forfait peut exclure l'offre
gratuite AWS, `architecture-aws.md` §10.4), règle de débit WAF incluse ou non dans le Free, comportement exact de
l'approbation. La documentation de la ressource consultée est celle du dépôt du fournisseur, pas AWS.

## Ordre d'application recommandé (chaque étape demande un accord explicite)

1. Prérequis ci-dessous, puis `cp terraform.tfvars.example terraform.tfvars` et adapter.
2. `terraform init -backend-config="bucket=…" -backend-config="key=meteo/<env>.tfstate"` puis `terraform plan`
   (lire le plan : c'est la première fois qu'il est produit).
3. `terraform apply -target=aws_acm_certificate.donnees`, puis créer chez o2switch le CNAME de validation
   (sortie `dns`, rôle « validation du certificat ACM »), attendre l'émission.
4. Passer `certificat_valide = true`, `terraform apply` (le zip du worker doit exister), puis créer le CNAME
   `weather-data` vers la sortie `cloudfront` (dernier élément de `dns`).
5. Confirmer les deux e-mails d'abonnement SNS.
6. Publier à la main un tirage de test dans le préfixe `v1/` et vérifier : `Range` (`curl -H 'Range: bytes=0-16383'`),
   CORS (`Origin: https://weather.runeride.fr`), absence de service des dossiers `_*` (attendu : 403), `X-Cache`.
7. Souscrire le forfait Free dans la console si choisi.
8. Poster un message à la main dans `file_jobs` (`{"modele":"arome","tirage":"…","echeance":0}`), observer journaux et
   alarmes. Le poller et le manifeste viendront ensuite (`activer_*`).

## Coût

Aucune estimation nouvelle ici. Voir `runeride-weather/docs/architecture-aws.md` : §10.6 (lancement, L-A ≈ 0,5 à 0,8 $/mois,
à la condition de rester dans le palier gratuit Lambda), §10.8 (ce qui fait dépasser 1 $), §5.3 (socle ≈ 14 à 25 $ à
8 tirages par jour). Les valeurs par défaut du module (rétention 2 jours, journaux 7 jours, au plus 9 alarmes, pas de WAF
payant) suivent la variante de lancement.

## Risques et réserves

- **Rien n'est validé contre AWS.** Les erreurs probables au premier plan/apply sont celles qu'un validateur statique ne
  voit pas : noms de ressources déjà pris, quotas, permissions de l'utilisateur Terraform, comportement des politiques.
- **Dossiers `_*`** : le refus effectif repose sur le `Deny` du compartiment (joker `*` qui couvre les `/` dans une
  ressource S3). Le comportement CloudFront `*/_*` n'est qu'une première barrière sans cache. À tester (étape 6).
- **CORS et OPTIONS** : les requêtes préalables sont relayées jusqu'à S3 (politique d'origine gérée `CORS-S3Origin`
  + CORS du compartiment) et **ne sont pas mises en cache** (écart avec `architecture-aws.md` §4.3 qui le souhaitait). Les
  GET reçoivent les en-têtes CORS de CloudFront. Non testé avec `pmtiles.js` (envoi éventuel de `If-Match`).
- **Identifiants des politiques gérées** (CachingOptimized, CachingDisabled, CORS-S3Origin) écrits en dur, comme
  `../deploiement`, de mémoire ; une erreur apparaîtrait au plan. Le motif du filtre de journal `"classe":"definitive"`
  est aussi non vérifié sur un vrai journal.
- **Quotas du compte neuf** : vérifier `aws lambda get-account-settings` avant d'activer le manifeste. Avec 10 exécutions au total, `worker_concurrence_max = 10` (défaut) affame poller et manifeste, et toute concurrence réservée est refusée. Concurrence Lambda possiblement basse (la réservation `worker_concurrence_reservee` et
  `manifeste_concurrence_reservee` = 1 peut être refusée si le compte garde moins de 10 exécutions non réservées),
  mémoire possiblement limitée à 3 008 Mo. SES/autres : sans objet ici.
- **Alarmes** : le gratuit est de 10 alarmes **pour le compte**, `../deploiement` en consomme jusqu'à 4 (11 à 13 au total : 1 à 3 payantes, ≈ 0,10 $/mois chacune). Un budget et le
  palier gratuit Lambda ne sont pas un plafond : un budget prévient, il ne bloque rien.
- **Tuiles à 1 an** : une échéance retraitée avec un contenu différent reste en cache un an ; le préfixe est paramétrable
  (`prefixe_cles`, `v1` → `v1r2`), décision ouverte de l'architecture.
- **Expiration** : asynchrone, granularité d'un jour ; le manifeste décide des tirages affichés. Si la rétention
  est modifiée, `manifest.json` et `sante.json` (hors préfixes de modèle) ne sont jamais expirés.
- **Boucle de notification S3** (si `activer_manifeste`) : ne jamais élargir les préfixes de notification à `v1/`.
- **État Terraform** : `backend "s3"` partiel comme `../deploiement` ; le compartiment d'état doit exister.

## Prérequis

- Compte AWS (numéro à douze chiffres), région `eu-north-1` utilisable, droits pour créer S3, CloudFront, ACM (us-east-1),
  SQS, Lambda, IAM, CloudWatch, SNS, Budgets, Scheduler (et WAF/Pricing Plan Manager si forfait).
- Terraform >= 1.10, fournisseur `hashicorp/aws` >= 6.0 (`terraform init` télécharge le fournisseur ; `.terraform.lock.hcl` verrouille 6.69.1).
- Le zip du worker : `runeride-weather/rust/tools/package-lambda.sh` (arm64) ; chemin dans `chemin_zip_worker`.
- Accès à la zone DNS `runeride.fr` chez o2switch (cPanel) pour deux CNAME.
- Une adresse de courriel pour les alertes (variable `alerte_email`, jamais en dur).

## Validation effectuée

```sh
terraform fmt
terraform init -backend=false
terraform validate     # Success! The configuration is valid.
```

Rien d'autre : pas de `plan`, pas d'`apply`, aucun appel AWS, aucun identifiant lu.
