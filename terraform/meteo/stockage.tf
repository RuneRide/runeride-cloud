# Compartiment des données météo : tuiles PMTiles, états d'échéance, manifeste. Privé, lu par CloudFront (OAC)
# et par les Lambdas. Le versionnage n'est PAS activé (jamais configuré, donc désactivé) : sinon l'expiration ne
# supprimerait pas définitivement les objets (docs/architecture-aws.md §2.3).

resource "aws_s3_bucket" "donnees" {
  bucket = local.bucket
}

resource "aws_s3_bucket_public_access_block" "donnees" {
  bucket                  = aws_s3_bucket.donnees.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "donnees" {
  bucket = aws_s3_bucket.donnees.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256" # SSE-S3, sans coût ni droits KMS
    }
  }
}

# Les fichiers sont écrits par les Lambdas : pas de listes de contrôle d'accès.
resource "aws_s3_bucket_ownership_controls" "donnees" {
  bucket = aws_s3_bucket.donnees.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Les requêtes préalables (OPTIONS) du navigateur arrivent jusqu'à S3 par CloudFront (politique d'origine
# Managed-CORS-S3Origin, qui transmet l'en-tête Origin) : S3 doit donc répondre lui aussi. Les en-têtes de
# réponse de CloudFront (cloudfront.tf) restent la référence pour les requêtes GET.
resource "aws_s3_bucket_cors_configuration" "donnees" {
  bucket = aws_s3_bucket.donnees.id
  cors_rule {
    allowed_origins = var.origines_autorisees
    allowed_methods = ["GET", "HEAD"]
    allowed_headers = ["Range", "If-Match", "If-None-Match"]
    expose_headers  = ["Content-Range", "Content-Length", "ETag", "Accept-Ranges"]
    max_age_seconds = 86400
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "donnees" {
  bucket = aws_s3_bucket.donnees.id

  # Une règle par modèle (préfixe stable par modèle) : le manifeste et sante.json, écrits à la racine du
  # préfixe général, ne sont jamais expirés. L'expiration est asynchrone (quelques heures de latence).
  dynamic "rule" {
    for_each = toset(var.modeles)
    content {
      id     = "tirages-expires-${rule.value}"
      status = "Enabled"
      filter {
        prefix = "${local.prefixe}/${rule.value}/"
      }
      expiration {
        days = var.retention_jours
      }
    }
  }

  # Les isobares (GeoJSON par tirage et échéance) expirent comme les tirages.
  rule {
    id     = "isobares-expirees"
    status = "Enabled"
    filter {
      prefix = "${local.prefixe_isobares}/"
    }
    expiration {
      days = var.retention_jours
    }
  }

  # Marqueurs du poller (<v1>/_poller/<modèle>/<tirage>.json, un par modèle et tirage) : le poller n'a pas le droit de
  # les supprimer (poller-manifeste.md §3.4 : « les marqueurs expirent avec la règle de cycle de vie »). Expiration
  # identique aux tirages : un tirage encore interrogé (RW_AGE_MAX_H, 36 h) est toujours plus jeune que 2 jours.
  rule {
    id     = "marqueurs-poller-expires"
    status = "Enabled"
    filter {
      prefix = "${local.prefixe_poller}/"
    }
    expiration {
      days = var.retention_jours
    }
  }

  # Un envoi multipart abandonné reste facturé tant que ses morceaux existent (le worker n'en fait pas :
  # fichiers < 30 Mo en un seul PutObject, mais la règle protège d'un client de test ou d'un SDK réglé autrement).
  rule {
    id     = "envois-interrompus"
    status = "Enabled"
    filter {
      prefix = ""
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = var.purge_multipart_jours
    }
  }
}

# Politique du compartiment : lecture par CloudFront seulement (cette distribution), pas de lecture des dossiers
# internes « _* » même par CloudFront, refus de tout accès sans TLS.
data "aws_iam_policy_document" "donnees" {
  statement {
    sid     = "LectureParCloudFront"
    actions = ["s3:GetObject"]
    # le préfixe des données (v1/) ET le fond de carte (basemap/, hors de v1/ : jamais expiré, jamais notifié)
    resources = [
      "${aws_s3_bucket.donnees.arn}/${local.prefixe}/*",
      "${aws_s3_bucket.donnees.arn}/${local.prefixe_fond}/*",
    ]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.donnees.arn]
    }
  }

  # Avec ListBucket, un objet absent donne 404 au lieu de 403 (ce qui permet au client de distinguer « pas
  # encore publié » d'« interdit »). Cette permission ne permet pas de lister : CloudFront ne fait que des GET.
  statement {
    sid       = "AbsentEstUn404"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.donnees.arn]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.donnees.arn]
    }
  }

  # Les dossiers « _* » (_etat, _isobares, _domaine, _canon : docs/poc-rust/lambda.md §3) ne sont jamais servis.
  # Le refus explicite l'emporte sur l'autorisation ci-dessus ; le comportement CloudFront « */_* » n'est que la
  # première barrière. Dans une ressource S3, « * » couvre aussi les barres obliques.
  statement {
    sid     = "RefuserLesDossiersInternes"
    effect  = "Deny"
    actions = ["s3:GetObject"]
    resources = [
      "${aws_s3_bucket.donnees.arn}/_*",
      "${aws_s3_bucket.donnees.arn}/*/_*",
    ]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
  }

  statement {
    sid       = "RefuserSansTLS"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.donnees.arn, "${aws_s3_bucket.donnees.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "donnees" {
  bucket = aws_s3_bucket.donnees.id
  policy = data.aws_iam_policy_document.donnees.json

  # la politique de blocage d'accès public doit être posée avant, sans quoi S3 peut refuser la politique
  depends_on = [aws_s3_bucket_public_access_block.donnees]
}
