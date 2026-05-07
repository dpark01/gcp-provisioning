# sabeti.broadinstitute.org DNS Zone

This directory contains Terraform configuration for managing the Cloud DNS zone for the `sabeti.broadinstitute.org` subdomain.

## Overview

- **Subdomain**: `sabeti.broadinstitute.org`
- **GCP Project**: `sabeti-mgmt`
- **Managed Zone Name**: `sabeti-broadinstitute-org`
- **DNSSEC**: Enabled

## Current Nameservers

The following nameservers are assigned by Google Cloud DNS:

1. `ns-cloud-a1.googledomains.com.`
2. `ns-cloud-a2.googledomains.com.`
3. `ns-cloud-a3.googledomains.com.`
4. `ns-cloud-a4.googledomains.com.`

## IT Request for NS Record Delegation

To complete the DNS setup, the Broad IT team needs to add the following **NS records** to the parent `broadinstitute.org` zone:

**Record Type**: NS  
**Name**: `sabeti.broadinstitute.org`  
**Values**:
- `ns-cloud-a1.googledomains.com.`
- `ns-cloud-a2.googledomains.com.`
- `ns-cloud-a3.googledomains.com.`
- `ns-cloud-a4.googledomains.com.`

These NS records delegate authority for the `sabeti.broadinstitute.org` subdomain to Google Cloud DNS.

## Usage

### Prerequisites

1. Ensure you have the Google Cloud CLI installed and authenticated
2. Ensure Terraform is installed (version >= 1.0)
3. Ensure you have appropriate permissions on the `sabeti-mgmt` project

### Initialize Terraform

```bash
cd dns/sabeti-broadinstitute-org
terraform init
```

### Import Existing Zone

Since the zone was created manually via gcloud, import it into Terraform state:

```bash
terraform import google_dns_managed_zone.sabeti_broadinstitute_org sabeti-mgmt/sabeti-broadinstitute-org
```

### View Current Configuration

```bash
terraform plan
```

### Apply Changes

```bash
terraform apply
```

### View Outputs

To see the current nameservers:

```bash
terraform output name_servers
```

## Adding DNS Records

To add DNS records to this zone, create additional `google_dns_record_set` resources in `main.tf`. Example:

```hcl
resource "google_dns_record_set" "example_a_record" {
  managed_zone = google_dns_managed_zone.sabeti_broadinstitute_org.name
  name         = "www.sabeti.broadinstitute.org."
  type         = "A"
  ttl          = 300
  rrdatas      = ["1.2.3.4"]
}
```

## Verification

After IT adds the NS records, verify delegation is working:

```bash
# Check NS records from public DNS
dig NS sabeti.broadinstitute.org

# Check that a test record resolves (after adding one)
dig A test.sabeti.broadinstitute.org
```
