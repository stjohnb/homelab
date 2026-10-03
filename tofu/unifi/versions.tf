terraform {
  required_version = ">= 1.6.0"

  required_providers {
    unifi = {
      source = "filipowm/unifi"
      # Exact pin. A bump must arrive as a reviewable Renovate diff together
      # with a regenerated .terraform.lock.hcl.
      version = "1.1.0"
    }
  }
}
