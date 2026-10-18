# Poller et manifeste : ressources FACULTATIVES, DÉSACTIVÉES par défaut (activer_poller / activer_manifeste).
#
# Le code des deux Lambdas existe (rust/crates/rw-poller et rw-manifeste du dépôt runeride-weather, testés en local avec
# de faux S3/SQS, jamais sur AWS : docs/poc-rust/poller-manifeste.md). Droits IAM et variables d'environnement ci-dessous
# ont été relus contre ce code (opérations S3/SQS réellement émises, variables réellement lues), pas contre AWS.
# Zips : rust/tools/package-lambda.sh arm64 tout -> rw-poller-arm64.zip et rw-manifeste-arm64.zip.

# ================================================================ POLLER
# EventBridge Scheduler (toutes les 5 min) -> Lambda « poller » : liste le S3 de Météo-France (OVH), compare avec
# l'état (_etat/NN.json dans notre compartiment), poste un message par échéance prête dans la file des tâches,
# et tient un marqueur par tirage (<v1>/_poller/<modèle>/<tirage>.json). Il n'écrit PAS sante.json (poller-manifeste.md
# §8, point 8). Message attendu par le worker :
# {"modele": "arome-hd", "tirage": "2026-10-17T03:00:00Z", "echeance": 12}.

resource "aws_cloudwatch_log_group" "poller" {
  count             = var.activer_poller ? 1 : 0
  name              = "/aws/lambda/${local.name}-poller"
  retention_in_days = var.journaux_retention_jours
}

resource "aws_iam_role" "poller" {
  count              = var.activer_poller ? 1 : 0
  name               = "${local.name}-poller"
  assume_role_policy = data.aws_iam_policy_document.lambda_confiance.json
}

# Relu contre rw-poller : SendMessageBatch (= sqs:SendMessage) ; listage et lecture de <v1>/<modèle>/<tirage>/_etat/ ;
# lecture ET écriture du marqueur <v1>/_poller/<modèle>/<tirage>.json (pas de suppression : le cycle de vie s'en charge).
# La lecture d'un marqueur absent exige s3:ListBucket (sinon 403 au lieu de 404 : le passage échouerait à chaque fois).
data "aws_iam_policy_document" "poller" {
  count = var.activer_poller ? 1 : 0

  statement {
    sid       = "PosterLesTaches"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.jobs.arn]
  }
  statement {
    sid       = "LireLEtat"
    actions   = ["s3:GetObject"]
    resources = [for p in local.prefixes_modeles : "${aws_s3_bucket.donnees.arn}/${p}/*"]
  }
  statement {
    sid       = "ListerLEtat"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.donnees.arn]
  }
  statement {
    sid       = "Marqueurs"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["${aws_s3_bucket.donnees.arn}/${local.prefixe_poller}/*"]
  }
  statement {
    sid       = "Journaux"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.poller[0].arn}:*"]
  }
}

resource "aws_iam_role_policy" "poller" {
  count  = var.activer_poller ? 1 : 0
  name   = "poller"
  role   = aws_iam_role.poller[0].id
  policy = data.aws_iam_policy_document.poller[0].json
}

resource "aws_lambda_function" "poller" {
  count         = var.activer_poller ? 1 : 0
  function_name = "${local.name}-poller"
  role          = aws_iam_role.poller[0].arn
  runtime       = "provided.al2023"
  architectures = ["arm64"]
  handler       = "bootstrap"

  filename         = var.chemin_zip_poller
  source_code_hash = filebase64sha256(var.chemin_zip_poller)
  memory_size      = var.poller_memoire_mo
  timeout          = var.poller_timeout

  environment {
    variables = merge(
      {
        RW_BUCKET  = aws_s3_bucket.donnees.id
        RW_PREFIXE = local.prefixe
        RW_SQS_URL = aws_sqs_queue.jobs.url
        # Un tirage plus vieux que cet âge n'est plus traité : il doit rester inférieur à la durée de vie des objets
        # (cycle de vie, + 2 à 6 h de production après l'heure nominale). 36 h pour 2 jours.
        RW_AGE_MAX_H = tostring(var.retention_jours * 24 - 12)
      },
      var.poller_environnement,
    )
  }

  depends_on = [aws_cloudwatch_log_group.poller, aws_iam_role_policy.poller]

  lifecycle {
    precondition {
      condition     = var.chemin_zip_poller != null
      error_message = "activer_poller exige chemin_zip_poller."
    }
  }
}

