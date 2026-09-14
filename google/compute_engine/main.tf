locals {
  # インスタンス名はリテラルで持つ。wake proxy は「Minecraft VM の内部 DNS 名」を
  # 設定に埋め込み、Minecraft VM は Discord 通知のために wake proxy の外部 IP を
  # 参照するので、両者をリソース属性で相互参照すると循環参照になる。
  mc_instance_name = "mc-server"

  # GCE のゾーン内部 DNS 名。VM が停止していて名前が引けない場合、wake proxy 側は
  # 接続失敗として扱い「停止中」と判断するので、それで問題ない。
  mc_internal_dns = "${local.mc_instance_name}.${var.zone}.c.${var.project_id}.internal"

  # count = 0 のときは null になる。
  wake_proxy_ip = one(google_compute_instance.mc_proxy[*].network_interface[0].access_config[0].nat_ip)

  # プレイヤーに案内する接続先。wake proxy があればそちらが固定の窓口になる。
  connect_address = local.wake_proxy_ip == null ? "" : "${local.wake_proxy_ip}:25565"
}

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
  # wake proxy を使う場合、プレイヤーはプロキシ経由で入るので、Minecraft VM の
  # 25565 はサブネット内 (= プロキシ) からだけ開ければよい。
  source_ranges = var.enable_wake_proxy ? [google_compute_subnetwork.mc_subnet.ip_cidr_range] : var.mc_allowed_source_ranges
  target_tags = ["mc-server"]
}

# プレイヤーが実際に接続する先。常時稼働の wake proxy が受ける。
resource "google_compute_firewall" "mc_proxy_firewall" {
  count   = var.enable_wake_proxy ? 1 : 0
  project = var.project_id
  name    = "mc-allow-wake-proxy"
  network = google_compute_network.mc_vpc.id
  allow {
    protocol = "tcp"
    ports    = ["25565"]
  }
  source_ranges = var.mc_allowed_source_ranges
  target_tags   = ["mc-proxy"]
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
  target_tags = ["mc-server", "mc-proxy"]
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

# wake proxy 用のサービスアカウント。Minecraft VM を起動する権限だけを持つ。
resource "google_service_account" "mc_proxy" {
  count        = var.enable_wake_proxy ? 1 : 0
  project      = var.project_id
  account_id   = "mc-wake-proxy"
  display_name = "Minecraft wake proxy VM"
}

# プロジェクト全体ではなく mc-server インスタンス 1 台にだけ紐づける。
# instanceAdmin.v1 には start のほかに stop/delete も含まれるが、対象は
# この 1 インスタンスに限定される。ワールドは別ディスクなので、最悪の場合でも
# VM の再作成で復帰できる。
resource "google_compute_instance_iam_member" "mc_proxy_instance_admin" {
  count         = var.enable_wake_proxy ? 1 : 0
  project       = var.project_id
  zone          = var.zone
  instance_name = local.mc_instance_name
  role          = "roles/compute.instanceAdmin.v1"
  member        = "serviceAccount:${google_service_account.mc_proxy[0].email}"

  # local.mc_instance_name はリテラルなので、暗黙の依存が張られない
  depends_on = [google_compute_instance.mc_server]
}

# サービスアカウントが紐づいた VM を起動するには actAs が要る。
resource "google_service_account_iam_member" "mc_proxy_act_as_mc_server" {
  count              = var.enable_wake_proxy ? 1 : 0
  service_account_id = google_service_account.mc_server.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.mc_proxy[0].email}"
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
  name = local.mc_instance_name
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
      enable_autostop              = var.enable_autostop
      autostop_timeout_est         = var.autostop_timeout_est
      autostop_timeout_init        = var.autostop_timeout_init
      backup_interval              = var.backup_interval
      prune_backups_days           = var.prune_backups_days
      connect_address              = local.connect_address
      autostop_check_script        = file("${path.module}/files/mc-autostop-check.sh")
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

# プレイヤーの窓口になる常時稼働の小さな VM。
# Minecraft VM が停止している間はステータス ping に「停止中」を返し、
# 参加操作を合図に Compute Engine API で Minecraft VM を起動する。
# 起動していれば TCP をそのまま中継するだけ。
#
# e2-micro / pd-standard 10GB / us-central1 / 非プリエンプティブルなので、
# GCP の無料枠 (対象リージョンで e2-micro 1 台 + 標準 PD 30GB/月) に収まる。
# 標準 PD は Minecraft VM の boot 10GB + data 10GB と合わせて 30GB ちょうど。
resource "google_compute_instance" "mc_proxy" {
  count        = var.enable_wake_proxy ? 1 : 0
  project      = var.project_id
  name         = "mc-wake-proxy"
  machine_type = var.wake_proxy_machine_type
  zone         = var.zone
  tags         = ["mc-proxy"]
  allow_stopping_for_update = true

  metadata_startup_script = templatefile(
    "${path.module}/templates/wake-proxy-startup.sh.tftpl",
    {
      wake_proxy_py     = file("${path.module}/files/wake-proxy.py")
      backend_host      = local.mc_internal_dns
      backend_port      = 25565
      listen_port       = 25565
      project_id        = var.project_id
      zone              = var.zone
      mc_instance_name  = local.mc_instance_name
      start_cooldown    = var.wake_proxy_start_cooldown
      install_ops_agent = var.wake_proxy_install_ops_agent
    }
  )

  service_account {
    email = google_service_account.mc_proxy[0].email
    # 実際に何ができるかは IAM 側 (mc-server インスタンスへの instanceAdmin) で絞る
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  boot_disk {
    initialize_params {
      image = "projects/debian-cloud/global/images/family/debian-12"
      size  = 10
      type  = "pd-standard"
    }
  }

  network_interface {
    network    = google_compute_network.mc_vpc.id
    subnetwork = google_compute_subnetwork.mc_subnet.id
    access_config {}
  }

  # プレイヤーの窓口なので Spot にはしない (無料枠の条件でもある)。
  scheduling {
    provisioning_model = "STANDARD"
    preemptible        = false
    automatic_restart  = true
  }

  # IAM 反映を待たずに起動してもプロキシは接続のたびに API を叩き直すので、
  # ここでは IAM に depends_on しない (張ると mc_server 経由で循環参照になる)。
}

# Grafana ダッシュボードの置き換え。コンソールから閲覧する。
resource "google_monitoring_dashboard" "minecraft_overview" {
  project        = var.project_id
  dashboard_json = file("${path.module}/dashboards/minecraft-overview.json")
}
