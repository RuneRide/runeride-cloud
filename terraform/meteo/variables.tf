# Variables du module météo. Les valeurs d'un environnement vont dans un fichier .tfvars
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
  description = "Numéro du compte AWS (douze chiffres) : il rend unique le nom du compartiment et sert aux ARN."
  type        = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.compte))
    error_message = "Douze chiffres attendus."
  }
}

variable "region" {
  description = "Région du compartiment S3, des files et des fonctions (Stockholm, comme le reste du projet)."
  type        = string
  default     = "eu-north-1"
}

variable "offline" {
  description = "Vérification sans compte AWS (plan à blanc) : aucun identifiant n'est demandé. Même convention que ../deploiement."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------- stockage et clés

variable "prefixe_cles" {
  description = "Préfixe de toutes les clés S3 (RW_PREFIXE du worker). Peut porter une révision du pipeline (v1, v1r2) pour contourner l'immuabilité d'un an."
  type        = string
  default     = "v1"
}

variable "prefixe_fond" {
  description = "Préfixe du fond de carte PMTiles (envoi manuel), servi par CloudFront comme les données mais hors de v1/ : aucune règle d'expiration ne le touche."
  type        = string
  default     = "basemap"
}

variable "modeles" {
  description = "Modèles météo, un préfixe de clé chacun sous le préfixe général. Servent aux droits IAM du worker et aux règles d'expiration (le manifeste et sante.json, hors de ces préfixes, ne sont jamais expirés)."
  type        = list(string)
  default     = ["arome", "arome-hd"]
}

variable "retention_jours" {
  description = "Âge (jours, minimum 1) auquel expirent les objets de tirage. 2 jours = 16 tirages de 8 par jour (voir docs/architecture-aws.md §2.3 et §10.3 du dépôt runeride-weather). Le manifeste décide quels tirages sont affichés."
  type        = number
  default     = 2
  validation {
    condition     = var.retention_jours >= 1 && var.retention_jours == floor(var.retention_jours)
    error_message = "Un nombre entier de jours, au moins 1."
  }
}

variable "purge_multipart_jours" {
  description = "Délai (jours) après lequel un envoi multipart abandonné est purgé. Il reste facturé tant que ses morceaux existent."
  type        = number
  default     = 1
}

# ---------------------------------------------------------------- diffusion

variable "domaine" {
  description = "Nom public des données météo, seul domaine derrière CloudFront (docs/architecture-aws.md §4.3)."
  type        = string
  default     = "weather-data.runeride.fr"
}

variable "origines_autorisees" {
  description = "Origines autorisées à lire les données depuis le navigateur (CORS). Pas de joker. Le port 8187 est celui du viewer local du dépôt runeride-weather."
  type        = list(string)
  default = [
    "https://weather.runeride.fr",
    "http://localhost:8187",
    "http://127.0.0.1:8187",
  ]
}

variable "certificat_valide" {
  description = "Passer à true une fois le CNAME de validation du certificat créé chez o2switch et le certificat émis : le domaine est alors rattaché à la distribution (l'application attend la validation)."
  type        = bool
  default     = false
}

variable "classe_prix" {
  description = "Classe de prix CloudFront. PriceClass_100 : Europe et Amérique du Nord, suffisant pour une audience française."
  type        = string
  default     = "PriceClass_100"
}

variable "ttl_manifeste_defaut" {
  description = "Durée de cache (secondes) du manifeste et de sante.json si l'origine n'envoie pas de Cache-Control. Le worker pose max-age=30 à l'écriture."
  type        = number
  default     = 30
}

variable "ttl_manifeste_max" {
  description = "Durée maximale (secondes) du cache du manifeste et de sante.json, même si l'origine demande plus."
  type        = number
  default     = 60
}

# ---------------------------------------------------------------- file et worker

variable "chemin_zip_worker" {
  description = "Chemin du zip du worker (binaire bootstrap à la racine), produit par rust/tools/package-lambda.sh du dépôt runeride-weather (rust/target/lambda/rw-lambda-arm64.zip). Doit exister au moment du plan."
  type        = string
}

variable "worker_memoire_mo" {
  description = "Mémoire du worker en Mo. 1 769 Mo = 1 vCPU. Pic mesuré 616 Mo en HD (docs/poc-rust/lambda.md §10.2, test réel du 18/10/2026). Un compte neuf peut être limité à 3 008 Mo."
  type        = number
  default     = 1769
  validation {
    condition     = var.worker_memoire_mo >= 128 && var.worker_memoire_mo <= 10240
    error_message = "Entre 128 et 10 240 Mo."
  }
}

variable "worker_timeout" {
  description = "Délai d'expiration du worker, en secondes (durée attendue 3 à 15 s, 120 s de marge pour la lenteur de la source)."
  type        = number
  default     = 120
  validation {
    condition     = var.worker_timeout >= 1 && var.worker_timeout <= 900
    error_message = "Entre 1 et 900 secondes."
  }
}

variable "worker_ephemere_mo" {
  description = "Stockage éphémère /tmp du worker en Mo (512 à 10 240). Le worker travaille en mémoire : 512 suffit."
  type        = number
  default     = 512
  validation {
    condition     = var.worker_ephemere_mo >= 512 && var.worker_ephemere_mo <= 10240
    error_message = "Entre 512 et 10 240 Mo."
  }
}

variable "worker_concurrence_max" {
  description = "Concurrence maximale du mapping SQS vers le worker (ScalingConfig.MaximumConcurrency, minimum 2). Borne aussi la charge sur OVH : concurrence × RW_CONNEXIONS connexions. ATTENTION au quota du compte : avec 10 exécutions simultanées au total, 10 ici laissent le poller et le manifeste sans exécution (Throttles) pendant qu'un tirage se traite ; en dessous de 10, laisser de la marge ou relever le quota."
  type        = number
  default     = 10
  validation {
    condition     = var.worker_concurrence_max >= 2 && var.worker_concurrence_max <= 1000
    error_message = "Entre 2 et 1 000."
  }
}

variable "worker_concurrence_reservee" {
  description = "Concurrence réservée de la fonction worker. -1 : aucune réservation (défaut AWS). Si renseignée, elle doit être supérieure à worker_concurrence_max ; sur un compte neuf (quota bas) une réservation peut être refusée car AWS impose 10 exécutions non réservées au compte."
  type        = number
  default     = -1
  validation {
    condition     = var.worker_concurrence_reservee == -1 || var.worker_concurrence_reservee >= 0
    error_message = "-1 (aucune) ou un entier positif."
  }
}

variable "mapping_actif" {
  description = "Active le mapping SQS vers le worker. À false, tout est créé mais la file n'est pas consommée (utile pour déployer avant que le zip soit prêt)."
  type        = bool
  default     = true
}

variable "source_grib" {
  description = "Base HTTP des fichiers GRIB (RW_SOURCE). Stockage public de Météo-France chez OVH."
  type        = string
  default     = "https://meteofrance-pnt.s3.rbx.io.cloud.ovh.net/pnt"
}

variable "worker_connexions_source" {
  description = "Téléchargements simultanés par invocation (RW_CONNEXIONS). 3 : limite courtoise envers OVH."
  type        = number
  default     = 3
}

variable "profil_tuilage" {
  description = "Profil de tuilage du worker (RW_PROFIL) : reduit2, reduit2-ete ou reduit2-hiver."
  type        = string
  default     = "reduit2"
}

variable "worker_environnement_supplementaire" {
  description = "Variables d'environnement RW_* supplémentaires du worker (par exemple RW_DEFINITIF = \"rejouer\"). Elles complètent, sans les remplacer, RW_BUCKET, RW_PREFIXE, RW_SOURCE, RW_CONNEXIONS et RW_PROFIL. Jamais de secret ici."
  type        = map(string)
  default     = {}
}

variable "file_reception_max" {
  description = "Nombre de réceptions d'un message avant son envoi dans la file de rebut (maxReceiveCount). Les 404 de fichiers non encore publiés consomment des réceptions."
  type        = number
  default     = 5
}

variable "file_retention_secondes" {
  description = "Durée de conservation d'un message dans la file des tâches (4 jours par défaut)."
  type        = number
  default     = 345600
}

variable "journaux_retention_jours" {
  description = "Rétention des journaux CloudWatch en jours (valeur acceptée par CloudWatch : 1, 3, 5, 7, 14, 30…). 7 jours : docs/architecture-aws.md §10.5."
  type        = number
  default     = 7
}

# ---------------------------------------------------------------- poller et manifeste (facultatifs, non écrits)

variable "activer_poller" {
  description = "Crée la Lambda « poller » (liste le S3 de Météo-France, poste les messages dans la file) et sa tâche EventBridge Scheduler. DÉSACTIVÉ par défaut : à activer une fois le worker vérifié à la main. Exige chemin_zip_poller."
  type        = bool
  default     = false
}

variable "chemin_zip_poller" {
  description = "Chemin du zip du poller (bootstrap à la racine, arm64). Utilisé seulement avec activer_poller."
  type        = string
  default     = null
}

variable "poller_cadence" {
  description = "Expression EventBridge Scheduler du poller (rate(...) ou cron(...)). 5 minutes : docs/architecture-aws.md §3.1 (« toutes les 2 à 5 min »)."
  type        = string
  default     = "rate(5 minutes)"
}

variable "poller_memoire_mo" {
  description = "Mémoire du poller en Mo (256 suffit : 1 à 2 s par passage)."
  type        = number
  default     = 256
}

variable "poller_timeout" {
  description = "Délai d'expiration du poller en secondes."
  type        = number
  default     = 60
}

variable "poller_environnement" {
  description = "Variables d'environnement RW_* supplémentaires du poller (liste : docs/poc-rust/poller-manifeste.md §3.3, ex. RW_TIRAGES_HEURES = \"00,03,06,09,12,15,18,21\" pour 8 tirages par jour). RW_BUCKET, RW_PREFIXE, RW_SQS_URL et RW_AGE_MAX_H sont ajoutées automatiquement. Jamais de secret ici."
  type        = map(string)
  default     = {}
}

variable "activer_manifeste" {
  description = "Crée la Lambda « manifeste » (agrège les états d'échéance en manifest.json, écrit en dernier), sa file d'événements S3 et le mapping. DÉSACTIVÉ par défaut. Exige chemin_zip_manifeste."
  type        = bool
  default     = false
}

variable "chemin_zip_manifeste" {
  description = "Chemin du zip de la Lambda manifeste (bootstrap à la racine, arm64). Utilisé seulement avec activer_manifeste."
  type        = string
  default     = null
}

variable "manifeste_memoire_mo" {
  description = "Mémoire de la Lambda manifeste en Mo."
  type        = number
  default     = 512
}

variable "manifeste_timeout" {
  description = "Délai d'expiration de la Lambda manifeste en secondes."
  type        = number
  default     = 60
}

variable "manifeste_fenetre_lot_secondes" {
  description = "Fenêtre de regroupement des événements S3 avant l'invocation de la Lambda manifeste (20 s : docs/architecture-aws.md §3.1)."
  type        = number
  default     = 20
}

variable "manifeste_concurrence_reservee" {
  description = "Concurrence réservée de la Lambda manifeste : 1 pour qu'il n'y ait jamais deux écritures simultanées du manifeste. -1 la supprime (à éviter hors essai : deux reconstructions simultanées pourraient s'écraser). AWS impose 10 exécutions NON réservées au compte : avec le quota initial de 10 (vérifier : aws lambda get-account-settings), toute réservation est refusée (apply en erreur) tant que le quota n'est pas relevé par une demande au support."
  type        = number
  default     = 1
}

variable "manifeste_environnement" {
  description = "Variables d'environnement RW_* supplémentaires de la Lambda manifeste (liste : docs/poc-rust/poller-manifeste.md §5.5). RW_BUCKET, RW_PREFIXE et RW_AGE_REF_H sont ajoutées automatiquement. Jamais de secret ici."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------- alertes et budget

variable "alerte_email" {
  description = "Adresse prévenue par les alarmes CloudWatch et par le budget. Vide : ni budget ni abonnement (les alarmes existent mais ne notifient personne). Les abonnements SNS demandent une confirmation par courriel."
  type        = string
  default     = ""
}

variable "budget_usd" {
  description = "Plafond de dépense mensuelle surveillé, en dollars (1 $ : cible de lancement, docs/architecture-aws.md §10). Un budget prévient mais ne plafonne pas."
  type        = number
  default     = 1
}

variable "alarmes_actives" {
  description = "Crée les alarmes CloudWatch. Le compte entier a droit à 10 alarmes standard gratuites : ce module en crée 7 au minimum et 9 au plus."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------- forfait CloudFront (facultatif)

variable "forfait_cloudfront" {
  description = "Forfait CloudFront à tarif fixe : FREE, PRO, BUSINESS ou PREMIUM. Null (défaut) : distribution à l'usage, forfait à souscrire dans la console. Crée aussi une ACL WAF (exigée par le forfait) et souscrit via aws_pricingplanmanager_subscription. Non validé contre l'API réelle (voir README.md)."
  type        = string
  default     = null
  validation {
    condition     = var.forfait_cloudfront == null || contains(["FREE", "PRO", "BUSINESS", "PREMIUM"], coalesce(var.forfait_cloudfront, "-"))
    error_message = "FREE, PRO, BUSINESS, PREMIUM ou null."
  }
}

variable "forfait_limite_debit_ip" {
  description = "Avec un forfait : nombre maximal de requêtes par adresse IP sur 5 minutes avant blocage (règle WAF à débit limité, minimum 10). Null : aucune règle (ACL vide, autorise tout). Dépend de ce que le forfait inclut : à vérifier."
  type        = number
  default     = null
}

variable "alarme_cloudfront" {
  description = "Crée l'alarme CloudFront (5xx) et son sujet SNS en us-east-1. À laisser à false si une politique de contrôle de service du compte interdit SNS hors eu-north-1 (constaté à la première application : AuthorizationError sur SNS:CreateTopic en us-east-1)."
  type        = bool
  default     = false
}
