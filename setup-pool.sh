#!/usr/bin/env bash
# setup-pool.sh - 複数の Fedora PC のディスクを mergerfs + NFSv4 で1つの共有ストレージにまとめる
#
# 全 PC が対等な構成（まとめ役なし）:
#   - 各 PC は自分のディスクを NFSv4 で他の PC に提供する
#   - 各 PC は他の全 PC のディスクを NFSv4 でマウントし、自分のディスクと合わせて mergerfs で束ねる
#   - pool.conf の CLIENTS に書いた PC は、ストレージを提供せずに共有ストレージを使うだけ
#
#   sudo ./setup-pool.sh install     # 全 PC で同じコマンドを実行
#   sudo ./setup-pool.sh status      # 状態確認
#   sudo ./setup-pool.sh uninstall   # 設定を取り除く（データは消さない）
#
#   --self <IP>  この PC が NODES / CLIENTS のどれかを明示する（自動判定がうまくいかない場合）
#   POOL_CONF=/path/to/pool.conf で設定ファイルを指定できる
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${POOL_CONF:-$SCRIPT_DIR/pool.conf}"
UNIT_DIR=/etc/systemd/system
TAG="# managed-by: pool-setup"
EXPORTS_FILE=/etc/exports.d/pool-node.exports
WATCH_BIN=/usr/local/libexec/pool-branch-watch
MOUNTD_DROPIN_DIR=/etc/systemd/system/nfs-server.service.d
MOUNTD_DROPIN=pool-mountd.conf
# soft: 相手が応答しないとき、無期限に待たずにエラーを返す（監視サービスが切り離すまでのつなぎ）
BRANCH_MOUNT_OPTS="rw,vers=4.2,soft,timeo=30,retrans=2,noatime,_netdev"

log()  { printf '\e[1;34m==>\e[0m %s\n' "$*"; }
ok()   { printf '\e[1;32m[OK]\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33m[警告]\e[0m %s\n' "$*" >&2; }
die()  { printf '\e[1;31m[エラー]\e[0m %s\n' "$*" >&2; exit 1; }

need_root() { [[ $EUID -eq 0 ]] || die "root で実行してください（sudo $0 ...）"; }

