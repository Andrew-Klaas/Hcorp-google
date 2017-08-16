
variable "environment_name" {
  type = "string"
}

variable "os" {
  type = "string"
}

variable "consul_server_count" {
  type = "string"
}

variable "project" {
  type = "string"
}

variable "image" {
  type = "string"
}

variable "network" {
  type = "string"
}

variable "user" {
  type = "string"
}

variable "public_key" {
  type = "string"
}

variable "creds" {
 type = "string"
}

variable "region" {
  type = "string"
}

variable "zone" {
  type = "string"
}

#Outputs
output "nomad_public_ips" {
  value = "${google_compute_instance.nomadagent.*.network_interface.0.access_config.0.assigned_nat_ip}"

}
output "nomad_server_addresses" {
  value = "${formatlist("ssh://%s", google_compute_instance.nomadagent.*.network_interface.0.access_config.0.assigned_nat_ip)}"
}

output "nomad_private_ips" {
  value = "${google_compute_instance.nomadagent.*.network_interface.0.address}"
}
output "consul_ui" {
  value = "http://${google_compute_instance.nomadagent.0.network_interface.0.access_config.0.assigned_nat_ip}:8500/ui/"
}
