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
  description = "Cluster CA certificate (base64 encoded), or null when master_auth is unavailable"
  value       = one(google_container_cluster.primary.master_auth[*].cluster_ca_certificate)
  sensitive   = true
}

output "location" {
  description = "Cluster location (zone)"
  value       = google_container_cluster.primary.location
}
