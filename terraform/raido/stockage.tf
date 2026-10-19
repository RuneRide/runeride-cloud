# Compartiment du graphe routier : index.json et tuiles/<z>/<x>/<y>.rkyv écrits par raido-graphe (publication
# manuelle, voir la sortie « publier_graphe »). Privé : lu par la seule fonction Lambda, jamais par CloudFront ni
# par le navigateur (spec O4 : graphe interne). Versionnage jamais activé ; une version de graphe = un dossier.

resource "aws_s3_bucket" "graphe" {
  bucket = local.bucket
}

resource "aws_s3_bucket_public_access_block" "graphe" {
  bucket                  = aws_s3_bucket.graphe.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "graphe" {
  bucket = aws_s3_bucket.graphe.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256" # SSE-S3, sans coût ni droits KMS
    }
  }
}

resource "aws_s3_bucket_ownership_controls" "graphe" {
  bucket = aws_s3_bucket.graphe.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "graphe" {
  bucket = aws_s3_bucket.graphe.id

  # Un envoi multipart abandonné (aws s3 sync d'une grosse tuile interrompu) reste facturé tant qu'il existe.
  rule {
    id     = "envois-interrompus"
    status = "Enabled"
    filter {
      prefix = ""
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

# Refus de tout accès sans TLS. La lecture par la fonction passe par son rôle (fonction.tf), pas par cette politique.
data "aws_iam_policy_document" "graphe" {
  statement {
    sid       = "RefuserSansTLS"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.graphe.arn, "${aws_s3_bucket.graphe.arn}/*"]
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

resource "aws_s3_bucket_policy" "graphe" {
  bucket     = aws_s3_bucket.graphe.id
  policy     = data.aws_iam_policy_document.graphe.json
  depends_on = [aws_s3_bucket_public_access_block.graphe]
}
