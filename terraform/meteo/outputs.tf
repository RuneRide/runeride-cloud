output "dns" {
  description = "Enregistrements DNS à créer chez o2switch (cPanel, zone runeride.fr). Le premier valide le certificat (à créer en premier) ; le second rattache le nom public à CloudFront (à créer après l'émission du certificat et certificat_valide = true)."
  value = concat(
    [for o in aws_acm_certificate.donnees.domain_validation_options : {
      nom    = o.resource_record_name
      type   = o.resource_record_type
      valeur = o.resource_record_value
      role   = "validation du certificat ACM"
    }],
    [{
      nom    = var.domaine
      type   = "CNAME"
      valeur = aws_cloudfront_distribution.donnees.domain_name
      role   = "nom public des données vers CloudFront"
    }],
  )
}

output "validation_certificat" {
  description = "Enregistrement CNAME de validation du certificat (même forme que ../tuiles)."
  value = [for o in aws_acm_certificate.donnees.domain_validation_options : {
    nom    = o.resource_record_name
    type   = o.resource_record_type
    valeur = o.resource_record_value
  }]
}

output "cloudfront" {
  description = "Cible du CNAME weather-data.runeride.fr."
  value       = aws_cloudfront_distribution.donnees.domain_name
}

output "distribution" {
  description = "Identifiant de la distribution CloudFront."
  value       = aws_cloudfront_distribution.donnees.id
}

output "url_donnees" {
  description = "Adresse publique des données une fois le domaine rattaché ; sinon l'adresse donnée par CloudFront."
  value       = local.rattache ? "https://${var.domaine}" : "https://${aws_cloudfront_distribution.donnees.domain_name}"
}

output "bucket" {
  description = "Compartiment S3 des données (RW_BUCKET)."
  value       = aws_s3_bucket.donnees.id
}

output "bucket_arn" {
  value = aws_s3_bucket.donnees.arn
}

output "prefixe_cles" {
  description = "Préfixe des clés (RW_PREFIXE)."
  value       = local.prefixe
}

output "file_jobs" {
  description = "URL de la file des tâches (à donner au poller)."
  value       = aws_sqs_queue.jobs.url
}

output "file_jobs_arn" {
  value = aws_sqs_queue.jobs.arn
}

output "file_rebut" {
  value = aws_sqs_queue.jobs_rebut.url
}

output "worker" {
  description = "Nom de la fonction worker."
  value       = aws_lambda_function.worker.function_name
}

output "worker_role_arn" {
  value = aws_iam_role.worker.arn
}

output "poller" {
  description = "Nom de la Lambda poller (null si activer_poller est false)."
  value       = var.activer_poller ? aws_lambda_function.poller[0].function_name : null
}

output "manifeste" {
  description = "Nom de la Lambda manifeste (null si activer_manifeste est false)."
  value       = var.activer_manifeste ? aws_lambda_function.manifeste[0].function_name : null
}

output "actions_manuelles" {
  description = "Ce que Terraform ne fait pas."
  value = concat(
    ["Créer chez o2switch les enregistrements de la sortie « dns » (validation du certificat, puis CNAME du nom public).",
    "Envoyer le fond de carte vers basemap/ (docs/mise-en-production.md §6) : Terraform n'envoie aucun fichier."],
    local.forfait ? [] : ["Souscrire le forfait CloudFront Free dans la console (distribution, gérer le forfait), ou renseigner forfait_cloudfront."],
    var.alerte_email == "" ? ["Renseigner alerte_email : sans elle, ni budget ni notification d'alarme."] : ["Confirmer les abonnements SNS reçus par courriel (deux sujets : eu-north-1 et us-east-1)."],
    var.activer_poller ? [] : ["Poller non déployé : sans lui, aucun message n'entre dans la file (envoi manuel possible pour un essai). Zip : rust/tools/package-lambda.sh arm64 poller."],
    var.activer_manifeste ? [] : ["Manifeste non déployé : manifest.json est à produire autrement (docs/mise-en-production.md §7, voie A). Zip : rust/tools/package-lambda.sh arm64 manifeste."],
  )
}
