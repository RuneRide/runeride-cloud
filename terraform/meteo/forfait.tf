# Forfait CloudFront à tarif fixe (FACULTATIF, désactivé par défaut : forfait_cloudfront = null).
#
# Ce que le fournisseur aws (>= 6.69) sait faire : la ressource aws_pricingplanmanager_subscription applique un
# forfait (plan_family = "CloudFront", plan_tier = FREE | PRO | BUSINESS | PREMIUM) à EXACTEMENT UNE distribution
# et UNE ACL WAF (plus des zones Route 53 en option). C'est pourquoi une ACL WAF de portée CLOUDFRONT est créée ici.
#
# NON VALIDÉ contre l'API : ni plan ni apply n'ont été possibles. Réserves à lever avant usage :
#   - le forfait peut exiger que le compte ne soit pas sous l'offre gratuite AWS (architecture-aws.md §5.1, §10.4) ;
#   - l'éligibilité de la distribution (OAC oui, cache par politiques oui, pas de Lambda@Edge) est supposée ;
#   - un forfait couvre la distribution : CloudFront en bloque ensuite la suppression et le retrait de l'ACL ;
#   - FREE = approbation immédiate ; les forfaits payants restent en attente d'approbation (approval_mode MANUAL).
# Repli sûr : laisser forfait_cloudfront à null et souscrire le forfait Free dans la console (comme ../tuiles).

resource "aws_wafv2_web_acl" "forfait" {
  count       = local.forfait ? 1 : 0
  provider    = aws.virginie # une ACL de portée CLOUDFRONT n'existe qu'en us-east-1
  name        = local.name
  description = "ACL du forfait CloudFront de la meteo"
  scope       = "CLOUDFRONT"

  default_action {
    allow {}
  }

  dynamic "rule" {
    for_each = var.forfait_limite_debit_ip == null ? [] : [var.forfait_limite_debit_ip]
    content {
      name     = "limite-debit-ip"
      priority = 1
      action {
        block {}
      }
      statement {
        rate_based_statement {
          limit              = rule.value
          aggregate_key_type = "IP"
        }
      }
      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "${local.name}-limite-debit-ip"
        sampled_requests_enabled   = true
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = local.name
    sampled_requests_enabled   = true
  }
}

resource "aws_pricingplanmanager_subscription" "cloudfront" {
  count       = local.forfait ? 1 : 0
  provider    = aws.virginie
  plan_family = "CloudFront"
  plan_tier   = var.forfait_cloudfront

  resource_arns = [
    aws_cloudfront_distribution.donnees.arn,
    aws_wafv2_web_acl.forfait[0].arn,
  ]
}
