# Alarmes CloudWatch : 7 au minimum, 9 au plus (poller et manifeste en plus s'ils sont activés), pour rester sous les
# 10 alarmes standard gratuites (architecture-aws.md §10.1). ATTENTION : ce quota est celui du COMPTE ENTIER ; les
# alarmes d'autres modules comptent dans les mêmes 10 : ../deploiement en crée jusqu'à 4 (erreurs du service et des
# échéances si alerte_email, file-remplie et file-vide du worker si worker = true, qui est le défaut), donc 11 à 13 au
# total avec ce module : 1 à 3 alarmes payantes (0,10 $ chacune par mois ; l'alarme file-vide est une expression
# métrique, facturée par métrique). `alarmes_actives = false` ou fusionner des alarmes si 1 $/mois est la cible. Chaque alarme en plus : 0,10 $/mois.
# Aucune alarme « âge du dernier tirage » : elle exige une métrique du poller, qui n'existe pas encore.

locals {
  alarmes  = var.alarmes_actives
  notifier = var.alerte_email != ""
}

# Alarmes de la région du projet : sujet SNS en eu-north-1.
resource "aws_sns_topic" "alertes" {
  count = local.notifier ? 1 : 0
  name  = "${local.name}-alertes"
}

# Abonnement par courriel : demande une confirmation par lien (dans le courriel reçu à la création).
resource "aws_sns_topic_subscription" "alertes" {
  count     = local.notifier ? 1 : 0
  topic_arn = aws_sns_topic.alertes[0].arn
  protocol  = "email"
  endpoint  = var.alerte_email
}

# Les métriques CloudFront n'existent qu'en us-east-1 et une alarme ne peut notifier qu'un sujet de sa région.
resource "aws_sns_topic" "alertes_virginie" {
  count    = local.notifier && var.alarme_cloudfront ? 1 : 0
  provider = aws.virginie
  name     = "${local.name}-alertes"
}

resource "aws_sns_topic_subscription" "alertes_virginie" {
  count     = local.notifier && var.alarme_cloudfront ? 1 : 0
  provider  = aws.virginie
  topic_arn = aws_sns_topic.alertes_virginie[0].arn
  protocol  = "email"
  endpoint  = var.alerte_email
}

locals {
  actions          = local.notifier ? [aws_sns_topic.alertes[0].arn] : []
  actions_virginie = local.notifier && var.alarme_cloudfront ? [aws_sns_topic.alertes_virginie[0].arn] : []
}

# 1. File de rebut non vide : un message a échoué var.file_reception_max fois (404 persistant, 403 S3…).
resource "aws_cloudwatch_metric_alarm" "rebut_non_vide" {
  count               = local.alarmes ? 1 : 0
  alarm_name          = "${local.name}-rebut-non-vide"
  alarm_description   = "Un message des tâches est dans la file de rebut."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = aws_sqs_queue.jobs_rebut.name }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.actions
}

# 2. Erreurs du worker (invocation en échec) sur 15 minutes.
resource "aws_cloudwatch_metric_alarm" "worker_erreurs" {
  count               = local.alarmes ? 1 : 0
  alarm_name          = "${local.name}-worker-erreurs"
  alarm_description   = "Le worker a échoué (Errors > 0 sur 15 minutes)."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.worker.function_name }
  statistic           = "Sum"
  period              = 900
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.actions
}

# 3. Limitations (concurrence ou quota de compte atteints).
resource "aws_cloudwatch_metric_alarm" "worker_limitations" {
  count               = local.alarmes ? 1 : 0
  alarm_name          = "${local.name}-worker-limitations"
  alarm_description   = "Le worker est limité (Throttles) : quota de concurrence du compte ou réservation trop basse."
  namespace           = "AWS/Lambda"
  metric_name         = "Throttles"
  dimensions          = { FunctionName = aws_lambda_function.worker.function_name }
  statistic           = "Sum"
  period              = 900
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.actions
}

# 4. Durée proche du délai d'expiration (> 80 %).
resource "aws_cloudwatch_metric_alarm" "worker_duree" {
  count               = local.alarmes ? 1 : 0
  alarm_name          = "${local.name}-worker-duree"
  alarm_description   = "Une invocation du worker dépasse 80 % de son délai d'expiration."
  namespace           = "AWS/Lambda"
  metric_name         = "Duration"
  dimensions          = { FunctionName = aws_lambda_function.worker.function_name }
  statistic           = "Maximum"
  period              = 900
  evaluation_periods  = 1
  threshold           = var.worker_timeout * 1000 * 0.8
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.actions
}

# 5. Message en attente depuis plus de 30 minutes (consommation bloquée ou 404 en boucle).
resource "aws_cloudwatch_metric_alarm" "file_ancienne" {
  count               = local.alarmes ? 1 : 0
  alarm_name          = "${local.name}-file-ancienne"
  alarm_description   = "Le plus vieux message de la file des tâches a plus de 30 minutes."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateAgeOfOldestMessage"
  dimensions          = { QueueName = aws_sqs_queue.jobs.name }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1800
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.actions
}

# 6. Erreurs définitives acquittées (invisibles autrement que dans le journal), via le filtre de worker.tf.
resource "aws_cloudwatch_metric_alarm" "erreurs_definitives" {
  count               = local.alarmes ? 1 : 0
  alarm_name          = "${local.name}-erreurs-definitives"
  alarm_description   = "Le worker a acquitté une erreur définitive (message illisible, GRIB incohérent…)."
  namespace           = "RuneRide/Meteo"
  metric_name         = "ErreursDefinitives"
  statistic           = "Sum"
  period              = 900
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.actions
}

# 7. CloudFront : taux d'erreurs 5xx supérieur à 1 % sur trois périodes de 5 minutes (métrique en us-east-1).
resource "aws_cloudwatch_metric_alarm" "cloudfront_5xx" {
  count               = local.alarmes && var.alarme_cloudfront ? 1 : 0
  provider            = aws.virginie
  alarm_name          = "${local.name}-cloudfront-5xx"
  alarm_description   = "Plus de 1 % de réponses 5xx de CloudFront."
  namespace           = "AWS/CloudFront"
  metric_name         = "5xxErrorRate"
  dimensions          = { DistributionId = aws_cloudfront_distribution.donnees.id, Region = "Global" }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 1
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.actions_virginie
}

# 8. (poller activé) Erreurs du poller.
resource "aws_cloudwatch_metric_alarm" "poller_erreurs" {
  count               = local.alarmes && var.activer_poller ? 1 : 0
  alarm_name          = "${local.name}-poller-erreurs"
  alarm_description   = "Le poller a échoué (Errors > 0 sur 15 minutes)."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.poller[0].function_name }
  statistic           = "Sum"
  period              = 900
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.actions
}

# 9. (manifeste activé) Erreurs de la Lambda manifeste.
resource "aws_cloudwatch_metric_alarm" "manifeste_erreurs" {
  count               = local.alarmes && var.activer_manifeste ? 1 : 0
  alarm_name          = "${local.name}-manifeste-erreurs"
  alarm_description   = "La Lambda manifeste a échoué (Errors > 0 sur 15 minutes)."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.manifeste[0].function_name }
  statistic           = "Sum"
  period              = 900
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.actions
}
