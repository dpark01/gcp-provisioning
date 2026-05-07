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
