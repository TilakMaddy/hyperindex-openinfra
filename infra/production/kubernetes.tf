module "marvel" {
  source  = "oatlabs/k8s-lima/aws"
  version = "0.0.3"

  config = local.config_json
}

output "talosconfigs" {
  description = "The generated talosconfig, per cluster. Keyed by the cluster's key in config.json, without the namespace prefix."
  value       = module.marvel.talosconfigs
  sensitive   = true
}

output "kubeconfigs" {
  description = "The generated kubeconfig, per cluster. Keyed by the cluster's key in config.json, without the namespace prefix."
  value       = module.marvel.kubeconfigs
  sensitive   = true
}
