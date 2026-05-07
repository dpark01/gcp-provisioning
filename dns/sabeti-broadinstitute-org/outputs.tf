output "name_servers" {
  description = "Name servers for the managed zone - provide these to IT for NS record delegation"
  value       = google_dns_managed_zone.sabeti_broadinstitute_org.name_servers
}

output "dns_name" {
  description = "The DNS name of this managed zone"
  value       = google_dns_managed_zone.sabeti_broadinstitute_org.dns_name
}

output "zone_id" {
  description = "The ID of the managed zone"
  value       = google_dns_managed_zone.sabeti_broadinstitute_org.id
}
