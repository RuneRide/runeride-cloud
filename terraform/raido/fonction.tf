# Lambda « calcul » : binaire Rust raido-lambda (runeride-carto/rust/crates/raido-lambda), arm64, provided.al2023,
# hors VPC. Routes : GET /v1/sante, POST /v1/balade, POST /v1/trajet, et POST /v1/apparier (privée, clé de service). Exposée par une Function URL en AWS_IAM, que
# seule la distribution CloudFront (OAC) peut invoquer.

resource "aws_cloudwatch_log_group" "calcul" {
  name              = "/aws/lambda/${local.name}-calcul"
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

resource "aws_iam_role" "calcul" {
  name               = "${local.name}-calcul"
  assume_role_policy = data.aws_iam_policy_document.lambda_confiance.json
}

# Moindre privilège : lecture du seul dossier du graphe, ListBucket pour que S3 réponde 404 (absent) et non 403
# (même raison que ../meteo, lambda.md §10.1), journaux. Aucune écriture.
data "aws_iam_policy_document" "calcul" {
  statement {
    sid       = "LireLeGraphe"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.graphe.arn}/${local.prefixe}/*"]
  }

  statement {
    sid       = "DistinguerAbsentEtInterdit"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.graphe.arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${local.prefixe}/*"]
    }
  }

  # logs:CreateLogGroup volontairement omis : le groupe est créé ici, avec sa rétention.
  statement {
    sid       = "Journaux"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.calcul.arn}:*"]
  }
}

resource "aws_iam_role_policy" "calcul" {
  name   = "calcul"
  role   = aws_iam_role.calcul.id
  policy = data.aws_iam_policy_document.calcul.json
}

resource "aws_lambda_function" "calcul" {
  function_name = "${local.name}-calcul"
  role          = aws_iam_role.calcul.arn
  runtime       = "provided.al2023"
  architectures = ["arm64"]
  handler       = "bootstrap" # sans objet pour provided.al2023, valeur conventionnelle

  filename         = var.chemin_zip
  source_code_hash = filebase64sha256(var.chemin_zip)

  memory_size                    = var.memoire_mo
  timeout                        = var.timeout
  reserved_concurrent_executions = var.concurrence_reservee

  ephemeral_storage {
    size = var.ephemere_mo
  }

  # Variables lues par raido_lambda::handler::Contexte::depuis_env. AWS_REGION et les identifiants viennent de Lambda.
  environment {
    variables = merge(
      {
        RAIDO_SOURCE   = "s3"
        RAIDO_BUCKET   = aws_s3_bucket.graphe.id
        RAIDO_PREFIXE  = local.prefixe
        RAIDO_CACHE    = "/tmp/raido"
        RAIDO_JETON    = "obligatoire"
        RAIDO_JWKS_URL = var.jwks_url
        RAIDO_EMETTEUR = var.jeton_emetteur
        RAIDO_AUDIENCE = var.jeton_audience
      },
      var.fils != "" ? { RAIDO_THREADS = var.fils } : {},
      var.cle_service != "" ? { RAIDO_CLE_SERVICE = var.cle_service } : {},
      var.environnement_supplementaire,
    )
  }

  depends_on = [aws_cloudwatch_log_group.calcul, aws_iam_role_policy.calcul]
}

# Function URL : authentification AWS_IAM, donc inaccessible sans signature ; CloudFront signe par l'OAC.
# Pas de CORS ici : c'est CloudFront qui pose les en-têtes (cloudfront.tf). Réponses en mémoire (BUFFERED).
resource "aws_lambda_function_url" "calcul" {
  function_name      = aws_lambda_function.calcul.function_name
  authorization_type = "AWS_IAM"
  invoke_mode        = "BUFFERED"
}

# Seule cette distribution peut invoquer l'URL.
resource "aws_lambda_permission" "cloudfront" {
  statement_id           = "InvocationParCloudFront"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.calcul.function_name
  principal              = "cloudfront.amazonaws.com"
  source_arn             = aws_cloudfront_distribution.raido.arn
  function_url_auth_type = "AWS_IAM"
}
