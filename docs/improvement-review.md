# インフラ / Mod 管理 改善調査レポート

- 調査日: 2026-09-11
- 対象コミット: `84f9cba` (version 1.2.5)
- 調査範囲: `deploy/`, `google/`, `packwiz/`, `.github/workflows/`

---

## 0. 現状サマリ

| 項目 | 現状 |
| --- | --- |
| VM | `n2-standard-4` (4vCPU/16GB)、**legacy preemptible**、`us-central1-a`、24/7 稼働 |
| ディスク | boot 10GB + data 10GB、どちらも `pd-standard` |
| 同居サービス | Minecraft (NeoForge 1.21.1 / heap 10G) + mc-backup + Ops Agent<br>（Prometheus / node-exporter / Grafana は [E](#e-監視スタックの整理-対応済み) で削除済み） |
| Mod 管理 | packwiz、**60 件すべて CurseForge ソース**、`side` は 61 件中 56 件が `both` |
| CI | `packwiz/` を GitHub Pages にそのままアップロードするのみ（`packwiz refresh` なし） |
| Terraform | プロバイダ未固定 / リモート state なし / lock ファイル未コミット |

概算コスト: **月 $50〜55**（n2-standard-4 Spot ≈ $0.066/h ≈ $48/月 + ディスク + 外部IP + 下り）

---

## 1. インフラコスト削減

### 削減見込みサマリ

| 項目 | 現状（概算/月） | 改善後 |
| --- | --- | --- |
| Compute | ~$48 | c4a Spot + 1日4h稼働 → **~$4** |
| ディスク | ~$0.8 | ~$1.5（pd-balanced 化） |
| 外部IP | ~$2–3 | 停止中は課金なし |
| 下り | 数ドル | Standard tier で実質 $0 |
| **合計** | **~$52–55** | **~$6–10** |

---

### A. 最優先: `preemptible` → Spot VM（コスト同額・リスクなし・即効）

`google/compute_engine/main.tf:122` がレガシーの preemptible 設定になっている。
Spot と料金は同じだが、**preemptible は 24 時間で強制停止**される。Spot にはその上限がない。

```hcl
scheduling {
  provisioning_model          = "SPOT"
  preemptible                 = true
  automatic_restart           = false
  on_host_maintenance         = "TERMINATE"
  instance_termination_action = "STOP"   # DELETE されず停止で済む
}
```

**効果**: 料金は変わらないが、24 時間ごとの強制停止がなくなる。

---

### B. 最大の削減幅: アイドル時の自動停止（削減率 60〜85%）

現在は誰も接続していなくても 24/7 課金されている。1 日 4 時間プレイなら compute は **$48 → 約 $8/月**。

itzg イメージの Auto-Stop を利用する。

```yaml
ENABLE_AUTOSTOP: "TRUE"
AUTOSTOP_TIMEOUT_EST: "1200"   # 最後の退出から20分で停止
AUTOSTOP_TIMEOUT_INIT: "900"   # 起動後15分誰も来なければ停止
```

#### 注意点

1. **`restart: unless-stopped` のままだと動かない。**
   自動停止したコンテナを Docker が即再起動してしまうため、minecraft サービスだけ `restart: "no"` にする必要がある。
2. **AUTOSTOP と AUTOPAUSE は排他。** 両方を有効にはできない。

#### VM ごと停止させる

コンテナ停止を検知して VM を落とす systemd timer を追加する。

```bash
[ "$(docker inspect -f '{{.State.Running}}' minecraft-server)" = "false" ] && poweroff
```

#### 起動側の選択肢

| 方式 | 備考 |
| --- | --- |
| Discord bot | 既に Discord 通知を使っているので導線が自然 |
| `gcloud compute instances start` | 最も単純。手動 |
| **無料枠 e2-micro に接続待ち受けプロキシ** | プレイヤーは「繋ぐだけ」。体験は最良 |

---

### C. マシンタイプ見直し（約半額）

- 現行 `n2-standard-4` (4vCPU/16GB) Spot ≈ **$48/月**
- `c4a-standard-4`（Axion Arm, 4vCPU/16GB）Spot ≈ **$24/月**
  - 半額かつシングルスレッド性能は同等以上。Minecraft はシングルスレッド律速なので相性が良い
  - **リスク**: arm64。itzg イメージはマルチアーチ対応だが、ネイティブライブラリを持つ mod があると動かない → **要検証**
- Arm を避ける場合: `n2-custom-4-12288` でメモリ 16→12GB に削るだけでも約 2 割減

あわせて `MEMORY: "10G"` も過大気味。監視スタック同居を考えると **8G** が現実的。

---

### D. ネットワーク Standard tier（下り実質 $0）

```hcl
access_config {
  network_tier = "STANDARD"
}
```

北米 Standard は **月 200GiB まで無料**（Premium は 1GiB）。

**トレードオフ**: Standard は Google バックボーンを使わないため、日本からのレイテンシは悪化方向。
プレイヤーが日本中心なら `us-central1`（RTT 120〜150ms）に留まる理由も薄いため、
**`asia-northeast1` への移設 + Standard tier** の方が総合的に良い可能性がある。
「コスト vs レイテンシ」の判断ポイント。

---

### E. 監視スタックの整理 【対応済み】

> **対応済み**: Cloud Monitoring に寄せる形で実装した。詳細は [監視構成ドキュメント](monitoring.md) を参照。

Prometheus + Grafana + node-exporter の常時稼働が RAM 0.5〜1GB とディスク IO を消費し、
**マシンサイズを押し上げる要因**になっていた。

「たまに見る」用途なので、3 コンテナを削除して **Ops Agent + Cloud Monitoring** に集約した。

- ホストメトリクス: Ops Agent の `hostmetrics`（node-exporter の代替）
- Minecraft メトリクス: Ops Agent の `prometheus` receiver が `localhost:19565` を scrape
- 可視化: Cloud Monitoring ダッシュボード「Minecraft Overview」（Grafana ダッシュボードを移植）
- サーバーログ: Cloud Logging へ転送

これで RAM 0.5〜1GB が空き、**C のダウンサイジングが `machine_type` / `mc_memory` 変数の
変更だけで行える**状態になった。あわせて 3-1（3000/9090 の全開放）と
3-3 の Grafana パスワード平文問題も解消している。

---

### F. バックアップを GCS へ（コストというより事故防止）

`mc-backup` が**ワールドと同じ 10GB ディスク**に書いている。

- preemption やディスク障害で**世界とバックアップが同時に消える**
- 10GB に Prometheus/Grafana データも同居しており、容量逼迫が見えている

対策: `BACKUP_METHOD=rclone` + GCS Nearline + lifecycle（月 $0.1 程度）。
`PRUNE_BACKUPS_DAYS` も明示しておく。

> **補足**: `pd-standard` は容量比例で IOPS が決まるため、**10GB だと実効 IOPS が一桁**。
> チャンク保存が遅い一因になっている可能性が高く、`pd-balanced` 化（+$1/月程度）はコスト効率が良い投資。

---

### G. 予算アラートの追加

Terraform に `google_billing_budget` がない。
Spot の再起動ループ等で暴走した際の保険として入れておく価値がある。

---

## 2. Mod 管理: packwiz の代替について

### 結論

**packwiz は置き換えない。** 本体は 2026 年 9 月時点でも更新されている現役プロジェクトであり、
この構成に必要な以下 3 点を同時に満たすツールは他にない。

- CurseForge 対応（現状 60/60 が CF ソース）
- `side` による client/server 分離
- itzg/minecraft-server のネイティブ対応（`USE_PACKWIZ`）

### 代替候補の評価

| 手段 | 評価 |
| --- | --- |
| **packwiz（現行）** | **継続推奨** |
| Modrinth `.mrpack` + `MODRINTH_MODPACK` | クライアント配布は圧倒的に楽（Modrinth App / Prism でワンクリック）。ただし **CF 専用 mod は .mrpack に埋め込めない** ため、60 件の Modrinth 移行が前提 |
| itzg の `MODRINTH_PROJECTS` / `CURSEFORGE_FILES` | サーバーだけなら最も簡単だが、**クライアント同期がない** → 却下 |
| ferium | CLI 管理は可能だが side 分離・クライアント同期が弱く、現行より劣る |
| mcman | サーバー中心。packwiz に対する明確な優位性なし |
| **AutoModpack** | packwiz の**代替ではなく併用**。下記 (c) 参照 |

---

### 代わりに効果が大きい 3 つ

#### (a) CI で `packwiz refresh` を回す

`.github/workflows/packwiz-pages.yml` は `packwiz/` を**そのまま**アップロードしているだけで、
`packwiz refresh` を実行していない。

現時点では `index.toml` のハッシュは `pack.toml` と一致している（確認済み）が、これは手作業に依存した状態。
**refresh 漏れ = パック破損**なので、CI で `packwiz refresh` → diff があれば fail、を入れる。

#### (b) mod 自動更新 PR

`packwiz update --all` を定期実行して PR を作るワークフローを追加する。現状は全て手動更新。

> ⚠️ `packwiz/mods/create-dreams-n-desires.pw.toml` は **`[update]` セクションがなく**
> `mediafilez.forgecdn.net` の直リンクになっている。`update --all` の対象外になり、
> 気づかないまま古いバージョンで固定される。

#### (c) AutoModpack の導入

サーバー側の modpack をクライアントに自動配信する mod。NeoForge 1.21.1 対応版あり。

現在プレイヤーは `packwiz-installer-bootstrap.jar` を自分で設定する必要があるが、
これが「サーバーに繋ぐだけ」になる。
**packwiz でサーバー側を管理し、AutoModpack で配信**する組み合わせが最も運用が楽。

---

### その他 packwiz まわりの指摘

#### side の棚卸しが未実施

61 件中 56 件が `both`。以下は実質クライアント専用で、**サーバーが不要な mod をロードしている**。

- `inventory-profiles-next` / `libipn`
- `mouse-tweaks`
- `controlling`
- `invmove`
- `clean-swing-through-grass`
- `enchantment-descriptions`
- `journeymap`

`client` に落とせばサーバーのメモリと起動時間が減り、**1-C のダウンサイジングに直結する**。

#### datapack が二重管理

`packwiz/datapacks/` の 4 ファイルと
`google/compute_engine/templates/startup.sh.tftpl:173` の `DATAPACKS` 環境変数に、
同じ 4 つの URL とバージョンが書かれている。片方だけ更新すると client/server でズレる。

#### `mod-list.html` の「概要」列が機能していない

`# 概要:` コメントを持つ `.pw.toml` が **0 件**のため、全行「概要未設定」と表示される。
また 67 ファイルを個別 fetch していて遅いので、CI で静的生成する方が良い。

#### EMI と JEI が両方入っている

レシピビューアの重複。意図的でなければどちらかで十分。

#### Modrinth ソースへの移行価値

- CF API キー不要
- CDN 直リンクで DL 高速
- `.mrpack` エクスポートが可能になる
- AutoModpack が Modrinth API から直接取得できる

移行可能な mod から順次寄せていく価値はある。

---

## 3. 見つかった不具合・リスク（コスト以外）

### 重要度: 高

#### 3-1. Prometheus (9090) が `0.0.0.0/0` に全開かつ認証なし 【解消済み】

誰でもメトリクスを読める状態だった（Grafana 3000 も同様）。
**E の対応で `mc-allow-monitoring` ファイアウォールごと削除**し、公開ポートは 25565 のみになった。
メトリクスエンドポイントは `127.0.0.1:19565` にだけ公開し、Ops Agent がホストから読む。

#### 3-2. Spot の猶予は 30 秒なのに `stop --timeout 120`

`google/compute_engine/templates/shutdown.sh.tftpl:29`。
Preemption 時の shutdown script は **30 秒で打ち切られる**ため、この 120 秒は実効しない。
ワールド保存が途中で切られる = **破損リスク**。

対策: RCON で `save-all flush` → `stop` を先に撃ち、timeout は 25 秒程度にする。

#### 3-3. RCON / Grafana パスワードがインスタンスメタデータに平文（RCON のみ残存）

startup script に埋め込まれるため、`compute.instances.get` 権限を持つ人と、
VM 上の任意のプロセス（メタデータサーバ経由）から読める。
**Grafana パスワードは E の対応で消滅**したが、RCON パスワードは依然として平文。

加えて `variable "rcon_password"` に `sensitive = true` が付いておらず、plan 出力に出る。
Secret Manager 参照が本筋。

---

### 重要度: 中

#### 3-4. NeoForge のバージョンが固定されていない

`packwiz/pack.toml` は `neoforge = "21.1.187"` だが、compose 側に `NEOFORGE_VERSION` がないため
itzg が 1.21.1 の最新を拾う。**クライアントとサーバーで NeoForge がズレる**。

#### 3-5. Terraform プロバイダが一切固定されていない

`required_providers` / `required_version` / `provider "google"` ブロックが存在せず、
`.terraform.lock.hcl` もコミットされていない。`terraform init` のたびに最新プロバイダが来る。

#### 3-6. リモート state がない

ローカル state + gitignore。紛失すると全リソースが孤児になる。GCS backend 化を推奨（月数セント）。

#### 3-7. 起動のたびに Docker を再インストール

`google/compute_engine/templates/startup.sh.tftpl:80-92`。
Spot は再起動が頻繁なので、毎回数分の起動遅延になる。
`command -v docker` でガードするか、Packer でカスタムイメージを焼く。

#### 3-8. スナップショットスケジュールなし

data disk に `resource_policies` が付いていない。

---

### 重要度: 低（コード品質）

#### 3-9. `google/basic/main.tf` の dead code / 重複

- `services` に `iam.googleapis.com` と `iamcredentials.googleapis.com` が**重複記述**（`toset` で吸収されるため無害）
- `time_sleep.wait_30_seconds` と `data.google_project.current` は**どこからも参照されていない dead code**

#### 3-10. `output` が一切ない 【解消済み】

外部 IP を知るのにコンソールを見る必要があった。
E の対応で `mc_server_external_ip` と `monitoring_dashboard_url` を追加した。

#### 3-11. ハードコードされた値（一部解消）

`OPS: "Prog24"` / `VERSION` がテンプレートに直書きのまま。
`MEMORY` と `machine_type` は E の対応で変数化済み（`mc_memory` / `machine_type`）。

---

## 4. 推奨する着手順

| 順 | 内容 | 効果 | 工数 |
| --- | --- | --- | --- |
| 1 | **A. Spot 化** | 24h 強制停止の解消 | 小 |
| 2 | **B. アイドル自動停止** | **コスト 60〜85% 減** | 中 |
| 3 | **3-1 / 3-2 / 3-3 の修正** | セキュリティ・データ保全 | 小〜中 |
| 4 | **C. マシンタイプ見直し** | コスト約半額 | 中（Arm 検証） |
| 5 | **2-(a) packwiz CI 自動化** | パック破損の予防 | 小 |
| 6 | D / F / G、2-(b) / 2-(c) | 継続改善 | 中 |

> **E（監視スタックの整理）は対応済み** → [監視構成ドキュメント](monitoring.md)

---

## 参考リンク

- [n2-standard-4 pricing | Economize](https://www.economize.cloud/resources/gcp/pricing/compute-engine/n2-standard-4/)
- [c4a-standard-4 specs and pricing | CloudPrice](https://cloudprice.net/gcp/compute/instances/c4a-standard-4)
- [Spot VMs | Google Cloud Documentation](https://docs.cloud.google.com/compute/docs/instances/spot)
- [Preemptible VM instances | Google Cloud Documentation](https://docs.cloud.google.com/compute/docs/instances/preemptible)
- [GCP Premium vs Standard Network Tier | EgressCost.com](https://egresscost.com/gcp/premium-vs-standard/)
- [Auto-Stop | itzg/docker-minecraft-server](https://docker-minecraft-server.readthedocs.io/en/latest/misc/autopause-autostop/autostop/)
- [packwiz/packwiz | GitHub](https://github.com/packwiz/packwiz)
- [AutoModpack | Modrinth](https://modrinth.com/mod/automodpack)
