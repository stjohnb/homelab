provider "unifi" {
  api_url = var.api_url
  site    = var.site

  # The console presents its own self-signed certificate on the LAN address.
  allow_insecure = true

  # Credentials are deliberately unset here: the provider reads them from the
  # runner's environment, supplied by the unifi-tofu-credentials Secret via
  # envFrom. Either UNIFI_USERNAME + UNIFI_PASSWORD (what is in use today) or
  # UNIFI_API_KEY works. See docs/unifi.md.
}
