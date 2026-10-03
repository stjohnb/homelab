# Read-only references to everything that already exists in the console. The
# pre-existing LAN and the built-in firewall zones are NOT managed here — see
# the no-bulk-import rule in docs/unifi.md.
data "unifi_network" "lan" {
  name = "Default"
}

data "unifi_firewall_zone" "internal" {
  name = "Internal"
}

data "unifi_firewall_zone" "external" {
  name = "External"
}

data "unifi_firewall_zone" "gateway" {
  name = "Gateway"
}

data "unifi_user_group" "default" {
  name = "Default"
}

data "unifi_ap_group" "default" {
  name = "All APs"
}
