terraform {
  backend "atlas" {
    name    = "aklaas/google-demo"
    address = "https://atlas.hashicorp.com"
  }
}

provider "google" {
  credentials = "${file("google_creds.json")}"
  project     = "${var.project}"
  region      = "us-central1"
}

resource "google_compute_instance" "nomadagent" {
  name         = "nomadagent${count.index}"
  machine_type = "n1-standard-1"
  count = "3"
  can_ip_forward = true
  zone         = "us-central1-a"
  project     = "${var.project}"

  tags = [
    "nomadagent${count.index}",
  ]

  disk {
    image = "google-ubuntu-1502641418"
  }

  network_interface {
    network = "${var.network}"

    access_config {
      // Ephemeral IP
    }
  }

  metadata {
    sshKeys = "aklaas:${file("/Users/andrewklaas/.ssh/id_rsa.pub")}"
  }

  metadata_startup_script ="${file("scripts/setup_consul_server.sh")}"


}

output "consul_ui" {
  value = "http://${google_compute_instance.nomadagent.0.network_interface.0.access_config.0.assigned_nat_ip}:8500/ui/"
}

resource "google_compute_firewall" "default" {
  name    = "test-firewall"
  network = "default"
  allow {
    protocol = "icmp"
  }

  allow {
    protocol = "tcp"
    ports    = ["22","80", "8080", "1000-2000", "9999", "9998", "8500" ]
  }
}

output "nomad_public_ips" {
  value = "${google_compute_instance.nomadagent.*.network_interface.0.access_config.0.assigned_nat_ip}"
}
output "nomad_private_ips" {
  value = "${google_compute_instance.nomadagent.*.network_interface.0.address}"
}
