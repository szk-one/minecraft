resource "google_compute_network" "mc_vpc" {
  project = var.project_id
  name = "mc-vpc"
  auto_create_subnetworks = false
}
resource "google_compute_subnetwork" "mc_subnet" {
  project = var.project_id
  name = "mc-subnet"
  ip_cidr_range = "10.0.0.0/24"
  region = var.region
  network = google_compute_network.mc_vpc.id
}

resource "google_compute_firewall" "mc_firewall" {
  project = va.project_id
  name = "mc-allow-minecraft"
  network = google_compute_network.mc_vpc.id
  allow {
    protocol = "tcp"
    ports = ["25565"]
  }
  source_ranges = var.mc_allowed_source_ranges
  target_tags = ["mc-server"]
}
resource "google_compute_firewall" "allow_ssh" {
  project = var.project_id
  name = "allow-ssh"
  network = google_compute_network.mc_vpc.id
  allow {
    protocol = "tcp"
    ports = ["22"]
  }
  # Restrict SSH to Google Cloud IAP TCP forwarding range
  # Ref: https://cloud.google.com/iap/docs/using-tcp-forwarding#iap-ip
  source_ranges = ["35.235.240.0/20"]
  target_tags = ["mc-server"]
}

resource "google_compute_disk" "mc_data_disk" {
  project = var.project_id
  name = "mc-data-disk"
  type = "pd-standard"
  zone = var.zone
  size = 10
}
resource "google_compute_instance" "mc_server" {
  project = var.project_id
  name = "mc-server"
  machine_type = "e2-standard-2"
  zone = var.zone
  tags = ["mc-server"]

  boot_disk {
    initialize_params {
      image = "projects/debian-cloud/global/images/family/debian-12"
      size = 10
      type = "pd-standard"
    }
  }
  attached_disk {
    source = google_compute_disk.mc_data_disk.id
    device_name = "mc-data-disk"
    mode = "READ_WRITE"
  }
  network_interface {
    network = google_compute_network.mc_vpc.id
    subnetwork = google_compute_subnetwork.mc_subnet.id
    access_config {}
  }
  scheduling {
    preemptible = true
    automatic_restart = false
    on_host_maintenance = "TERMINATE"
  }
}
