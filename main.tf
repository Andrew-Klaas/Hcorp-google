provider "google" {
  credentials = "${var.creds}"
  project     = "${var.project}"
  region      = "${var.region}"
}

resource "google_compute_instance" "nomadagent" {
  name         = "nomadagent${count.index}"
  machine_type = "n1-standard-2"
  count = "3"
  can_ip_forward = true
  zone         = "${var.zone}"
  project     = "${var.project}"

  tags = [
    "nomadagent${count.index}",
  ]

  disk {
    image = "${var.image}"
  }

  network_interface {
    network = "${var.network}"

    access_config {
      // Ephemeral IP
    }
  }

  metadata {
    sshKeys = "${var.user}:${var.public_key}"
  }

  metadata_startup_script ="${file("scripts/setup.sh")}"


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
