terraform {
  required_version = ">= 1.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
}

resource "google_dns_managed_zone" "sabeti_broadinstitute_org" {
  name        = "sabeti-broadinstitute-org"
  dns_name    = "sabeti.broadinstitute.org."
  description = "Managed zone for sabeti.broadinstitute.org subdomain"

  dnssec_config {
    state = "on"

    default_key_specs {
      algorithm  = "rsasha256"
      key_length = 2048
      key_type   = "keySigning"
    }

    default_key_specs {
      algorithm  = "rsasha256"
      key_length = 1024
      key_type   = "zoneSigning"
    }
  }
}

resource "google_dns_record_set" "chat" {
  name         = "chat.sabeti.broadinstitute.org."
  managed_zone = google_dns_managed_zone.sabeti_broadinstitute_org.name
  type         = "CNAME"
  ttl          = 300
  rrdatas      = ["ghs.googlehosted.com."]
}

resource "google_dns_record_set" "carmen_analysis" {
  name         = "carmen-analysis.sabeti.broadinstitute.org."
  managed_zone = google_dns_managed_zone.sabeti_broadinstitute_org.name
  type         = "CNAME"
  ttl          = 300
  rrdatas      = ["ghs.googlehosted.com."]
}

resource "google_dns_record_set" "google_site_verification" {
  name         = "sabeti.broadinstitute.org."
  managed_zone = google_dns_managed_zone.sabeti_broadinstitute_org.name
  type         = "TXT"
  ttl          = 300
  rrdatas      = ["google-site-verification=xuEG5vQyP01V9Beeqwe8WmW-Xq0IzPbUvUvLv1f1STQ"]
}
