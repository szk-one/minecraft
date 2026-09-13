# 監視構成: Cloud Monitoring への集約

- 更新日: 2026-09-11
- 対象: [改善調査レポート](improvement-review.md) の **E. 監視スタックの整理**

## 変更の要点

VM 上で常時稼働していた **Prometheus / Grafana / node-exporter の 3 コンテナを削除**し、
**Ops Agent + Cloud Monitoring** に寄せた。

| | 変更前 | 変更後 |
| --- | --- | --- |
| ホストメトリクス | node-exporter (コンテナ) | Ops Agent の `hostmetrics` (既定パイプライン) |
| Minecraft メトリクス | Prometheus がコンテナ間で scrape | Ops Agent の `prometheus` receiver が `localhost:19565` を scrape |
| 保存先 | VM 内の `/mnt/minecraft/prometheus` | Cloud Monitoring (`prometheus.googleapis.com/*`, `agent.googleapis.com/*`) |
| 可視化 | Grafana (`http://<IP>:3000`) | Cloud Monitoring ダッシュボード "Minecraft Overview" |
| サーバーログ | `docker logs` を SSH で見る | Cloud Logging (`/mnt/minecraft/server/logs/latest.log` を転送) |
| 公開ポート | 25565, 3000, 9090 | **25565 のみ** |

ダッシュボードの URL は `terraform output monitoring_dashboard_url` で取得できる。

## コストへの効果

- **RAM**: Prometheus + Grafana + node-exporter の常駐分（0.5〜1GB）が空く。
  これにより `machine_type` のダウンサイジング（調査レポート C）が現実的になる。
  ダウンサイジングは `machine_type` / `mc_memory` 変数で行う（下記参照）。
- **ディスク IO / 容量**: Prometheus の TSDB 書き込みが 10GB の `pd-standard` から消える。
  旧データの削除は任意（[旧データの削除](#旧データの削除)を参照）。
- **Cloud Monitoring 側の課金**: Ops Agent (`agent.googleapis.com`) と Prometheus 由来の
  メトリクスはいずれも課金対象だが、請求先アカウントあたり月 150 MiB の無料枠がある。
  この規模（VM 1 台 + `mc_*` メトリクスのみ・60 秒間隔）なら無料枠内〜月 $1 未満に収まる見込み。
  実測は [指標管理ページ](https://console.cloud.google.com/monitoring/metrics-management) で確認できる。

### ダウンサイジングの手順

監視スタックを降ろした後、`deploy/terraform.tfvars` で以下を指定して `terraform apply` する。

```hcl
machine_type = "n2-custom-4-12288"  # 4vCPU/12GB
mc_memory    = "8G"
```

`mc_memory` は必ず `machine_type` のメモリより十分小さくすること（OS + Docker + Ops Agent の分を残す）。

## 取り込みメトリクスの絞り込み

`metric_relabel_configs` で `mc_*` と `up`（scrape 成否）以外（mod が出す JVM 内部メトリクスなど）を落としている。
さらに絞る場合は `startup.sh.tftpl` の `regex` を編集する。
scrape 間隔は `metrics_scrape_interval` 変数（既定 60s、最小 10s）で調整する。
**間隔を短くするとサンプル数に比例して課金が増える**ので、下げる前に指標管理ページで実測すること。

## 認証

Ops Agent が書き込むために VM 用サービスアカウント `mc-server` を新設し、以下を付与している。

- `roles/monitoring.metricWriter`
- `roles/logging.logWriter`
- `roles/stackdriver.resourceMetadata.writer`

従来 VM にはサービスアカウントが一切付いていなかったため、この追加は必須。
サービスアカウントの差し替えにはインスタンス停止が要るので、
`allow_stopping_for_update = true` を入れてある（初回 apply で VM が一度停止する）。

## 移行時の注意

1. **初回 apply で VM が停止・再起動する。** プレイヤーがいない時間に実施すること。
2. 旧コンテナは起動スクリプトの `docker compose up -d --remove-orphans` と、
   名前指定の `docker rm -f` で掃除される。
3. Grafana に貯めた履歴は移行されない。必要なら apply 前にエクスポートしておくこと。
4. 旧データディレクトリ (`/mnt/minecraft/prometheus`, `/mnt/minecraft/grafana`) は
   既定では残る。削除方法は下記。

## 旧データの削除

`purge_legacy_monitoring_data` は **起動スクリプトが実行されたときにだけ評価される**。
`metadata_startup_script` を変更する apply はインスタンスメタデータを書き換えるだけで、
**起動スクリプトの再実行も VM の再起動もしない**。つまり apply だけでは削除されない。

確実なのは以下のどちらか。

### A. 初回移行と同時に消す（推奨・追加操作なし）

この移行の初回 apply はサービスアカウント追加のため VM を必ず停止・起動する。
そのタイミングなら起動スクリプトが走るので、最初から `true` にしておけば 1 回で済む。

```hcl
# deploy/terraform.tfvars
purge_legacy_monitoring_data = true
```

apply 後に `false` へ戻しておくこと（残しておくと以降の再起動のたびに `rm -rf` が走る）。

### B. 移行後に消す

apply でメタデータを更新したうえで、VM を明示的に停止・起動する。
`reset` ではなく `stop` → `start` を使うこと（shutdown script が走り、ワールドが正しく保存される）。

```bash
terraform -chdir=deploy apply -var 'purge_legacy_monitoring_data=true'
gcloud compute instances stop mc-server --zone us-central1-a
gcloud compute instances start mc-server --zone us-central1-a
```

その後 `purge_legacy_monitoring_data` を `false` に戻して apply する。

### C. SSH で直接消す

Terraform を経由せず消すだけなら、これが最短。

```bash
gcloud compute ssh mc-server --zone us-central1-a --tunnel-through-iap \
  --command 'sudo rm -rf /mnt/minecraft/prometheus /mnt/minecraft/grafana /mnt/minecraft/grafana-admin-password /mnt/minecraft/compose/grafana /mnt/minecraft/compose/prometheus.yml'
```

## ダッシュボードの中身

`google/compute_engine/dashboards/minecraft-overview.json` が Terraform 管理の実体。
Grafana 版のパネルをそのまま移植している。

| パネル | クエリ種別 |
| --- | --- |
| 現在のTPS / TPS 推移 / MSPT | PromQL (`mc_server_tick_seconds_*`) |
| 接続プレイヤー数・推移 | PromQL (`mc_player_list`) |
| 読み込みチャンク数 / ディメンション別 | PromQL (`mc_dimension_chunks_loaded`) |
| エンティティ数 | PromQL (`mc_entities_total`) |
| ホスト CPU / メモリ / ディスク使用率 | `agent.googleapis.com/*` のフィルタ |

> Grafana 版の TPS パネルは `clamp_max(20, <式>)` と引数順が逆で、PromQL としては不正だった
> （第 1 引数は instant-vector）。移植にあたり `clamp_max(<式>, 20)` に修正している。

コンソールで編集した内容は Terraform 管理外になる。恒久的な変更は JSON を直して apply すること。

## 参考リンク

- [Collect Prometheus metrics | Ops Agent](https://cloud.google.com/monitoring/agent/ops-agent/prometheus)
- [Pricing | Google Cloud Observability](https://cloud.google.com/products/observability/pricing)
- [View and manage metric usage | Cloud Monitoring](https://docs.cloud.google.com/monitoring/docs/metrics-management)
