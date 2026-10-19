# Garde-fou de dépense : spec §5.5 (< 1 € attendu, alarme à 5). Un budget PRÉVIENT mais ne plafonne pas ; seule la
# concurrence réservée plafonne. Créé seulement si alerte_email est renseignée.

resource "aws_budgets_budget" "mois" {
  count        = var.alerte_email != "" ? 1 : 0
  name         = "${local.name}-mois"
  budget_type  = "COST"
  limit_amount = tostring(var.budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "TagKeyValue"
    values = ["user:composant$raido"]
  }

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
