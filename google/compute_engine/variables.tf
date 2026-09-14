variable "project_id" {}
variable "region" {}
variable "zone" {}

variable "machine_type" {
  description = "Minecraft サーバー VM のマシンタイプ。監視スタックを VM から降ろしたため、メモリを削ったタイプに落とせる。"
  type        = string
  default     = "n2-standard-4"
}

variable "mc_memory" {
  description = "Minecraft サーバーに割り当てる JVM ヒープ。machine_type のメモリより十分小さい値にすること。"
  type        = string
  default     = "10G"
}

variable "mc_allowed_source_ranges" {
  description = "CIDR ranges allowed to access Minecraft server"
  type = list(string)
  # 本番では自宅回線のIPだけに絞る
  default = ["0.0.0.0/0"]
}

variable "packwiz_url" {
  description = "公開された packwiz pack.toml の URL (例: GitHub Pages)"
  type        = string
  default = "https://szk-one.github.io/minecraft/pack.toml"
}

variable "rcon_password" {
  description = "Minecraft サーバーの RCON パスワード。空の場合は起動スクリプトで自動生成します。"
  type        = string
  default     = ""
}

variable "discord_webhook_url" {
  description = "サーバー起動通知を送信する Discord Webhook の URL"
  type        = string
  default     = ""
}

variable "metrics_scrape_interval" {
  description = "Ops Agent が Minecraft の Prometheus エンドポイントを取得する間隔。短くすると Cloud Monitoring の取り込み課金が増える。"
  type        = string
  default     = "60s"

  validation {
    # Ops Agent の下限は 10 秒。これを下回る値は黙って 10 秒に切り上げられるうえ、
    # 書式ミスは Ops Agent が起動時に失敗するまで気づけないので apply 時に弾く。
    condition     = can(regex("^[0-9]+s$", var.metrics_scrape_interval)) && tonumber(trimsuffix(var.metrics_scrape_interval, "s")) >= 10
    error_message = "metrics_scrape_interval は秒単位の文字列 (例: \"60s\") で、Ops Agent の下限である 10 秒以上を指定してください。"
  }
}

variable "purge_legacy_monitoring_data" {
  description = "true にすると、旧 Prometheus / Grafana のデータディレクトリを起動スクリプトが削除してデータディスクを解放します。"
  type        = bool
  default     = false
}

variable "enable_autostop" {
  description = "誰も接続していないときに Minecraft を終了し、VM ごと停止するか。コスト削減の主役。"
  type        = bool
  default     = true
}

variable "autostop_timeout_est" {
  description = "最後のプレイヤーが退出してからサーバーを終了するまでの秒数 (itzg の AUTOSTOP_TIMEOUT_EST)。"
  type        = number
  default     = 1200

  validation {
    condition     = var.autostop_timeout_est >= 60
    error_message = "autostop_timeout_est は 60 秒以上にしてください。短すぎると再接続のたびに停止・起動を繰り返します。"
  }
}

variable "autostop_timeout_init" {
  description = "サーバー起動後、誰も接続しないまま終了するまでの秒数 (itzg の AUTOSTOP_TIMEOUT_INIT)。Mod の読み込み時間より十分長くすること。"
  type        = number
  default     = 900

  validation {
    condition     = var.autostop_timeout_init >= 300
    error_message = "autostop_timeout_init は 300 秒以上にしてください。Mod の読み込み中に停止してしまいます。"
  }
}

variable "backup_interval" {
  description = "mc-backup のバックアップ間隔。24/7 稼働ではなくなるため、既定の 24h だとセッション中に一度も走らない。"
  type        = string
  default     = "2h"
}

variable "prune_backups_days" {
  description = "バックアップを保持する日数。10GB のデータディスクを溢れさせないために明示する。"
  type        = number
  default     = 7
}

variable "enable_wake_proxy" {
  description = <<-EOT
    常時稼働の待ち受けプロキシ VM を建てるか。
    停止中の Minecraft VM の代わりに 25565 を受け、参加操作を合図に VM を起動する。
    true の場合、プレイヤーの接続先は Minecraft VM ではなくこのプロキシの外部 IP
    (terraform output minecraft_connect_address) になり、Minecraft VM 側の 25565 は
    サブネット内からのみ開放される。
  EOT
  type        = bool
  default     = true
}

variable "wake_proxy_machine_type" {
  description = "待ち受けプロキシのマシンタイプ。既定の e2-micro は us-central1/us-west1/us-east1 で無料枠の対象。"
  type        = string
  default     = "e2-micro"
}

variable "wake_proxy_start_cooldown" {
  description = "待ち受けプロキシが VM 起動を要求してから、次の起動要求を受け付けるまでの秒数。"
  type        = number
  default     = 120
}

variable "wake_proxy_install_ops_agent" {
  description = "待ち受けプロキシに Ops Agent を入れて、起動要求のログを Cloud Logging に送るか。ホストメトリクスは送らない。"
  type        = bool
  default     = true
}