# Rôle que le Scheduler endosse pour invoquer le poller.
data "aws_iam_policy_document" "scheduler_confiance" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.compte]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  count              = var.activer_poller ? 1 : 0
  name               = "${local.name}-scheduler"
  assume_role_policy = data.aws_iam_policy_document.scheduler_confiance.json
}

resource "aws_iam_role_policy" "scheduler" {
  count = var.activer_poller ? 1 : 0
  name  = "invoquer-le-poller"
  role  = aws_iam_role.scheduler[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = aws_lambda_function.poller[0].arn
    }]
  })
}

# 14 millions d'invocations par mois gratuites (architecture-aws.md §10.1).
resource "aws_scheduler_schedule" "poller" {
  count       = var.activer_poller ? 1 : 0
  name        = "${local.name}-poller"
  description = "Sondage du stockage de Meteo-France et mise en file des echeances pretes"

  schedule_expression = var.poller_cadence
  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.poller[0].arn
    role_arn = aws_iam_role.scheduler[0].arn
    input    = jsonencode({}) # évènement statique explicite (le poller lit « simulation » et « maintenant », absents ici)
    retry_policy {
      maximum_retry_attempts       = 0 # le poller est à déclenchement par niveau : le passage suivant rattrape
      maximum_event_age_in_seconds = 60
    }
  }
}

# ================================================================ MANIFESTE
# S3 (événements _etat/*.json) -> SQS « manifeste » -> Lambda « manifeste » à concurrence réservée 1, fenêtre de lot
# de 20 s. Elle agrège les états d'échéance et écrit manifest.json EN DERNIER (docs/poc-rust/lambda.md §7).
#
# PIÈGE DE BOUCLE : la notification est limitée au préfixe de CHAQUE MODÈLE (v1/arome/, v1/arome-hd/) avec le suffixe
# .json. manifest.json et sante.json sont écrits à la racine du préfixe général : ils ne déclenchent pas la fonction.
# Ne jamais élargir ces préfixes à v1/ (boucle infinie et facture). Le suffixe ne peut pas viser « /_etat/ » seul :
# S3 n'accepte qu'un préfixe et un suffixe ; les autres .json des modèles sont inexistants à ce jour.

resource "aws_sqs_queue" "manifeste_rebut" {
  count                     = var.activer_manifeste ? 1 : 0
  name                      = "${local.name}-manifeste-rebut"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "manifeste" {
  count                      = var.activer_manifeste ? 1 : 0
  name                       = "${local.name}-manifeste"
  visibility_timeout_seconds = max(720, 6 * var.manifeste_timeout)
  sqs_managed_sse_enabled    = true
  # Au moins 10 réceptions (poller-manifeste.md §5.7) : avec une concurrence réservée de 1, les invocations limitées
  # (Throttles) rendent les messages à la file en consommant des réceptions, sans qu'il y ait de vraie erreur.
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.manifeste_rebut[0].arn
    maxReceiveCount     = max(10, var.file_reception_max)
  })
}

# Seul ce compartiment peut envoyer ses événements dans la file (architecture-aws.md §6).
data "aws_iam_policy_document" "manifeste_file" {
  count = var.activer_manifeste ? 1 : 0
  statement {
    sid       = "EvenementsS3"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.manifeste[0].arn]
    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_s3_bucket.donnees.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.compte]
    }
  }
}

resource "aws_sqs_queue_policy" "manifeste" {
  count     = var.activer_manifeste ? 1 : 0
  queue_url = aws_sqs_queue.manifeste[0].id
  policy    = data.aws_iam_policy_document.manifeste_file[0].json
}

resource "aws_s3_bucket_notification" "manifeste" {
  count  = var.activer_manifeste ? 1 : 0
  bucket = aws_s3_bucket.donnees.id

  dynamic "queue" {
    for_each = toset(var.modeles)
    content {
      id            = "etat-${queue.value}"
      queue_arn     = aws_sqs_queue.manifeste[0].arn
      events        = ["s3:ObjectCreated:*"]
      filter_prefix = "${local.prefixe}/${queue.value}/"
      filter_suffix = ".json"
    }
  }

  depends_on = [aws_sqs_queue_policy.manifeste]
}

