# Raido, calculateur de balade à moto de RuneRide (raido.runeride.fr) : moteur Rust sans serveur.
# Spécification : runeride/docs/itineraire.md (§5.2 architecture, §5.5 coûts, §7.2 API) ; code : runeride-carto/rust.
#
#   stockage.tf    compartiment S3 privé du graphe routier (tuiles rkyv + index.json), lu par la seule Lambda
#   fonction.tf    Lambda « calcul » (Rust, arm64, provided.al2023), Function URL (AWS_IAM), rôle, journaux
#   cloudfront.tf  certificat ACM (us-east-1), distribution raido.runeride.fr devant la Function URL (OAC lambda), CORS
#   alarmes.tf     alarmes CloudWatch (3 ou 4) et notifications
#   budget.tf      budget AWS mensuel avec alerte par courriel
#   outputs.tf     sorties, dont les enregistrements DNS à créer chez o2switch et la commande de publication du graphe
#
# Ce module n'a JAMAIS été appliqué : ni `plan` ni `apply` n'ont été exécutés (voir README.md).
# Comme ../meteo, ../tuiles et ../deploiement : rien ne s'applique sans accord explicite, `terraform plan` d'abord.
# Les secrets ne sont ni ici ni dans l'état. L'adresse de courriel des alertes est une variable.

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
  }
  # Compartiment et clé à donner à l'initialisation, comme pour ../meteo (un état par environnement) :
  #   terraform init -backend-config="bucket=<compartiment d'état>" -backend-config="key=raido/<env>.tfstate"
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
    tags = { projet = "runeride", environnement = var.env, composant = "raido" }
  }
}

# CloudFront ne lit ses certificats qu'en Virginie du Nord, et ses métriques n'y sont publiées qu'à cet endroit.
provider "aws" {
  alias                       = "virginie"
  region                      = "us-east-1"
  access_key                  = var.offline ? "verification" : null
  secret_key                  = var.offline ? "verification" : null
  skip_credentials_validation = var.offline
  skip_metadata_api_check     = var.offline
  skip_requesting_account_id  = var.offline
  default_tags {
    tags = { projet = "runeride", environnement = var.env, composant = "raido" }
  }
}

locals {
  name   = "runeride-${var.env}-raido"
  bucket = "${local.name}-graphe-${var.compte}"

  # dossier du graphe servi (RAIDO_PREFIXE) : graphe/courant ; une nouvelle version se publie dans un autre dossier
  # puis la variable change (nouveau déploiement de la fonction, cache /tmp distinct)
  prefixe = trim(var.prefixe_graphe, "/")

  # le domaine n'est rattaché à la distribution qu'une fois son certificat validé (DNS hors AWS)
  rattache = var.certificat_valide

  # politiques gérées par AWS, par identifiant (stables et publics) : aucune lecture d'API, plan à blanc possible
  cache_coupe            = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # Managed-CachingDisabled
  origine_tout_sauf_hote = "b689b0a8-53d0-40ab-baf2-68738e2966ac" # Managed-AllViewerExceptHostHeader (origine Lambda)

  # hôte de la Function URL : https://<id>.lambda-url.<région>.on.aws/
  hote_fonction = replace(replace(aws_lambda_function_url.calcul.function_url, "https://", ""), "/", "")
}
