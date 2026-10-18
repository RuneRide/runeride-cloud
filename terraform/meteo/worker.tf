# Lambda « worker » : une échéance par message SQS (binaire Rust rw-lambda, docs/poc-rust/lambda.md).
# arm64, provided.al2023, hors VPC (pas de NAT : les GRIB viennent d'OVH, sur Internet).

resource "aws_cloudwatch_log_group" "worker" {
  name              = "/aws/lambda/${local.name}-worker"
  retention_in_days = var.journaux_retention_jours
}

data "aws_iam_policy_document" "lambda_confiance" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "worker" {
  name               = "${local.name}-worker"
  assume_role_policy = data.aws_iam_policy_document.lambda_confiance.json
}

# Politique d'exemple de docs/poc-rust/lambda.md §10.1. Pas de s3:DeleteObject, pas de DynamoDB (l'état est dans S3).
data "aws_iam_policy_document" "worker" {
  statement {
    sid       = "LireLaFileDesTaches"
    actions   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
    resources = [aws_sqs_queue.jobs.arn]
  }

  # GetObject couvre aussi HeadObject (idempotence : lecture de _etat/NN.json et taille des fichiers).
  statement {
    sid       = "EcrireEtRelireLesSorties"
    actions   = ["s3:PutObject", "s3:GetObject"]
    resources = [for p in local.prefixes_ecriture : "${aws_s3_bucket.donnees.arn}/${p}/*"]
  }

  # Sert seulement à ce que S3 réponde 404 (absent) au lieu de 403. Non restreint par préfixe : la condition
  # s3:prefix n'a pas été vérifiée pour ce contrôle (lambda.md §10.1).
  statement {
    sid       = "DistinguerAbsentEtInterdit"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.donnees.arn]
  }

  # logs:CreateLogGroup volontairement omis : le groupe est créé ici, avec sa rétention.
  statement {
    sid       = "Journaux"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.worker.arn}:*"]
  }
}

resource "aws_iam_role_policy" "worker" {
  name   = "worker"
  role   = aws_iam_role.worker.id
  policy = data.aws_iam_policy_document.worker.json
}

resource "aws_lambda_function" "worker" {
  function_name = "${local.name}-worker"
  role          = aws_iam_role.worker.arn
  runtime       = "provided.al2023"
  architectures = ["arm64"]
  handler       = "bootstrap" # sans objet pour provided.al2023, valeur conventionnelle

  filename         = var.chemin_zip_worker
  source_code_hash = filebase64sha256(var.chemin_zip_worker)

  memory_size = var.worker_memoire_mo
  timeout     = var.worker_timeout
  # -1 : aucune réservation
  reserved_concurrent_executions = var.worker_concurrence_reservee

  ephemeral_storage {
    size = var.worker_ephemere_mo
  }

  # Variables de docs/poc-rust/lambda.md §4. AWS_REGION et les identifiants sont fournis par Lambda.
  environment {
    variables = merge(
      {
        RW_BUCKET     = aws_s3_bucket.donnees.id
        RW_PREFIXE    = local.prefixe
        RW_SOURCE     = var.source_grib
        RW_CONNEXIONS = tostring(var.worker_connexions_source)
        RW_PROFIL     = var.profil_tuilage
      },
      var.worker_environnement_supplementaire,
    )
  }

  depends_on = [aws_cloudwatch_log_group.worker, aws_iam_role_policy.worker]

  lifecycle {
    precondition {
      condition     = var.worker_concurrence_reservee == -1 || var.worker_concurrence_reservee > var.worker_concurrence_max
      error_message = "La concurrence réservée du worker doit être supérieure à sa concurrence maximale (mapping SQS), ou valoir -1."
    }
  }
}

# Mapping SQS : lot de 1, réponses partielles de lot (sans ReportBatchItemFailures un lot « réussi » est supprimé
# en entier), concurrence maximale plafonnée.
resource "aws_lambda_event_source_mapping" "worker" {
  event_source_arn        = aws_sqs_queue.jobs.arn
  function_name           = aws_lambda_function.worker.arn
  batch_size              = 1
  function_response_types = ["ReportBatchItemFailures"]
  enabled                 = var.mapping_actif

  scaling_config {
    maximum_concurrency = var.worker_concurrence_max
  }

  depends_on = [aws_iam_role_policy.worker]
}

# Les erreurs définitives sont acquittées (pas de rejeu) : leur seule trace est le journal ("classe":"definitive").
# Ce filtre en fait une métrique (une des 10 métriques personnalisées gratuites) pour l'alarme de alarmes.tf.
# Le motif suppose le texte exact "classe":"definitive" dans la ligne de journal [non vérifié sur un vrai journal].
resource "aws_cloudwatch_log_metric_filter" "definitives" {
  name           = "${local.name}-erreurs-definitives"
  log_group_name = aws_cloudwatch_log_group.worker.name
  pattern        = "\"\\\"classe\\\":\\\"definitive\\\"\""

  metric_transformation {
    name          = "ErreursDefinitives"
    namespace     = "RuneRide/Meteo"
    value         = "1"
    default_value = "0"
  }
}