load_conf() {
  [[ -f $CONF ]] || die "設定ファイルがありません: $CONF"
  NODES=() CLIENTS=()
  # shellcheck source=pool.conf
  source "$CONF"
  local v n
  for v in LAN_CIDR DISK_DIR DATA_SUBDIR BRANCH_BASE POOL_DIR MINFREE; do
    [[ -n ${!v:-} ]] || die "pool.conf の $v が空です"
  done
  [[ ${#NODES[@]} -ge 1 ]] || die "pool.conf の NODES には1台以上を書いてください"
  [[ $(( ${#NODES[@]} + ${#CLIENTS[@]} )) -ge 2 ]] || die "pool.conf の NODES と CLIENTS で2台以上を書いてください"
  for n in "${CLIENTS[@]}"; do
    if in_list "$n" "${NODES[@]}"; then die "$n が NODES と CLIENTS の両方にあります"; fi
  done
}

in_list() {
  local x=$1 n; shift
  for n in "$@"; do [[ $n == "$x" ]] && return 0; done
  return 1
}

SELF=""
ROLE=""   # storage: ストレージを提供する / client: 使うだけ
# この PC が NODES / CLIENTS のどれか（ホスト名・自分の IP・名前解決結果で判定）
detect_self() {
  if [[ -z $SELF ]]; then
    local n resolved my_ips
    my_ips=" $(hostname -I 2>/dev/null) "
    for n in "${NODES[@]}" "${CLIENTS[@]}"; do
      if [[ $n == "$(hostname)" || $n == "$(hostname -s)" || $my_ips == *" $n "* ]]; then SELF=$n; break; fi
      resolved=$(getent ahostsv4 "$n" 2>/dev/null | awk 'NR==1{print $1}') || true
      if [[ -n $resolved && $my_ips == *" $resolved "* ]]; then SELF=$n; break; fi
    done
    [[ -n $SELF ]] || die "この PC が NODES / CLIENTS のどれか判定できません。--self <IP> で指定してください（この PC の IP: $(hostname -I 2>/dev/null)）"
  fi
  if in_list "$SELF" "${NODES[@]}"; then ROLE=storage
  elif in_list "$SELF" "${CLIENTS[@]}"; then ROLE=client
  else die "--self $SELF は NODES にも CLIENTS にも含まれていません"
  fi
}

# この PC がマウントする相手（ストレージを提供している PC のうち自分以外）
other_nodes() {
  local n
  for n in "${NODES[@]}"; do
    if [[ $n != "$SELF" ]]; then echo "$n"; fi
  done
}

# このディスクを公開する相手（自分以外の全参加 PC）
export_targets() {
  local n
  for n in "${NODES[@]}" "${CLIENTS[@]}"; do
    if [[ $n != "$SELF" ]]; then echo "$n"; fi
  done
}

unit_name() { systemd-escape -p --suffix="$2" "$1"; }

open_firewall() {
  if systemctl is-active -q firewalld 2>/dev/null; then
    local rule="rule family=\"ipv4\" source address=\"$LAN_CIDR\" service name=\"nfs\" accept"
    if ! firewall-cmd -q --permanent --query-rich-rule="$rule"; then
      firewall-cmd -q --permanent --add-rich-rule="$rule"
      firewall-cmd -q --reload
    fi
    ok "firewalld: $LAN_CIDR からの NFS (2049/tcp) を許可"
  else
    warn "firewalld が動いていません。別のファイアウォールを使っている場合は 2049/tcp を LAN に開けてください"
  fi
}

close_firewall() {
  if systemctl is-active -q firewalld 2>/dev/null; then
    local rule="rule family=\"ipv4\" source address=\"$LAN_CIDR\" service name=\"nfs\" accept"
    if firewall-cmd -q --permanent --query-rich-rule="$rule"; then
      firewall-cmd -q --permanent --remove-rich-rule="$rule"
      firewall-cmd -q --reload
    fi
  fi
}

install_mergerfs() {
  if command -v mergerfs >/dev/null; then
    ok "mergerfs は導入済み（$(mergerfs --version 2>&1 | head -1)）"
    return
  fi
  local ver=${MERGERFS_VERSION:-} arch fc base rpm a tmp
  if [[ -z $ver ]]; then
    ver=$(curl -fsSL https://api.github.com/repos/trapexit/mergerfs/releases/latest \
          | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)
    [[ -n $ver ]] || die "mergerfs の最新バージョンを取得できませんでした（pool.conf の MERGERFS_VERSION を指定してください）"
  fi
  arch=$(uname -m)
  fc=$(rpm -E %fedora)
  base="https://github.com/trapexit/mergerfs/releases/download/$ver"
  rpm="mergerfs-$ver-1.fc$fc.$arch.rpm"
  if curl -fsIL -o /dev/null "$base/$rpm"; then
    log "mergerfs $ver を導入します（$rpm）"
    dnf install -y "$base/$rpm"
  else
    case $arch in
      x86_64) a=amd64 ;; aarch64) a=arm64 ;;
      *) die "このアーキテクチャ向けの mergerfs が見つかりません: $arch" ;;
    esac
    log "Fedora $fc 向けの RPM がないため、静的ビルド版を導入します"
    tmp=$(mktemp -d)
    curl -fsSL "$base/mergerfs-$ver-static-linux_$a.tar.gz" -o "$tmp/mergerfs.tgz"
    tar -xzf "$tmp/mergerfs.tgz" -C /
    rm -rf "$tmp"
  fi
  command -v mergerfs >/dev/null || die "mergerfs の導入に失敗しました"
  ok "mergerfs を導入しました（$(mergerfs --version 2>&1 | head -1)）"
}

# ---------------------------------------------------------------- 1. 自分のディスクを提供
setup_export() {
  log "このディスク ($DISK_DIR) を他の PC に NFSv4 で提供します"
  mkdir -p "$DISK_DIR/$DATA_SUBDIR" /etc/exports.d
  # no_root_squash は mergerfs が下のディスクを管理するのに必要。参加 PC にだけ許可する
  {
    echo "$TAG"
    local n
    while read -r n; do
      echo "$DISK_DIR $n(rw,sync,no_subtree_check,no_root_squash)"
    done < <(export_targets)
  } >"$EXPORTS_FILE"
  if command -v getenforce >/dev/null && [[ $(getenforce) != Disabled ]]; then
    setsebool -P nfs_export_all_rw on
  fi
  open_firewall
  # nfs-server と一緒に nfs-mountd（公開先の判定）を必ず起動する。
  # Fedora 45 の nfs-utils では nfs-server だけが起動し、mountd が動かずにマウントが固まった
  mkdir -p "$MOUNTD_DROPIN_DIR"
  cat >"$MOUNTD_DROPIN_DIR/$MOUNTD_DROPIN" <<EOF
$TAG
[Unit]
Wants=nfs-mountd.service
After=nfs-mountd.service
EOF
  systemctl daemon-reload
  systemctl enable --now nfs-server
  systemctl start nfs-mountd
  systemctl is-active -q nfs-mountd || die "nfs-mountd を起動できませんでした（journalctl -u nfs-mountd を確認してください）"
  exportfs -ra
  ok "提供中: $DISK_DIR → $(export_targets | paste -sd' ')"
}

# 以前ストレージを提供していて、使うだけに変えた PC の公開設定を外す
remove_export() {
  rm -f "$MOUNTD_DROPIN_DIR/$MOUNTD_DROPIN"
  if [[ -f $EXPORTS_FILE ]]; then
    rm -f "$EXPORTS_FILE"
    exportfs -ra 2>/dev/null || true
    close_firewall
    ok "このディスクの提供をやめました（データは $DISK_DIR/$DATA_SUBDIR に残っています）"
  fi
}

# ---------------------------------------------------------------- 2. 他の PC のディスクをマウント
BRANCH_UNITS=()
BRANCH_NODES=()
BRANCH_MPS=()
BRANCHES=()
setup_branches() {
  log "他の PC のディスクをマウントします"
  # 自分のディスクはローカルで直接使う（使うだけの PC はディスクを束ねない）
  if [[ $ROLE == storage ]]; then BRANCHES=("$DISK_DIR/$DATA_SUBDIR"); else BRANCHES=(); fi
  local n mp u addr
  while read -r n; do
    mp="$BRANCH_BASE/$n"
    mkdir -p "$mp"
    u=$(unit_name "$mp" mount)
    # addr=: Fedora 45 では mount が mount.nfs4 を通さずカーネルに直接頼むことがあり、
    # そのときサーバーの IP が渡らず「mount program didn't pass remote address」で失敗する
    addr=$(getent ahostsv4 "$n" 2>/dev/null | awk 'NR==1{print $1}') || true
    addr=${addr:-$n}
    cat >"$UNIT_DIR/$u" <<EOF
$TAG
[Unit]
Description=Pool branch from $n
Wants=network-online.target
After=network-online.target

[Mount]
What=$n:$DISK_DIR
Where=$mp
Type=nfs4
Options=$BRANCH_MOUNT_OPTS,addr=$addr
TimeoutSec=30

[Install]
WantedBy=remote-fs.target
EOF
    BRANCH_UNITS+=("$u")
    BRANCH_NODES+=("$n")
    BRANCH_MPS+=("$mp")
    # マウントポイント直下の $DATA_SUBDIR をブランチにする。未マウント時はこのパスが
    # 存在しないので、mergerfs はそのブランチを飛ばす（ローカルの空ディレクトリに誤って書かない）
    BRANCHES+=("$mp/$DATA_SUBDIR")
  done < <(other_nodes)

  # 監視サービス: 応答しない PC のマウントをすぐ外し、復帰したら再マウントする。
  # NFS は相手が落ちると数分固まり、mergerfs は一覧表示などで全ディスクを見に行くため、
  # 1台の停止で共有ストレージ全体が固まる。外してしまえばそのディスクは飛ばされる。
  mkdir -p "$(dirname "$WATCH_BIN")"
  cat >"$WATCH_BIN" <<'EOF'
#!/usr/bin/env bash
# pool-branch-watch  <IP>|<マウント先>|<unit名> ...
# managed-by: pool-setup
INTERVAL=5
while true; do
  for spec in "$@"; do
    IFS='|' read -r ip mp unit <<<"$spec"
    # stat を伴う mountpoint ではなく mountinfo を読む findmnt を使う（固まった NFS で止まらない）
    if findmnt -rn --mountpoint "$mp" >/dev/null; then mounted=1; else mounted=0; fi
    if timeout 2 bash -c "exec 3<>/dev/tcp/$ip/2049" 2>/dev/null; then
      if [[ $mounted -eq 0 ]]; then
        echo "$ip が応答 → 再マウント"
        systemctl start --no-block "$unit"
      fi
    elif [[ $mounted -eq 1 ]]; then
      echo "$ip が応答しない → $mp を切り離し"
      umount -f -l "$mp" || true
      systemctl reset-failed "$unit" 2>/dev/null || true
    fi
  done
  sleep "$INTERVAL"
done
EOF
  chmod 755 "$WATCH_BIN"
  local args="" i
  for i in "${!BRANCH_UNITS[@]}"; do
    args+=" ${BRANCH_NODES[$i]}|${BRANCH_MPS[$i]}|${BRANCH_UNITS[$i]}"
  done
  cat >"$UNIT_DIR/pool-branch-watch.service" <<EOF
$TAG
[Unit]
Description=Detach unreachable pool branches and remount them when they come back
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$WATCH_BIN$args
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

# ---------------------------------------------------------------- 3. mergerfs で束ねる
setup_pool() {
  log "mergerfs で $POOL_DIR に束ねます"
  mkdir -p "$POOL_DIR"
  local pu branch_str
  pu=$(unit_name "$POOL_DIR" mount)
  branch_str=$(IFS=:; echo "${BRANCHES[*]}")
  # category.create=epmfs: 親ディレクトリがあるディスクのうち空きが最大の所に作る。
  #   → 最上位に作ったディレクトリ（プロジェクト）単位で1台のディスクにまとまるので、
  #     ある PC が止まっても、影響はその PC にあるプロジェクトだけで済む
  # ネットワーク上のブランチに依存するので、ネットワーク側のマウントとして順序づける
  local old=""
  [[ -f $UNIT_DIR/$pu ]] && old=$(cat "$UNIT_DIR/$pu")
  cat >"$UNIT_DIR/$pu" <<EOF
$TAG
[Unit]
Description=mergerfs pool
DefaultDependencies=no
Wants=network-online.target ${BRANCH_UNITS[*]}
After=network-online.target remote-fs-pre.target ${BRANCH_UNITS[*]}
Before=remote-fs.target umount.target
Conflicts=umount.target

[Mount]
What=$branch_str
Where=$POOL_DIR
Type=mergerfs
Options=allow_other,category.create=epmfs,minfreespace=$MINFREE,moveonenospc=true,inodecalc=path-hash,fsname=pool

[Install]
WantedBy=remote-fs.target
EOF
  # 設定が変わっていなければ、使用中の共有ストレージを付け直さない
  # （CLIENTS を追加して再 install したときなど）
  if [[ $old == "$(cat "$UNIT_DIR/$pu")" ]]; then POOL_CHANGED=0; else POOL_CHANGED=1; fi
}
POOL_CHANGED=1

# ---------------------------------------------------------------- コマンド
cmd_install() {
  need_root
  detect_self
  if [[ $ROLE == storage ]]; then
    log "この PC: $SELF（ストレージを提供） / 提供する PC: ${NODES[*]} / 使うだけの PC: ${CLIENTS[*]:-なし}"
  else
    log "この PC: $SELF（使うだけ。ストレージは提供しない） / 提供する PC: ${NODES[*]}"
  fi
  dnf install -y nfs-utils fuse3 curl gawk
  install_mergerfs
  if [[ $ROLE == storage ]]; then setup_export; else remove_export; fi
  setup_branches
  setup_pool
  systemctl daemon-reload
  local u
  for u in "${BRANCH_UNITS[@]}"; do
    systemctl enable "$u" >/dev/null 2>&1 || true
    if systemctl start "$u"; then ok "接続: ${u%.mount}"; else warn "接続できません（その PC の install 後に自動で再接続）: $u"; fi
  done
  systemctl enable pool-branch-watch.service >/dev/null 2>&1
  systemctl restart pool-branch-watch.service
  local pu; pu=$(unit_name "$POOL_DIR" mount)
  systemctl enable "$pu" >/dev/null 2>&1
  if [[ $POOL_CHANGED -eq 1 ]] || ! mountpoint -q "$POOL_DIR"; then
    systemctl restart "$pu" \
      || die "$POOL_DIR を付け直せませんでした。使用中のプログラムを止めてから、もう一度 install してください"
  fi
  ok "共有ストレージ: $POOL_DIR"
  echo
  cmd_status
  echo
  echo "次の作業: 共有ストレージは root 所有で作られます。使うユーザーに書き込み権限を与えてください（どれか1台で1回）:"
  echo "  sudo chown <ユーザー>:<グループ> $POOL_DIR"
}

cmd_status() {
  detect_self
  if [[ $ROLE == storage ]]; then echo "この PC: $SELF（ストレージを提供）"; else echo "この PC: $SELF（使うだけ）"; fi
  echo "--- ディスク"
  if [[ $ROLE == storage ]]; then
    printf '  %-20s %s\n' "$SELF（この PC）" "$(df -h --output=size,avail "$DISK_DIR" | tail -1)"
  fi
  local n mp
  while read -r n; do
    mp="$BRANCH_BASE/$n"
    if findmnt -rn --mountpoint "$mp" >/dev/null; then
      printf '  %-20s %s\n' "$n" "$(timeout 10 df -h --output=size,avail "$mp" 2>/dev/null | tail -1 || echo '応答なし')"
    else
      printf '  %-20s %s\n' "$n" "未接続"
    fi
  done < <(other_nodes)
  echo "--- 共有ストレージ"
  if mountpoint -q "$POOL_DIR"; then
    printf '  '; df -h --output=target,size,used,avail "$POOL_DIR" | tail -1
  else
    echo "  $POOL_DIR はマウントされていません"
  fi
  echo "--- UID（全 PC で同じユーザーの UID をそろえてください）"
  getent passwd | awk -F: '$3>=1000 && $3<60000 {printf "  %s=%s\n",$1,$3}'
}

cmd_uninstall() {
  need_root
  log "pool-setup の設定を取り除きます（データと mergerfs 本体は残します）"
  local f u units=()
  for f in "$UNIT_DIR"/*; do
    if [[ -f $f ]] && grep -qxF "$TAG" "$f"; then units+=("$(basename "$f")"); fi
  done
  # 外側から順に止める: timer → mergerfs → ブランチ
  for u in "${units[@]}"; do
    if [[ $u == *.timer || $u == *.automount || $u == *.service ]]; then systemctl disable --now "$u" 2>/dev/null || true; fi
  done
  for u in "${units[@]}"; do
    if [[ $u == *.mount ]] && grep -qx 'Type=mergerfs' "$UNIT_DIR/$u"; then systemctl disable --now "$u" 2>/dev/null || true; fi
  done
  for u in "${units[@]}"; do systemctl disable --now "$u" 2>/dev/null || true; done
  for u in "${units[@]}"; do rm -f "$UNIT_DIR/$u"; done
  rm -f "$WATCH_BIN" "$MOUNTD_DROPIN_DIR/$MOUNTD_DROPIN"
  rmdir "$MOUNTD_DROPIN_DIR" 2>/dev/null || true
  systemctl daemon-reload
  rm -f "$EXPORTS_FILE"
  exportfs -ra 2>/dev/null || true
  close_firewall
  ok "完了。データは $DISK_DIR/$DATA_SUBDIR に残っています。mergerfs の削除: sudo dnf remove mergerfs"
}

usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

main() {
  local cmd=${1:-}; shift || true
  while [[ $# -gt 0 ]]; do
    case $1 in
      --self) SELF=${2:-}; shift 2 ;;
      *) usage ;;
    esac
  done
  case $cmd in
    install|status|uninstall) ;;
    *) usage ;;
  esac
  load_conf
  "cmd_$cmd"
}

main "$@"
