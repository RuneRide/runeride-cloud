# Météo de RuneRide (weather.runeride.fr) : chaîne de traitement et diffusion des tuiles météo sur AWS.
#
#   stockage.tf      compartiment S3 privé des données (tuiles PMTiles, états, manifeste), cycle de vie
#   cloudfront.tf    certificat ACM (us-east-1), distribution weather-data.runeride.fr, OAC, CORS, comportements
#   forfait.tf       forfait CloudFront à tarif fixe (FACULTATIF, désactivé, non validé contre l'API)
#   file.tf          file SQS des tâches (une échéance = un message) et sa file de rebut
#   worker.tf        Lambda « worker » (Rust, arm64, provided.al2023), rôle IAM, journaux, mapping SQS
#   planification.tf Lambdas « poller » et « manifeste » (FACULTATIVES, désactivées par défaut ; code écrit, jamais déployé)
#   alarmes.tf       alarmes CloudWatch (10 au plus, pour rester dans l'offre gratuite) et notifications
#   budget.tf        budget AWS mensuel avec alerte par courriel
#   outputs.tf       sorties, dont les enregistrements DNS à créer chez o2switch
#
# Ce module n'a JAMAIS été appliqué : ni `plan` ni `apply` n'ont été exécutés (voir README.md).
# Comme ../deploiement et ../tuiles : rien ne s'applique sans accord explicite, `terraform plan` d'abord.
# Les secrets ne sont ni ici ni dans l'état. L'adresse de courriel des alertes est une variable.

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
  }
  # Compartiment et clé à donner à l'initialisation, comme pour ../deploiement (un état par environnement) :
  #   terraform init -backend-config="bucket=<compartiment d'état>" -backend-config="key=meteo/<env>.tfstate"
  backend "s3" {
    region       = "eu-north-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region                      = var.region
  access_key                  = var.offline ? "verification" : null
  secret_key                  = var.offline ? "verification" : null
  skip_credentials_validation = var.offline
  skip_metadata_api_check     = var.offline
  skip_requesting_account_id  = var.offline
  default_tags {
    tags = { projet = "runeride", environnement = var.env, composant = "meteo" }
  }
}

# CloudFront ne lit ses certificats que dans la région de Virginie du Nord, et ses métriques n'y sont publiées
# qu'à cet endroit (donc l'alarme sur les erreurs 5xx et son sujet SNS aussi).
provider "aws" {
  alias                       = "virginie"
  region                      = "us-east-1"
  access_key                  = var.offline ? "verification" : null
  secret_key                  = var.offline ? "verification" : null
  skip_credentials_validation = var.offline
  skip_metadata_api_check     = var.offline
  skip_requesting_account_id  = var.offline
  default_tags {
    tags = { projet = "runeride", environnement = var.env, composant = "meteo" }
  }
}

locals {
  name   = "runeride-${var.env}-meteo"
  bucket = "${local.name}-donnees-${var.compte}"

  # préfixe des clés sans barre finale, puis un préfixe par modèle : v1/arome, v1/arome-hd
  prefixe          = trim(var.prefixe_cles, "/")
  prefixes_modeles = [for m in var.modeles : "${local.prefixe}/${m}"]

  # isobares : GeoJSON écrit par le worker sous <v1>/isobares/<modèle>/<tirage>/NN.geojson (hors des préfixes de modèle)
  prefixe_isobares  = "${local.prefixe}/isobares"
  prefixes_ecriture = concat(local.prefixes_modeles, [local.prefixe_isobares])

  # marqueurs d'envoi du poller (jamais servis : « _poller »)
  prefixe_poller = "${local.prefixe}/_poller"

  # fond de carte (envoi manuel, docs/mise-en-production.md §6) : hors du préfixe des données, donc ni expiré ni notifié
  prefixe_fond = trim(var.prefixe_fond, "/")

  # clés écrites hors des préfixes de modèle : jamais expirées par la règle de cycle de vie
  cle_manifeste = "${local.prefixe}/manifest.json"
  cle_sante     = "${local.prefixe}/sante.json"

  # forfait CloudFront à tarif fixe demandé (forfait.tf)
  forfait = var.forfait_cloudfront != null

  # le domaine n'est rattaché à la distribution qu'une fois son certificat validé (DNS hors AWS)
  rattache = var.certificat_valide

  # politiques gérées par AWS, désignées par leur identifiant (stables et publics) : aucune lecture d'API
  # n'est nécessaire, donc un plan à blanc (offline) reste possible, comme dans ../deploiement.
  cache_optimise = "658327ea-f89d-4fab-a63d-7e88639e58f6" # Managed-CachingOptimized
  cache_coupe    = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # Managed-CachingDisabled
  origine_cors   = "88a5eaf4-2fd4-4709-b370-b4c650ea3fcf" # Managed-CORS-S3Origin
}
