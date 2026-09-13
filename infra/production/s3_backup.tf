locals {
  pg_backups_bucket = "${local.pg_backups_bucket_prefix}-${local.namespace}"
  postgres_nodes = [
    for name, worker in local.cluster.k8s_workers :
    name if contains(worker.roles, "postgres")
  ]
}

resource "aws_s3_bucket" "pg_backups" {
  region = local.region
  bucket = local.pg_backups_bucket
  tags   = local.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "pg_backups" {
  region = local.region
  bucket = aws_s3_bucket.pg_backups.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "pg_backups" {
  region = local.region
  bucket = aws_s3_bucket.pg_backups.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "pg_backups" {
  region = local.region
  bucket = aws_s3_bucket.pg_backups.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }

    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "pg_backups" {
  region = local.region
  bucket = aws_s3_bucket.pg_backups.id

  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

resource "aws_iam_policy" "pg_backups" {
  name        = "${local.name_prefix}-postgres-backups-policy"
  description = "IAM policy for the postgres nodes to allow the CNPG barman-cloud plugin to read and write base backups and WALs, and to read them back from the cross-region replica"
  tags        = local.tags

  policy = jsonencode(
    {
      Version = "2012-10-17",
      Statement = [
        {
          Effect = "Allow",
          Action = [
            "s3:ListBucket",
            "s3:GetBucketLocation",
            "s3:ListBucketMultipartUploads"
          ],
          Resource = aws_s3_bucket.pg_backups.arn
        },
        {
          Effect = "Allow",
          Action = [
            "s3:GetObject",
            "s3:PutObject",
            "s3:DeleteObject",
            "s3:AbortMultipartUpload",
            "s3:ListMultipartUploadParts"
          ],
          Resource = "${aws_s3_bucket.pg_backups.arn}/*"
        },
        {
          Effect = "Allow",
          Action = [
            "s3:ListBucket",
            "s3:GetBucketLocation"
          ],
          Resource = aws_s3_bucket.pg_backups_replica.arn
        },
        {
          Effect = "Allow",
          Action = [
            "s3:GetObject"
          ],
          Resource = "${aws_s3_bucket.pg_backups_replica.arn}/*"
        }
      ]
    }
  )
}

data "aws_iam_role" "postgres_nodes" {
  for_each = toset(local.postgres_nodes)

  name       = "${local.name_prefix}-worker-${each.key}"
  depends_on = [module.marvel]
}

resource "aws_iam_role_policy_attachment" "pg_backups" {
  for_each = data.aws_iam_role.postgres_nodes

  role       = each.value.name
  policy_arn = aws_iam_policy.pg_backups.arn
}

output "pg_backups_destination" {
  description = "The PG_BACKUP_DESTINATION for the flux entrypoint of this namespace."
  value       = "s3://${local.pg_backups_bucket}/"
}

output "pg_backups_region" {
  description = "The PG_BACKUP_REGION for the flux entrypoint of this namespace."
  value       = local.region
}
