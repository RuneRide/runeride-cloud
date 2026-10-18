# Diffusion : CloudFront devant le compartiment privé, domaine weather-data.runeride.fr.
# Le DNS est chez o2switch : le certificat ACM (us-east-1) se valide par un CNAME à créer à la main, et le nom
# public est un CNAME vers la distribution. Voir les sorties « dns » et README.md pour l'ordre d'application.
#
# FORFAIT CLOUDFRONT (Free / Pro / Business) : facultatif, voir forfait.tf et README.md. Par défaut (variable
# forfait_cloudfront vide), la distribution est à l'usage (palier gratuit 1 To / 10 M de requêtes) et le forfait
# se souscrit à la main dans la console, comme pour ../tuiles.

# ---------------------------------------------------------------- certificat

resource "aws_acm_certificate" "donnees" {
  provider          = aws.virginie
  domain_name       = var.domaine
  validation_method = "DNS"
  lifecycle {
    create_before_destroy = true
  }
}

# Attend que le certificat soit émis (après création du CNAME chez o2switch). Seulement une fois
# certificat_valide à true : sinon l'application attendrait indéfiniment (comme ../deploiement).
resource "aws_acm_certificate_validation" "donnees" {
  count           = local.rattache ? 1 : 0
  provider        = aws.virginie
  certificate_arn = aws_acm_certificate.donnees.arn
  # pas de validation_record_fqdns : le DNS n'est pas dans AWS, ACM interroge lui-même le CNAME
}

# ---------------------------------------------------------------- accès à l'origine, en-têtes, cache

resource "aws_cloudfront_origin_access_control" "donnees" {
  name                              = local.name
  description                       = "Lecture du compartiment météo par CloudFront (OAC, jamais d'OAI)"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# CORS limité à weather.runeride.fr et au viewer local, plus les en-têtes de sécurité (docs/architecture-aws.md §6).
resource "aws_cloudfront_response_headers_policy" "donnees" {
  name    = "${local.name}-cors"
  comment = "CORS (weather.runeride.fr, localhost) et en-tetes de securite"

  cors_config {
    access_control_allow_credentials = false
    access_control_allow_headers { items = ["Range", "If-Match", "If-None-Match"] }
    access_control_allow_methods { items = ["GET", "HEAD", "OPTIONS"] }
    access_control_allow_origins { items = var.origines_autorisees }
    access_control_expose_headers { items = ["Content-Range", "Content-Length", "ETag", "Accept-Ranges"] }
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

# Manifeste et sante.json : cache court. Le Cache-Control du worker (max-age=30) fait foi, borné par ces TTL.
# Compression activée dans la clé de cache (gzip, brotli) : le JSON se compresse bien.
resource "aws_cloudfront_cache_policy" "manifeste" {
  name        = "${local.name}-manifeste"
  comment     = "TTL court pour manifest.json et sante.json, sans chaine de requete"
  min_ttl     = 0
  default_ttl = var.ttl_manifeste_defaut
  max_ttl     = var.ttl_manifeste_max

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

resource "aws_cloudfront_distribution" "donnees" {
  enabled         = true
  comment         = "${local.name} : tuiles PMTiles et manifeste"
  is_ipv6_enabled = true
  http_version    = "http2and3"
  price_class     = var.classe_prix
  aliases         = local.rattache ? [var.domaine] : []
  web_acl_id      = local.forfait ? aws_wafv2_web_acl.forfait[0].arn : null

  origin {
    origin_id                = "s3-donnees"
    domain_name              = aws_s3_bucket.donnees.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.donnees.id
  }

  # 1. Dossiers internes (_etat, _isobares, _domaine, _canon) : jamais servis. Aucun cache ; le refus effectif est
  #    celui de la politique du compartiment (« RefuserLesDossiersInternes »), qui répond 403. Ce comportement doit
  #    rester le PREMIER de la liste (CloudFront retient le premier motif qui correspond).
  ordered_cache_behavior {
    path_pattern               = "*/_*"
    target_origin_id           = "s3-donnees"
    viewer_protocol_policy     = "https-only"
    allowed_methods            = ["GET", "HEAD", "OPTIONS"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = false
    cache_policy_id            = local.cache_coupe
    origin_request_policy_id   = local.origine_cors
    response_headers_policy_id = aws_cloudfront_response_headers_policy.donnees.id
  }

  # 1 bis. Isobares (GeoJSON, application/json, immuables) : compressées par CloudFront (≈ 93 Ko -> bien moins). Le
  #    comportement par défaut ne compresse pas (décalages d'octets des PMTiles). Sans recoupement avec « */_* ».
  ordered_cache_behavior {
    path_pattern               = "/${local.prefixe}/isobares/*"
    target_origin_id           = "s3-donnees"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD", "OPTIONS"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = local.cache_optimise
    origin_request_policy_id   = local.origine_cors
    response_headers_policy_id = aws_cloudfront_response_headers_policy.donnees.id
  }

  # 2. Manifeste : TTL court, ETag, compression.
  ordered_cache_behavior {
    path_pattern               = "/${local.cle_manifeste}"
    target_origin_id           = "s3-donnees"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD", "OPTIONS"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = aws_cloudfront_cache_policy.manifeste.id
    origin_request_policy_id   = local.origine_cors
    response_headers_policy_id = aws_cloudfront_response_headers_policy.donnees.id
  }

  # 3. Fichier de santé écrit par le poller : même cache court.
  ordered_cache_behavior {
    path_pattern               = "/${local.cle_sante}"
    target_origin_id           = "s3-donnees"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD", "OPTIONS"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = aws_cloudfront_cache_policy.manifeste.id
    origin_request_policy_id   = local.origine_cors
    response_headers_policy_id = aws_cloudfront_response_headers_policy.donnees.id
  }

  # Par défaut : les .pmtiles. Cache-Control « public, max-age=31536000, immutable » posé à l'écriture par le
  # worker et respecté par CachingOptimized (min 1 s, défaut 1 jour, max 1 an). PAS de compression : les
  # décalages d'octets des requêtes Range doivent rester ceux du fichier. Les requêtes Range sont gérées
  # nativement par CloudFront (plages mises en cache) ; Content-Type application/vnd.pmtiles posé par le worker.
  default_cache_behavior {
    target_origin_id           = "s3-donnees"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD", "OPTIONS"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = false
    cache_policy_id            = local.cache_optimise
    origin_request_policy_id   = local.origine_cors
    response_headers_policy_id = aws_cloudfront_response_headers_policy.donnees.id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = !local.rattache
    acm_certificate_arn            = local.rattache ? aws_acm_certificate_validation.donnees[0].certificate_arn : null
    ssl_support_method             = local.rattache ? "sni-only" : null
    minimum_protocol_version       = local.rattache ? "TLSv1.2_2021" : null
  }
}
