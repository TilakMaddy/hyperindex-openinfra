locals {
  cluster_name             = "us-west-2-aws-backoffice-dataplane"
  replica_region           = "us-east-2"
  pg_backups_bucket_prefix = "oatlabs-backoffice-pg-backups"
}

locals {
  config_json = file("${path.module}/config.json")
  config      = jsondecode(local.config_json)
  cluster     = local.config.k8s_clusters[local.cluster_name]
  region      = local.cluster.region
  namespace   = local.config.namespace
  name_prefix = substr(uuidv5("oid", "${local.namespace}/${local.cluster_name}"), 0, 32)

  tags = {
    Organization = local.config.organization
    Namespace    = local.namespace
    Provisioner  = "Terraform"
    Platform     = "OatLabs"
    ClusterName  = "${local.namespace}-${local.cluster_name}"
  }
}

terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {}
