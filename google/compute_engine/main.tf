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
  project = var.project_id
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

# Ops Agent が Cloud Monitoring / Cloud Logging へ書き込むためのサービスアカウント。
# メトリクスは VM 内の Prometheus/Grafana ではなく Cloud Monitoring に集約する。
resource "google_service_account" "mc_server" {
  project      = var.project_id
  account_id   = "mc-server"
  display_name = "Minecraft server VM"
}

resource "google_project_iam_member" "mc_server_metric_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.mc_server.email}"
}

resource "google_project_iam_member" "mc_server_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.mc_server.email}"
}

resource "google_project_iam_member" "mc_server_metadata_writer" {
  project = var.project_id
  role    = "roles/stackdriver.resourceMetadata.writer"
  member  = "serviceAccount:${google_service_account.mc_server.email}"
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
  machine_type = var.machine_type
  zone = var.zone
  tags = ["mc-server"]
  # サービスアカウントの差し替えにはインスタンス停止が必要
  allow_stopping_for_update = true
  metadata_startup_script = templatefile(
    "${path.module}/templates/startup.sh.tftpl",
    {
      packwiz_url                  = var.packwiz_url
      rcon_password                = var.rcon_password
      discord_webhook_url          = var.discord_webhook_url
      mc_memory                    = var.mc_memory
      metrics_scrape_interval      = var.metrics_scrape_interval
      purge_legacy_monitoring_data = var.purge_legacy_monitoring_data
    }
  )
  metadata = {
    shutdown-script = templatefile("${path.module}/templates/shutdown.sh.tftpl", {})
  }

  service_account {
    email = google_service_account.mc_server.email
    scopes = [
      "https://www.googleapis.com/auth/monitoring.write",
      "https://www.googleapis.com/auth/logging.write",
    ]
  }

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
  # Spot VM。legacy preemptible と料金は同じだが 24 時間の強制停止上限がない。
  # SPOT 指定には preemptible = true / automatic_restart = false が必須。
  scheduling {
    provisioning_model = "SPOT"
    preemptible        = true
    automatic_restart  = false
    # プリエンプト時は DELETE ではなく STOP。ブートディスクを保持したまま再起動できる。
    instance_termination_action = "STOP"
    on_host_maintenance         = "TERMINATE"
  }

  # VM 起動時点で Ops Agent が書き込めるよう、IAM 付与を先行させる
  depends_on = [
    google_project_iam_member.mc_server_metric_writer,
    google_project_iam_member.mc_server_log_writer,
    google_project_iam_member.mc_server_metadata_writer,
  ]
}

# Grafana ダッシュボードの置き換え。コンソールから閲覧する。
resource "google_monitoring_dashboard" "minecraft_overview" {
  project        = var.project_id
  dashboard_json = file("${path.module}/dashboards/minecraft-overview.json")
}