resource "aws_cloudwatch_log_group" "manifeste" {
  count             = var.activer_manifeste ? 1 : 0
  name              = "/aws/lambda/${local.name}-manifeste"
  retention_in_days = var.journaux_retention_jours
}

resource "aws_iam_role" "manifeste" {
  count              = var.activer_manifeste ? 1 : 0
  name               = "${local.name}-manifeste"
  assume_role_policy = data.aws_iam_policy_document.lambda_confiance.json
}

# Relu contre rw-manifeste : listage de <v1>/<modèle>/ (tirages) et de .../_etat/ ; lecture des états et de _domaine/NN.npz
# (sous les préfixes de modèle) ; LECTURE de manifest.json (comparaison avec l'ancien : sans ce droit, 403 à chaque
# reconstruction) ; écriture de manifest.json. Pas de suppression : la purge (RW_PURGE_AGE_H) est désactivée par défaut ;
# l'activer exigerait s3:DeleteObject sur les préfixes de modèle, <v1>/isobares/ et <v1>/_poller/.
data "aws_iam_policy_document" "manifeste" {
  count = var.activer_manifeste ? 1 : 0

  statement {
    sid       = "LireLaFileDEvenements"
    actions   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
    resources = [aws_sqs_queue.manifeste[0].arn]
  }
  statement {
    sid       = "ListerLesTirages"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.donnees.arn]
  }
  statement {
    sid       = "LireLesEtats"
    actions   = ["s3:GetObject"]
    resources = [for p in local.prefixes_modeles : "${aws_s3_bucket.donnees.arn}/${p}/*"]
  }
  statement {
    sid       = "LireLeManifeste"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.donnees.arn}/${local.cle_manifeste}"]
  }
  statement {
    sid       = "EcrireLeManifeste"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.donnees.arn}/${local.cle_manifeste}"]
  }
  statement {
    sid       = "Journaux"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.manifeste[0].arn}:*"]
  }
}

resource "aws_iam_role_policy" "manifeste" {
  count  = var.activer_manifeste ? 1 : 0
  name   = "manifeste"
  role   = aws_iam_role.manifeste[0].id
  policy = data.aws_iam_policy_document.manifeste[0].json
}

resource "aws_lambda_function" "manifeste" {
  count         = var.activer_manifeste ? 1 : 0
  function_name = "${local.name}-manifeste"
  role          = aws_iam_role.manifeste[0].arn
  runtime       = "provided.al2023"
  architectures = ["arm64"]
  handler       = "bootstrap"

  filename         = var.chemin_zip_manifeste
  source_code_hash = filebase64sha256(var.chemin_zip_manifeste)
  memory_size      = var.manifeste_memoire_mo
  timeout          = var.manifeste_timeout

  # Concurrence réservée 1 : jamais deux écritures simultanées du manifeste.
  reserved_concurrent_executions = var.manifeste_concurrence_reservee

  environment {
    variables = merge(
      {
        RW_BUCKET  = aws_s3_bucket.donnees.id
        RW_PREFIXE = local.prefixe
        # Âge maximal d'un tirage cité : inférieur à la durée de vie des objets (le manifeste ne cite jamais un
        # fichier expiré). Expiration S3 = création + retention_jours, arrondie à minuit UTC suivant, objets écrits de
        # +2 à +6 h après l'heure nominale : 42 h pour 2 jours (poller 36 h < manifeste 42 h < expiration >= 50 h).
        RW_AGE_REF_H = tostring(var.retention_jours * 24 - 6)
      },
      var.manifeste_environnement,
    )
  }

  depends_on = [aws_cloudwatch_log_group.manifeste, aws_iam_role_policy.manifeste]

  lifecycle {
    precondition {
      condition     = var.chemin_zip_manifeste != null
      error_message = "activer_manifeste exige chemin_zip_manifeste."
    }
  }
}

resource "aws_lambda_event_source_mapping" "manifeste" {
  count                              = var.activer_manifeste ? 1 : 0
  event_source_arn                   = aws_sqs_queue.manifeste[0].arn
  function_name                      = aws_lambda_function.manifeste[0].arn
  batch_size                         = 100
  maximum_batching_window_in_seconds = var.manifeste_fenetre_lot_secondes
  function_response_types            = ["ReportBatchItemFailures"]

  depends_on = [aws_iam_role_policy.manifeste]
}
