# Garde-fou de dépense : cible de lancement 1 $/mois (docs/architecture-aws.md §10). Un budget PRÉVIENT mais ne
# plafonne pas. Créé seulement si alerte_email est renseignée (un budget sans destinataire ne sert à rien).
# Seuils : 80 % et 100 % du réel, 100 % de la prévision. Avec 1 $, 80 % = 0,80 $.

resource "aws_budgets_budget" "mois" {
  count        = var.alerte_email != "" ? 1 : 0
  name         = "${local.name}-mois"
  budget_type  = "COST"
  limit_amount = tostring(var.budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alerte_email]
  }
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alerte_email]
  }
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alerte_email]
  }
}
