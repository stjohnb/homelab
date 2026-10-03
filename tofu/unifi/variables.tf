variable "api_url" {
  description = "Base URL of the UniFi console (no /api suffix)."
  type        = string
  default     = "https://192.168.0.1"
}

variable "site" {
  description = "UniFi site name."
  type        = string
  default     = "default"
}

variable "iot_vlan_id" {
  description = "VLAN ID for the isolated IoT network."
  type        = number
  default     = 20
}

variable "iot_subnet" {
  description = "CIDR of the IoT network."
  type        = string
  default     = "192.168.20.0/24"
}

variable "iot_ssid" {
  description = "SSID broadcast on the IoT network."
  type        = string
  default     = "IoT"
}

variable "iot_wifi_passphrase" {
  description = "WPA2 passphrase for the IoT SSID. Supplied through spec.varsFrom on the Terraform CR, from key `iot_wifi_passphrase` of the unifi-tofu-credentials Secret. NOT via TF_VAR_ in the runner environment — terraform-exec rejects any TF_VAR_* env var."
  type        = string
  sensitive   = true

  validation {
    # varsFrom turns a missing Secret key into "" rather than an error, so
    # guard it here: an empty value almost always means the Secret key is not
    # named `iot_wifi_passphrase`.
    condition     = length(var.iot_wifi_passphrase) >= 8 && length(var.iot_wifi_passphrase) <= 63
    error_message = "iot_wifi_passphrase must be 8-63 characters (WPA2-PSK). Empty usually means the unifi-tofu-credentials Secret key is misnamed."
  }
}

variable "mqtt_host" {
  description = "Home Assistant address on the trusted LAN, the only trusted-LAN host IoT devices may reach."
  type        = string
  default     = "192.168.0.89"
}

variable "mqtt_port" {
  description = "Home Assistant MQTT broker port."
  type        = number
  default     = 1883
}
