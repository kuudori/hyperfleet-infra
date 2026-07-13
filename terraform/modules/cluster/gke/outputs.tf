output "cluster_name" {
  description = "Name of the GKE cluster"
  value       = google_container_cluster.primary.name
}

output "endpoint" {
  description = "Cluster endpoint"
  value       = google_container_cluster.primary.endpoint
  sensitive   = true
}

output "ca_certificate" {
  description = "Cluster CA certificate (base64 encoded)"
  value       = google_container_cluster.primary.master_auth[0].cluster_ca_certificate
  sensitive   = true
}

output "location" {
  description = "Cluster location (zone)"
  value       = google_container_cluster.primary.location
}

output "oidc_issuer_url" {
  description = "OIDC issuer URL for this GKE cluster (used for JWT validation of projected ServiceAccount tokens)"
  value       = "https://container.googleapis.com/v1/projects/${var.project_id}/locations/${google_container_cluster.primary.location}/clusters/${google_container_cluster.primary.name}"
}
