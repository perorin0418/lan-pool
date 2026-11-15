# lan-pool

複数の Fedora PC のディスクを束ねて、全 PC から同じ共有ストレージ（`/mnt/pool`）として使うためのセットアップスクリプトです。mergerfs と NFSv4 を使います。

## 構成

```
PC-A: /srv/disk ─┐
PC-B: /srv/disk ─┼─ 各 PC が他の全 PC のディスクを NFSv4 でマウントし、
PC-C: /srv/disk ─┘   自分のディスクと合わせて mergerfs で /mnt/pool に束ねる
PC-D: （提供なし）    PC-A〜C のディスクをマウントして /mnt/pool に束ねる（使うだけ）
```

- 全 PC が対等で、まとめ役はいません。1台が止まっても、残りの PC で使い続けられます。
- 新しいファイルやディレクトリは、親ディレクトリがあるディスクのうち空きが一番多い所に作られます（`epmfs`）。そのため、**最上位に作ったディレクトリ（プロジェクト）単位で1台のディスクにまとまります**。PC が止まったときに影響を受けるのは、その PC にあるプロジェクトだけです。
- 各ディスクの中身は普通のファイルです（`/srv/disk/pool-data/`）。mergerfs が壊れても、ファイルを直接取り出せます。

## 準備

1. 各 PC の IP アドレスを固定します（ルーターの DHCP 予約など）。
2. 共有に使うディレクトリを各 PC に用意します（既定は `/srv/disk`。大きいディスクをここにマウントしておくのがおすすめです）。
3. **全 PC で、同じユーザーの UID をそろえます**（`id -u` で確認）。そろっていないと権限が合いません。
4. `pool.conf` の `LAN_CIDR` と `NODES` を書き換え、全 PC に同じ内容で置きます。
   - ストレージを提供せずに使うだけの PC は、`NODES` ではなく `CLIENTS` に書きます。この PC では `/srv/disk` は不要で、NFS の公開もファイアウォールの変更もしません。
   - `CLIENTS` を後から追加・削除したときは、`NODES` の全 PC でも `install` をやり直してください（公開先が更新されます。使用中の `/mnt/pool` は付け直しません）。

## 使い方

```bash
# 全 PC で実行（順番は問いません。後から install した PC にも自動で再接続します）
sudo ./setup-pool.sh install

# どれか1台で1回、使うユーザーに書き込み権限を与える
sudo chown "$USER": /mnt/pool

# 状態の確認
sudo ./setup-pool.sh status

# 取り除く（データは残します）
sudo ./setup-pool.sh uninstall
```

この PC が `NODES` / `CLIENTS` のどれか自動で判定できないときは、`--self 192.168.1.11` のように指定してください。

## 作られるもの

| 種類 | 場所 |
|---|---|
| NFS の公開設定 | `/etc/exports.d/pool-node.exports`（参加している PC にだけ公開） |
| 他の PC のディスクのマウント | `/mnt/branches/<IP>`（systemd の mount ユニット） |
| 共有ストレージ | `/mnt/pool`（systemd の mount ユニット、mergerfs） |
| 監視サービス | `pool-branch-watch.service`。応答しない PC を数秒で切り離し、復帰したら再マウントする |
| ファイアウォール | firewalld で `LAN_CIDR` からの NFS（2049/tcp）を許可 |
| mergerfs 本体 | GitHub 配布の RPM（Fedora の公式リポジトリにはないため） |

## 注意

- **複製はありません。** ディスクが壊れると、そのディスクにあったデータは失われます。大事なデータは別途バックアップしてください。
- **同じ git リポジトリを複数の PC で同時に操作しないでください。** 作業を分けるときは、PC ごとに `git worktree` や clone を分けます。
- PC が止まった直後の数秒（監視サービスが気づくまで）は、その PC のディスクへの操作が待たされることがあります。
- NFS は認証なしで LAN に公開します（`no_root_squash`。参加している PC の IP にだけ許可）。信頼できない機器がある LAN では使わないでください。

## 動作確認済みの内容

Fedora 44（WSL2 上、1台で2ノード分を模擬）で次を確認しました。

- install、status、uninstall
- 共有ストレージ上での git 操作（commit、mv、300 ファイル、gc、fsck）
- 再起動後の自動マウント
- ノード停止時の切り離しと、復帰時の再マウント

実機の複数台での確認、firewalld、SELinux の設定は未確認です。
`CLIENTS`（使うだけの PC）は、役割の判定・マウント先・公開先の振り分けだけを確認しています。実際のマウントは未確認です。
