# Alarmes CloudWatch : 3 (4 avec alarme_cloudfront). Le quota gratuit de 10 alarmes est celui du COMPTE ENTIER,
# partagé avec ../meteo (7 à 9) et ../deploiement (jusqu'à 4) : au-delà, 0,10 $ par alarme et par mois.

locals {
  alarmes  = var.alarmes_actives
  notifier = var.alerte_email != ""
}

resource "aws_sns_topic" "alertes" {
  count = local.notifier ? 1 : 0
  name  = "${local.name}-alertes"
}

# Abonnement par courriel : demande une confirmation par lien.
resource "aws_sns_topic_subscription" "alertes" {
  count     = local.notifier ? 1 : 0
  topic_arn = aws_sns_topic.alertes[0].arn
  protocol  = "email"
  endpoint  = var.alerte_email
}

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

# 1. Erreurs de la fonction (invocation en échec : configuration, panique, graphe absent) sur 15 minutes.
resource "aws_cloudwatch_metric_alarm" "erreurs" {
  count               = local.alarmes ? 1 : 0
  alarm_name          = "${local.name}-erreurs"
  alarm_description   = "La fonction Raido a échoué (Errors > 0 sur 15 minutes)."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.calcul.function_name }
  statistic           = "Sum"
  period              = 900
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.actions
}

# 2. Limitations : concurrence réservée atteinte (coût borné, mais des utilisateurs reçoivent une erreur).
resource "aws_cloudwatch_metric_alarm" "limitations" {
  count               = local.alarmes ? 1 : 0
  alarm_name          = "${local.name}-limitations"
  alarm_description   = "La fonction Raido est limitée (Throttles) : concurrence réservée ou quota du compte atteint."
  namespace           = "AWS/Lambda"
  metric_name         = "Throttles"
  dimensions          = { FunctionName = aws_lambda_function.calcul.function_name }
  statistic           = "Sum"
  period              = 900
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.actions
}

# 3. Durée proche du délai d'expiration (> 80 %) : grandes boucles trop lentes, à traiter par la mémoire (vCPU).
resource "aws_cloudwatch_metric_alarm" "duree" {
  count               = local.alarmes ? 1 : 0
  alarm_name          = "${local.name}-duree"
  alarm_description   = "Une invocation Raido dépasse 80 % de son délai d'expiration."
  namespace           = "AWS/Lambda"
  metric_name         = "Duration"
  dimensions          = { FunctionName = aws_lambda_function.calcul.function_name }
  statistic           = "Maximum"
  period              = 900
  evaluation_periods  = 1
  threshold           = var.timeout * 1000 * 0.8
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.actions
}

# 4. CloudFront : taux d'erreurs 5xx supérieur à 5 % sur trois périodes de 5 minutes (métrique en us-east-1).
resource "aws_cloudwatch_metric_alarm" "cloudfront_5xx" {
  count               = local.alarmes && var.alarme_cloudfront ? 1 : 0
  provider            = aws.virginie
  alarm_name          = "${local.name}-cloudfront-5xx"
  alarm_description   = "Plus de 5 % de réponses 5xx de CloudFront pour Raido."
  namespace           = "AWS/CloudFront"
  metric_name         = "5xxErrorRate"
  dimensions          = { DistributionId = aws_cloudfront_distribution.raido.id, Region = "Global" }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 5
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.actions_virginie
}
