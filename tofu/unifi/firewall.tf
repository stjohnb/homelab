resource "unifi_firewall_zone" "iot" {
  name     = "IoT"
  networks = [unifi_network.iot.id]
}

resource "unifi_firewall_zone_policy" "iot_to_internet" {
  name        = "IoT to Internet"
  enabled     = true
  action      = "ALLOW"
  description = "IoT devices may reach the internet."

  source = {
    zone_id = unifi_firewall_zone.iot.id
  }
  destination = {
    zone_id = data.unifi_firewall_zone.external.id
  }

  auto_allow_return_traffic = true
}

resource "unifi_firewall_zone_policy" "iot_to_gateway_dns" {
  name        = "IoT to Gateway DNS"
  enabled     = true
  action      = "ALLOW"
  description = "IoT devices may resolve names against the gateway."
  protocol    = "tcp_udp"

  source = {
    zone_id = unifi_firewall_zone.iot.id
  }
  destination = {
    zone_id = data.unifi_firewall_zone.gateway.id
    port    = 53
  }

  auto_allow_return_traffic = true
}

resource "unifi_firewall_zone_policy" "iot_to_gateway_dhcp" {
  name        = "IoT to Gateway DHCP"
  enabled     = true
  action      = "ALLOW"
  description = "IoT devices may obtain a DHCP lease from the gateway."
  protocol    = "udp"

  source = {
    zone_id = unifi_firewall_zone.iot.id
  }
  destination = {
    zone_id = data.unifi_firewall_zone.gateway.id
    port    = 67
  }

  auto_allow_return_traffic = true
}

resource "unifi_firewall_zone_policy" "iot_to_gateway_block" {
  name        = "IoT to Gateway block"
  enabled     = true
  action      = "BLOCK"
  description = "Everything else IoT sends at the gateway — the console UI included."

  source = {
    zone_id = unifi_firewall_zone.iot.id
  }
  destination = {
    zone_id = data.unifi_firewall_zone.gateway.id
  }
}

resource "unifi_firewall_zone_policy" "iot_to_ha_mqtt" {
  name        = "IoT to Home Assistant MQTT"
  enabled     = true
  action      = "ALLOW"
  description = "The single hole in the trusted LAN: the Home Assistant MQTT broker."
  protocol    = "tcp"

  source = {
    zone_id = unifi_firewall_zone.iot.id
  }
  destination = {
    zone_id = data.unifi_firewall_zone.internal.id
    ips     = [var.mqtt_host]
    port    = var.mqtt_port
  }

  auto_allow_return_traffic = true
}

resource "unifi_firewall_zone_policy" "iot_to_lan_block" {
  name        = "IoT to LAN block"
  enabled     = true
  action      = "BLOCK"
  description = "IoT devices may not otherwise initiate connections to the trusted LAN."

  source = {
    zone_id = unifi_firewall_zone.iot.id
  }
  destination = {
    zone_id = data.unifi_firewall_zone.internal.id
  }
}

resource "unifi_firewall_zone_policy" "lan_to_iot" {
  name        = "LAN to IoT"
  enabled     = true
  action      = "ALLOW"
  description = "The trusted LAN may initiate connections to IoT devices."

  source = {
    zone_id = data.unifi_firewall_zone.internal.id
  }
  destination = {
    zone_id = unifi_firewall_zone.iot.id
  }

  auto_allow_return_traffic = true
}

# Policy evaluation order. `index` on a zone policy is controller-assigned and
# read-only, so this is the only supported way to make ordering deterministic
# — and ordering is load-bearing here: the MQTT hole must be evaluated before
# the IoT -> LAN catch-all block, and the two gateway allows before the
# gateway block. Both lists run before the controller's predefined policies
# for their zone pair.
#
# Attribute names verified against `tofu providers schema -json` for
# filipowm/unifi v1.1.0. The resource is flagged experimental upstream and
# needs UniFi OS 9.0.0 with the zone-based firewall migrated — the same
# requirement the zone policies above already carry.
resource "unifi_firewall_zone_policy_order" "iot_to_gateway" {
  source_zone_id      = unifi_firewall_zone.iot.id
  destination_zone_id = data.unifi_firewall_zone.gateway.id

  before_predefined_ids = [
    unifi_firewall_zone_policy.iot_to_gateway_dns.id,
    unifi_firewall_zone_policy.iot_to_gateway_dhcp.id,
    unifi_firewall_zone_policy.iot_to_gateway_block.id,
  ]
}

resource "unifi_firewall_zone_policy_order" "iot_to_internal" {
  source_zone_id      = unifi_firewall_zone.iot.id
  destination_zone_id = data.unifi_firewall_zone.internal.id

  before_predefined_ids = [
    unifi_firewall_zone_policy.iot_to_ha_mqtt.id,
    unifi_firewall_zone_policy.iot_to_lan_block.id,
  ]
}

# No mDNS reflector: discovery across the two networks is off by default and
# only gets enabled if Cast/HomeKit from the trusted side turns out to be wanted.
