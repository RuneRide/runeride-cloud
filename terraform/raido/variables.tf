# Variables du module Raido. Les valeurs d'un environnement vont dans un fichier .tfvars
# (voir terraform.tfvars.example). Aucune valeur secrète ici.

# ---------------------------------------------------------------- général

variable "env" {
  description = "Nom de l'environnement : « essai » ou « production » (minuscules et chiffres)."
  type        = string
  default     = "production"
  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,15}$", var.env))
    error_message = "Lettres minuscules et chiffres seulement (2 à 16 caractères, première lettre obligatoire)."
  }
}

variable "compte" {
  description = "Numéro du compte AWS (douze chiffres) : il rend unique le nom du compartiment."
  type        = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.compte))
    error_message = "Douze chiffres attendus."
  }
}

variable "region" {
  description = "Région du compartiment et de la fonction (Stockholm, comme le reste du projet)."
  type        = string
  default     = "eu-north-1"
}

variable "offline" {
  description = "Vérification sans compte AWS (plan à blanc) : aucun identifiant n'est demandé. Même convention que ../meteo."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------- graphe

variable "prefixe_graphe" {
  description = "Dossier du graphe servi dans le compartiment (RAIDO_PREFIXE) : index.json et tuiles/… de raido-graphe. Changer de dossier = changer de version de graphe (nouveau déploiement, cache /tmp distinct)."
  type        = string
  default     = "graphe/courant"
}

# ---------------------------------------------------------------- fonction

variable "chemin_zip" {
  description = "Chemin du zip de la fonction (binaire bootstrap à la racine), produit par runeride-carto/rust/tools/package-lambda.sh (rust/target/lambda/raido-lambda-arm64.zip). Doit exister au moment du plan."
  type        = string
}

variable "memoire_mo" {
  description = "Mémoire de la fonction en Mo. Le calcul tient dans 152 Mo (mesuré, docs/raido.md) : la mémoire sert surtout à acheter des vCPU (1 769 Mo = 1 vCPU, ≈ 3 500 Mo = 2 vCPU) pour paralléliser les pétales ; le coût en Go·s est le même à temps CPU égal."
  type        = number
  default     = 2048
  validation {
    condition     = var.memoire_mo >= 512 && var.memoire_mo <= 10240
    error_message = "Entre 512 et 10 240 Mo."
  }
}

variable "timeout" {
  description = "Délai d'expiration de la fonction en secondes. 29 : CloudFront coupe une origine après 30 s par défaut ; une boucle de 120 km prend 2 à 4 s, 200 km jusqu'à 7 s sur un vCPU."
  type        = number
  default     = 29
  validation {
    condition     = var.timeout >= 3 && var.timeout <= 60
    error_message = "Entre 3 et 60 secondes."
  }
}

variable "ephemere_mo" {
  description = "Stockage éphémère /tmp en Mo (512 à 10 240) : cache des tuiles de graphe entre invocations (RAIDO_CACHE). Rhône-Alpes = 116 Mo ; France entière ≈ 1,5 à 2,5 Go (ESTIMATION). Au-delà de 512 Mo, facturé (faiblement) par Go·s."
  type        = number
  default     = 1024
  validation {
    condition     = var.ephemere_mo >= 512 && var.ephemere_mo <= 10240
    error_message = "Entre 512 et 10 240 Mo."
  }
}

variable "concurrence_reservee" {
  description = "Concurrence réservée de la fonction, qui BORNE le coût (spec §5.2 : 10). -1 : aucune réservation. Sur un compte neuf (quota de 10 exécutions), toute réservation est refusée car AWS impose 10 exécutions non réservées : laisser -1 tant que le quota n'est pas relevé."
  type        = number
  default     = -1
  validation {
    condition     = var.concurrence_reservee == -1 || var.concurrence_reservee >= 1
    error_message = "-1 (aucune) ou un entier positif."
  }
}

variable "fils" {
  description = "Nombre de fils de calcul (RAIDO_THREADS). Vide : autant que de vCPU vus par la fonction."
  type        = string
  default     = ""
}

variable "cle_service" {
  description = <<-EOT
    Clé de service de POST /v1/apparier (appariement des tracés, appelé par le PHP de app.runeride.fr, jamais par le navigateur) :
    variable RAIDO_CLE_SERVICE de la fonction. Vide (défaut) : la route n'existe pas (404) et rien n'est exposé.
    Valeur : au moins 32 caractères aléatoires, passée par TF_VAR_cle_service ou un tfvars hors Git, jamais écrite dans le dépôt ;
    la même valeur va dans RUNERIDE_RAIDO_CLE_SERVICE côté application. Elle se retrouve dans la configuration de la fonction
    (visible de qui peut la lire dans IAM) et dans l'état Terraform (chiffré, accès restreint) : c'est un choix sans coût, Secrets
    Manager coûterait 0,40 $ par mois et par secret. La clé ne donne accès à aucune donnée : elle permet seulement de lancer des
    appariements, donc de consommer du calcul. Rotation : changer la valeur des deux côtés, puis appliquer.
  EOT
  type        = string
  default     = ""
  sensitive   = true
  validation {
    condition     = var.cle_service == "" || length(var.cle_service) >= 32
    error_message = "cle_service : vide (route désactivée) ou au moins 32 caractères."
  }
}

variable "environnement_supplementaire" {
  description = "Variables d'environnement RAIDO_* supplémentaires. Jamais de secret ici."
  type        = map(string)
  default     = {}
}

variable "journaux_retention_jours" {
  description = "Rétention des journaux CloudWatch en jours (1, 3, 5, 7, 14, 30…)."
  type        = number
  default     = 7
}

# ---------------------------------------------------------------- diffusion

variable "domaine" {
  description = "Nom public du service (spec D5)."
  type        = string
  default     = "raido.runeride.fr"
}

# ---------------------------------------------------------------- jeton court (spec §7.1)

variable "jwks_url" {
  description = "JWKS de l'émetteur des jetons courts (classe PHP RuneRide\\Auth\\Jwt). Lu au démarrage de la fonction et à chaque kid inconnu (au plus toutes les 5 minutes)."
  type        = string
  default     = "https://app.runeride.fr/.well-known/jwks.json"
}

variable "jeton_emetteur" {
  description = "Revendication iss attendue : RUNERIDE_BASE_URL du PHP (émetteur de la classe Jwt), sans barre oblique finale."
  type        = string
  default     = "https://app.runeride.fr"
}

variable "jeton_audience" {
  description = "Revendication aud attendue : « raido », distincte de l'audience « runeride » des jetons de session de l'appli, qui sont refusés."
  type        = string
  default     = "raido"
}

variable "origines_autorisees" {
  description = "Origines autorisées à appeler l'API depuis le navigateur (CORS). Pas de joker. Les ports locaux servent au développement de la PWA."
  type        = list(string)
  default = [
    "https://app.runeride.fr",
    "https://runeride.fr",
    "http://localhost:8080",
    "http://127.0.0.1:8080",
  ]
}

variable "certificat_valide" {
  description = "Passer à true une fois le CNAME de validation du certificat créé chez o2switch et le certificat émis : le domaine est alors rattaché à la distribution."
  type        = bool
  default     = false
}

variable "classe_prix" {
  description = "Classe de prix CloudFront. PriceClass_100 : Europe et Amérique du Nord."
  type        = string
  default     = "PriceClass_100"
}

# ---------------------------------------------------------------- alertes et budget

variable "alerte_email" {
  description = "Adresse prévenue par les alarmes CloudWatch et par le budget. Vide : ni budget ni abonnement."
  type        = string
  default     = ""
}

variable "budget_usd" {
  description = "Plafond de dépense mensuelle surveillé, en dollars (spec §5.5 : 5). Un budget prévient mais ne plafonne pas ; la concurrence réservée plafonne."
  type        = number
  default     = 5
}

variable "alarmes_actives" {
  description = "Crée les alarmes CloudWatch (3, 4 avec alarme_cloudfront). Le compte entier a droit à 10 alarmes standard gratuites, partagées avec ../meteo et ../deploiement."
  type        = bool
  default     = true
}

variable "alarme_cloudfront" {
  description = "Crée l'alarme CloudFront 5xx et son sujet SNS en us-east-1 (à laisser à false si une politique du compte interdit SNS hors eu-north-1, constaté sur ../meteo)."
  type        = bool
  default     = false
}
