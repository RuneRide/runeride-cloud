# File des tâches : un message = une échéance d'un modèle, {"modele": "arome-hd", "tirage": "2026-10-17T03:00:00Z",
# "echeance": 12} (docs/poc-rust/lambda.md §2), postée par le poller. File standard, au moins une livraison :
# le worker est idempotent (clés déterministes, état d'échéance dans S3).

resource "aws_sqs_queue" "jobs_rebut" {
  name                      = "${local.name}-jobs-rebut"
  message_retention_seconds = 1209600 # 14 jours pour comprendre un échec
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "jobs" {
  name = "${local.name}-jobs"

  # Au moins 6 fois le délai du worker (recommandation AWS pour SQS + Lambda), jamais moins de 720 s :
  # c'est aussi la cadence de rejeu d'un 404 (fichier non encore publié chez Météo-France).
  visibility_timeout_seconds = max(720, 6 * var.worker_timeout)
  message_retention_seconds  = var.file_retention_secondes
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.jobs_rebut.arn
    maxReceiveCount     = var.file_reception_max
  })
}

# Seule cette file peut déverser dans la file de rebut.
resource "aws_sqs_queue_redrive_allow_policy" "jobs_rebut" {
  queue_url = aws_sqs_queue.jobs_rebut.id
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.jobs.arn]
  })
}
