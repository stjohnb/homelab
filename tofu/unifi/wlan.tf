resource "unifi_wlan" "iot" {
  name       = var.iot_ssid
  network_id = unifi_network.iot.id

  # WPA2-PSK. Plenty of IoT hardware cannot associate with WPA3, and the
  # transition mode confuses more of it still.
  security        = "wpapsk"
  passphrase      = var.iot_wifi_passphrase
  wpa3_support    = false
  wpa3_transition = false
  pmf_mode        = "disabled"

  user_group_id = data.unifi_user_group.default.id
  ap_group_ids  = [data.unifi_ap_group.default.id]

  # 2.4 GHz only — the band every one of these devices actually speaks.
  # wlan_bands, not the legacy single-valued wlan_band it supersedes.
  wlan_bands = ["2g"]

  # Devices must be able to reach the Home Assistant broker, so no L2 isolation.
  l2_isolation = false
  hide_ssid    = false
}
