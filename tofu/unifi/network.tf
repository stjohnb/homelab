# The isolated IoT network. purpose = "corporate", NOT "guest": a guest network
# adds a captive portal and client isolation, which would stop IoT devices
# reaching the Home Assistant MQTT broker.
resource "unifi_network" "iot" {
  name    = "IoT"
  purpose = "corporate"

  network_group = "LAN"
  subnet        = var.iot_subnet
  vlan_id       = var.iot_vlan_id

  internet_access_enabled = true

  dhcp_enabled = true
  dhcp_start   = "192.168.20.100"
  dhcp_stop    = "192.168.20.254"
  dhcp_lease   = 86400
}
