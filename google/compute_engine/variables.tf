variable "project_id" {}
variable "region" {}
variable "zone" {}

variable "mc_allowed_source_ranges" {
  description = "CIDR ranges allowed to access Minecraft server"
  type = list(string)
  # 本番では自宅回線のIPだけに絞る
  default = ["0.0.0.0/0"]
}
