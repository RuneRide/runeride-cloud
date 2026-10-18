output "dns" {
  description = "Enregistrements DNS à créer chez o2switch (cPanel, zone runeride.fr). Le premier valide le certificat (à créer en premier) ; le second rattache le nom public à CloudFront (après l'émission du certificat et certificat_valide = true)."
  value = concat(
    [for o in aws_acm_certificate.raido.domain_validation_options : {
      nom    = o.resource_record_name
      type   = o.resource_record_type
      valeur = o.resource_record_value
      role   = "validation du certificat ACM"
    }],
    [{
      nom    = var.domaine
      type   = "CNAME"
      valeur = aws_cloudfront_distribution.raido.domain_name
      role   = "nom public de Raido vers CloudFront"
    }],
  )
}

output "cloudfront" {
  description = "Cible du CNAME raido.runeride.fr."
  value       = aws_cloudfront_distribution.raido.domain_name
}

output "url_raido" {
  description = "Adresse publique de l'API une fois le domaine rattaché ; sinon l'adresse donnée par CloudFront."
  value       = local.rattache ? "https://${var.domaine}" : "https://${aws_cloudfront_distribution.raido.domain_name}"
}

output "function_url" {
  description = "Function URL (AWS_IAM : inutilisable sans signature, seul CloudFront l'appelle). Pour information."
  value       = aws_lambda_function_url.calcul.function_url
}

output "bucket" {
  description = "Compartiment du graphe (RAIDO_BUCKET)."
  value       = aws_s3_bucket.graphe.id
}

output "prefixe_graphe" {
  value = local.prefixe
}

output "fonction" {
  value = aws_lambda_function.calcul.function_name
}

output "publier_graphe" {
  description = "Commande de publication d'un graphe construit par raido-graphe (Terraform n'envoie aucun fichier). Une nouvelle version va dans un autre dossier, puis prefixe_graphe change."
  value       = "aws s3 sync <dossier du graphe> s3://${aws_s3_bucket.graphe.id}/${local.prefixe}/ --exclude '*' --include 'index.json' --include 'tuiles/*' --content-type application/octet-stream"
}

output "actions_manuelles" {
  description = "Ce que Terraform ne fait pas."
  value = concat(
    [
      "Créer chez o2switch les enregistrements de la sortie « dns » (validation du certificat, puis CNAME du nom public).",
      "Publier le graphe (sortie « publier_graphe ») AVANT la première invocation : sans index.json, la fonction échoue au démarrage.",
      "Vérifier : curl -s https://<cloudfront>/v1/sante ; puis un POST avec l'en-tête x-amz-content-sha256 (README.md).",
    ],
    var.alerte_email == "" ? ["Renseigner alerte_email : sans elle, ni budget ni notification d'alarme."] : ["Confirmer l'abonnement SNS reçu par courriel."],
    var.concurrence_reservee == -1 ? ["Concurrence non réservée : le coût n'est borné que par le budget (qui prévient sans bloquer). Réserver dès que le quota du compte le permet."] : [],
  )
}
