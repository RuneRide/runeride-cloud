# Diffusion : CloudFront devant la Function URL, domaine raido.runeride.fr. Le DNS est chez o2switch : le certificat
# ACM (us-east-1) se valide par un CNAME à créer à la main, et le nom public est un CNAME vers la distribution.
#
# POST à travers un OAC Lambda : CloudFront signe la requête vers la Function URL mais NE CALCULE PAS le condensé du
# corps ; le navigateur doit envoyer l'en-tête `x-amz-content-sha256` (SHA-256 hexadécimal du corps JSON), sinon la
# Function URL répond 403 (runeride-weather/docs/architecture-aws.md §4.4, piège vérifié dans la documentation AWS).
# La PWA le fait avec crypto.subtle.digest ; à documenter dans js/api.js (jalon J4).

# ---------------------------------------------------------------- certificat

resource "aws_acm_certificate" "raido" {
  provider          = aws.virginie
  domain_name       = var.domaine
  validation_method = "DNS"
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_acm_certificate_validation" "raido" {
  count           = local.rattache ? 1 : 0
  provider        = aws.virginie
  certificate_arn = aws_acm_certificate.raido.arn
  # pas de validation_record_fqdns : le DNS n'est pas dans AWS, ACM interroge lui-même le CNAME
}

# ---------------------------------------------------------------- accès à l'origine, en-têtes, cache

resource "aws_cloudfront_origin_access_control" "raido" {
  name                              = local.name
  description                       = "Invocation de la Function URL Raido par CloudFront (OAC lambda)"
  origin_access_control_origin_type = "lambda"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# CORS pour l'appli (POST JSON avec Authorization et x-amz-content-sha256), HSTS, nosniff.
resource "aws_cloudfront_response_headers_policy" "raido" {
  name    = "${local.name}-cors"
  comment = "CORS (app.runeride.fr, runeride.fr, dev local) et en-tetes de securite"

  cors_config {
    access_control_allow_credentials = false
    access_control_allow_headers { items = ["Content-Type", "Authorization", "x-amz-content-sha256"] }
    access_control_allow_methods { items = ["GET", "HEAD", "OPTIONS", "POST"] }
    access_control_allow_origins { items = var.origines_autorisees }
    access_control_max_age_sec = 86400
    origin_override            = true
  }

  security_headers_config {
    strict_transport_security {
      access_control_max_age_sec = 31536000
      include_subdomains         = false
      override                   = true
    }
    content_type_options {
      override = true
    }
  }
}

# /v1/sante : cache court (30 s) pour ne pas invoquer la fonction à chaque sonde.
resource "aws_cloudfront_cache_policy" "sante" {
  name        = "${local.name}-sante"
  comment     = "TTL court pour /v1/sante"
  min_ttl     = 0
  default_ttl = 30
  max_ttl     = 60

  parameters_in_cache_key_and_forwarded_to_origin {
    enable_accept_encoding_gzip   = true
    enable_accept_encoding_brotli = true
    cookies_config {
      cookie_behavior = "none"
    }
    headers_config {
      header_behavior = "none"
    }
    query_strings_config {
      query_string_behavior = "none"
    }
  }
}

# ---------------------------------------------------------------- distribution

resource "aws_cloudfront_distribution" "raido" {
  enabled         = true
  comment         = "${local.name} : API de balade (Function URL)"
  is_ipv6_enabled = true
  http_version    = "http2and3"
  price_class     = var.classe_prix
  aliases         = local.rattache ? [var.domaine] : []

  origin {
    origin_id                = "lambda-calcul"
    domain_name              = local.hote_fonction
    origin_access_control_id = aws_cloudfront_origin_access_control.raido.id
    custom_origin_config {
      http_port                = 80
      https_port               = 443
      origin_protocol_policy   = "https-only"
      origin_ssl_protocols     = ["TLSv1.2"]
      origin_read_timeout      = 30
      origin_keepalive_timeout = 5
    }
  }

  # /v1/sante : GET mis en cache 30 s.
  ordered_cache_behavior {
    path_pattern               = "/v1/sante"
    target_origin_id           = "lambda-calcul"
    viewer_protocol_policy     = "https-only"
    allowed_methods            = ["GET", "HEAD", "OPTIONS"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = aws_cloudfront_cache_policy.sante.id
    origin_request_policy_id   = local.origine_tout_sauf_hote
    response_headers_policy_id = aws_cloudfront_response_headers_policy.raido.id
  }

  # Par défaut : POST /v1/balade et /v1/trajet, jamais en cache (chaque requête est un calcul), compression des
  # réponses JSON. AllViewerExceptHostHeader : CloudFront transmet corps, en-têtes (dont Authorization et
  # x-amz-content-sha256) et chaîne de requête, mais pas Host (exigé par la Function URL).
  default_cache_behavior {
    target_origin_id           = "lambda-calcul"
    viewer_protocol_policy     = "https-only"
    allowed_methods            = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = local.cache_coupe
    origin_request_policy_id   = local.origine_tout_sauf_hote
    response_headers_policy_id = aws_cloudfront_response_headers_policy.raido.id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = !local.rattache
    acm_certificate_arn            = local.rattache ? aws_acm_certificate_validation.raido[0].certificate_arn : null
    ssl_support_method             = local.rattache ? "sni-only" : null
    minimum_protocol_version       = local.rattache ? "TLSv1.2_2021" : null
  }
}
