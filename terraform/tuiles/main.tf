# Tuiles de fond de carte (PMTiles) de RuneRide : S3 privé derrière CloudFront.
# Le navigateur lit le fichier par requêtes HTTP Range (pmtiles.js) ; le bucket n'est jamais public,
# seul CloudFront (contrôle d'accès à l'origine) y accède.
#
# Rien n'est appliqué automatiquement : `terraform plan` d'abord, `apply` sur accord explicite.
# CloudFront est global : le certificat ACM doit être en us-east-1, même si le compte est verrouillé sur eu-north-1.

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

variable "region" {
  description = "Région du bucket S3 (le compte est verrouillé sur eu-north-1)."
  type        = string
  default     = "eu-north-1"
}

variable "domaine" {
  description = "Nom public des tuiles."
  type        = string
  default     = "tuiles.runeride.fr"
}

variable "origines_autorisees" {
  description = "Origines autorisées à lire les tuiles (CORS). Pas de joker."
  type        = list(string)
  default     = ["https://app.runeride.fr", "https://runeride.fr"]
}

variable "bucket" {
  description = "Nom du bucket S3 (unique au monde)."
  type        = string
  default     = "runeride-tuiles"
}

provider "aws" {
  region = var.region
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

# --- Stockage -----------------------------------------------------------------------------------

resource "aws_s3_bucket" "tuiles" {
  bucket = var.bucket
}

resource "aws_s3_bucket_public_access_block" "tuiles" {
  bucket                  = aws_s3_bucket.tuiles.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tuiles" {
  bucket = aws_s3_bucket.tuiles.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# --- Certificat (DNS hébergé hors AWS : validation par CNAME à créer chez o2switch) --------------

resource "aws_acm_certificate" "tuiles" {
  provider          = aws.us_east_1
  domain_name       = var.domaine
  validation_method = "DNS"
  lifecycle {
    create_before_destroy = true
  }
}

# --- CloudFront ---------------------------------------------------------------------------------

resource "aws_cloudfront_origin_access_control" "tuiles" {
  name                              = "${var.bucket}-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# Le contenu (PMTiles) est déjà compressé en interne : pas de compression par CloudFront (les offsets Range
# doivent rester ceux du fichier). CORS : en-têtes de réponse limités aux origines de l'appli.
resource "aws_cloudfront_response_headers_policy" "tuiles" {
  name = "${var.bucket}-cors"
  cors_config {
    access_control_allow_credentials = false
    access_control_allow_headers { items = ["Range", "If-Match", "If-None-Match"] }
    access_control_allow_methods { items = ["GET", "HEAD"] }
    access_control_allow_origins { items = var.origines_autorisees }
    access_control_expose_headers { items = ["Content-Range", "Content-Length", "ETag", "Accept-Ranges"] }
    access_control_max_age_sec = 86400
    origin_override            = true
  }
}

data "aws_cloudfront_cache_policy" "optimise" {
  name = "Managed-CachingOptimized"
}

resource "aws_cloudfront_distribution" "tuiles" {
  enabled         = true
  is_ipv6_enabled = true
  http_version    = "http2and3"
  aliases         = [var.domaine]
  price_class     = "PriceClass_100"
  comment         = "RuneRide : tuiles PMTiles"

  origin {
    domain_name              = aws_s3_bucket.tuiles.bucket_regional_domain_name
    origin_id                = "s3-tuiles"
    origin_access_control_id = aws_cloudfront_origin_access_control.tuiles.id
  }

  default_cache_behavior {
    target_origin_id           = "s3-tuiles"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD", "OPTIONS"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = false
    cache_policy_id            = data.aws_cloudfront_cache_policy.optimise.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.tuiles.id
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate.tuiles.arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}

# Seul CloudFront (cette distribution) peut lire le bucket.
data "aws_iam_policy_document" "lecture_cloudfront" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.tuiles.arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.tuiles.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "tuiles" {
  bucket = aws_s3_bucket.tuiles.id
  policy = data.aws_iam_policy_document.lecture_cloudfront.json
}

output "validation_certificat" {
  description = "Enregistrement CNAME à créer chez o2switch pour valider le certificat."
  value = [for o in aws_acm_certificate.tuiles.domain_validation_options : {
    nom    = o.resource_record_name
    type   = o.resource_record_type
    valeur = o.resource_record_value
  }]
}

output "cloudfront" {
  description = "Cible du CNAME tuiles.runeride.fr."
  value       = aws_cloudfront_distribution.tuiles.domain_name
}

output "bucket" {
  value = aws_s3_bucket.tuiles.bucket
}
