#!/usr/bin/env bash
# AnJing 控制脚本：安装、启动、停止、状态、日志、升级、回滚、卸载。
# （AnJing 二进制里也内嵌了一份，`anjing controller` 可以打印出来）。
set -euo pipefail

# 安装目录。安装向导写入 anjingctl 时会把默认值替换成实际目录。
ANJING_DIR="${ANJING_DIR:-/opt/anjing}"
BIN="$ANJING_DIR/bin/anjing"
MANIFEST="$ANJING_DIR/.install-manifest"
TARGET="anjing.target"
CONTROLLER="/usr/local/bin/anjingctl"
UNIT_DIR="/etc/systemd/system"
NATS_BIN="/usr/local/bin/nats-server"
SERVICES=(node-registry im-logic user-auth media push gateway admin)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$(basename "$0")"

info() { printf '\033[1;36m%s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m%s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m%s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m错误：%s\033[0m\n' "$*" >&2; exit 1; }

need_root() {
  [ "$(id -u)" -eq 0 ] || die "需要 root 权限，请用 sudo $SELF ${1:-} 运行"
}

need_installed() {
  [ -x "$BIN" ] || die "未找到 $BIN，请先运行：sudo $SELF install"
}

need_systemd() {
  command -v systemctl >/dev/null 2>&1 || die "未找到 systemctl，AnJing 需要 systemd"
}

go_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *) echo unknown ;;
  esac
}

# package_binary 找发布包里和本脚本放在一起的 AnJing 二进制。
package_binary() {
  local c
  for c in "$SCRIPT_DIR/anjing" "$SCRIPT_DIR/anjing-linux-$(go_arch)"; do
    if [ -f "$c" ] && [ "$(readlink -f "$c")" != "$(readlink -f "$BIN" 2>/dev/null || true)" ]; then
      echo "$c"
      return 0
    fi
  done
  return 1
}

# manifest_get 读安装清单里的一个值。只用 grep 读取，不 source，避免执行文件内容。
manifest_get() {
  [ -f "$MANIFEST" ] || return 0
  grep -m1 "^$1=" "$MANIFEST" 2>/dev/null | cut -d= -f2- || true
}

# env_get 读 .env 里一个单引号包裹的值（安装向导写的格式）。
env_get() {
  [ -f "$ANJING_DIR/.env" ] || return 0
  grep -m1 "^$1=" "$ANJING_DIR/.env" 2>/dev/null | cut -d= -f2- | sed -e "s/^'//" -e "s/'\$//" || true
}

units() {
  echo "anjing-nats.service"
  local s
  for s in "${SERVICES[@]}"; do echo "anjing-$s.service"; done
}

# ---------------------------------------------------------------- commands

cmd_install() {
  need_root install
  local bin
  if bin="$(package_binary)"; then
    :
  elif [ -x "$BIN" ]; then
    bin="$BIN"
  else
    die "在 $SCRIPT_DIR 下找不到 AnJing 二进制。请把 anjing.sh 和 anjing 放在同一目录后再运行。"
  fi
  # 从 Windows 上传（WinSCP、网页面板等）时可执行权限常会丢失。
  chmod +x "$bin" 2>/dev/null || true
  "$bin" version >/dev/null 2>&1 || die "$bin 无法运行（架构不对？本机是 $(uname -m)）"
  info "启动安装向导：$bin setup $*"
  exec "$bin" setup "$@"
}

cmd_start() {
  need_root start; need_systemd; need_installed
  systemctl start "$TARGET"
  ok "已启动"
  sleep 2
  cmd_status
}

cmd_stop() {
  need_root stop; need_systemd
  systemctl stop "$TARGET"
  ok "已停止全部 AnJing 服务（开机仍会自启，不想自启请运行：sudo $SELF disable）"
}

cmd_restart() {
  need_root restart; need_systemd; need_installed
  systemctl restart "$TARGET"
  ok "已重启"
  sleep 2
  cmd_status
}

cmd_enable() {
  need_root enable; need_systemd
  systemctl enable "$TARGET"
  ok "已设置开机自启"
}

cmd_disable() {
  need_root disable; need_systemd
  systemctl disable "$TARGET"
  ok "已取消开机自启（正在运行的服务不受影响）"
}

cmd_status() {
  need_systemd
  if [ -x "$BIN" ]; then
    printf '版本：%s\n' "$("$BIN" version 2>/dev/null || echo 未知)"
  else
    warn "未安装（找不到 $BIN）"
  fi
  printf '开机自启：%s\n\n' "$(systemctl is-enabled "$TARGET" 2>/dev/null || echo 未注册)"

  local u state failed=0
  printf '%-28s %s\n' "服务" "状态"
  while read -r u; do
    state="$(systemctl is-active "$u" 2>/dev/null || true)"
    case "$state" in
      active)   printf '%-28s \033[32m%s\033[0m\n' "$u" "运行中" ;;
      inactive) printf '%-28s \033[33m%s\033[0m\n' "$u" "已停止" ;;
      failed)   printf '%-28s \033[31m%s\033[0m\n' "$u" "失败"; failed=1 ;;
      *)        printf '%-28s %s\n' "$u" "${state:-未注册}" ;;
    esac
  done < <(units)
  if [ "$failed" = 1 ]; then
    echo
    warn "有服务启动失败，查看日志：sudo $SELF logs <服务名>"
  fi
}

cmd_logs() {
  need_systemd
  local svc="" args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -f|--follow) args+=(-f); shift ;;
      -n) [ $# -ge 2 ] || die "-n 需要一个数字"; args+=(-n "$2"); shift 2 ;;
      -*) die "未知参数 $1" ;;
      *) svc="$1"; shift ;;
    esac
  done
  [ ${#args[@]} -gt 0 ] || args=(-n 100)

  if [ -z "$svc" ]; then
    exec journalctl --no-pager -u 'anjing-*' "${args[@]}"
  fi
  local s
  for s in nats "${SERVICES[@]}"; do
    if [ "$s" = "$svc" ]; then
      exec journalctl --no-pager -u "anjing-$svc.service" "${args[@]}"
    fi
  done
  die "未知服务 $svc，可选：nats ${SERVICES[*]}"
}

cmd_version() {
  need_installed
  "$BIN" version
}

# refresh_controller 用二进制内嵌的最新脚本覆盖 /usr/local/bin/anjingctl，
# 并保留当前的安装目录。
refresh_controller() {
  local tmp
  tmp="$(mktemp "$CONTROLLER.XXXXXX")"
  if "$BIN" controller --dir "$ANJING_DIR" >"$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    chmod 755 "$tmp"
    mv -f "$tmp" "$CONTROLLER"
  else
    rm -f "$tmp"
    warn "更新控制脚本失败，继续使用旧版本"
  fi
}

cmd_upgrade() {
  need_root upgrade; need_systemd; need_installed
  local new="${1:-}"
  if [ -z "$new" ]; then
    new="$(package_binary)" || die "请指定新版本二进制：sudo $SELF upgrade /path/to/anjing"
  fi
  [ -f "$new" ] || die "找不到 $new"
  [ "$(readlink -f "$new")" != "$(readlink -f "$BIN")" ] || die "$new 就是当前安装的版本"
  chmod +x "$new" 2>/dev/null || true
  local newver oldver
  newver="$("$new" version 2>/dev/null)" || die "$new 无法运行（架构不对？本机是 $(uname -m)）"
  oldver="$("$BIN" version 2>/dev/null || echo 未知)"
  info "升级：$oldver -> $newver"

  install -m 755 -o root -g root "$new" "$BIN.new"
  cp -p "$BIN" "$BIN.prev"
  mv -f "$BIN.new" "$BIN"
  refresh_controller
  systemctl restart "$TARGET"
  ok "已升级并重启。出问题可以回滚：sudo $SELF rollback"
  echo "提示：新版本如果修改了 systemd 服务或配置项，请再运行一次 sudo $SELF install 更新。"
  sleep 2
  cmd_status
}

cmd_rollback() {
  need_root rollback; need_systemd; need_installed
  [ -f "$BIN.prev" ] || die "没有可回滚的版本（$BIN.prev 不存在）"
  info "回滚：$("$BIN" version 2>/dev/null || echo 未知) -> $("$BIN.prev" version 2>/dev/null || echo 未知)"
  mv -f "$BIN" "$BIN.rollback"
  mv -f "$BIN.prev" "$BIN"
  mv -f "$BIN.rollback" "$BIN.prev"
  refresh_controller
  systemctl restart "$TARGET"
  ok "已回滚并重启"
  sleep 2
  cmd_status
}

valid_ident() { [[ "$1" =~ ^[A-Za-z0-9_]{1,64}$ ]]; }

# drop_database 只删除安装向导自己创建的数据库和账号（安装清单里记录的
# DB_CREATED_BY_ANJING / DB_USER_CREATED_BY_ANJING）。你自己建好交给 AnJing 用的
# 数据库（例如在宝塔面板里创建的）永远不会被删除。
drop_database() {
  local db user
  db="$(manifest_get DB_CREATED_BY_ANJING)"
  user="$(manifest_get DB_USER_CREATED_BY_ANJING)"
  if [ -z "$db" ] && [ -z "$user" ]; then
    local used
    used="$(manifest_get DB_NAME)"
    if [ -n "$used" ]; then
      info "数据库 $used 不是安装向导创建的，保留（如需删除请在 MySQL / 宝塔面板中手动处理）"
    fi
    return 0
  fi
  if { [ -n "$db" ] && ! valid_ident "$db"; } || { [ -n "$user" ] && ! valid_ident "$user"; }; then
    warn "安装清单中的数据库名/用户名格式异常，跳过删除数据库"
    return 0
  fi
  case "$(echo "$db" | tr 'A-Z' 'a-z')" in
    mysql|sys|information_schema|performance_schema) warn "拒绝删除系统库 $db"; return 0 ;;
  esac
  if ! command -v mysql >/dev/null 2>&1; then
    warn "未找到 mysql 客户端，跳过删除数据库，请手动删除：${db:+数据库 $db }${user:+账号 $user}"
    return 0
  fi

  local sql=""
  [ -n "$db" ] && sql+="DROP DATABASE IF EXISTS \`$db\`;"$'\n'
  if [ -n "$user" ]; then
    sql+="DROP USER IF EXISTS '$user'@'localhost';"$'\n'
    sql+="DROP USER IF EXISTS '$user'@'127.0.0.1';"$'\n'
  fi
  sql+="FLUSH PRIVILEGES;"$'\n'

  info "删除安装向导创建的${db:+数据库 $db }${user:+账号 $user}"
  if ! mysql --protocol=socket -uroot <<<"$sql" 2>/dev/null; then
    warn "无法以 root 身份通过本地 socket 登录 MySQL（宝塔面板等设置了 root 密码的情况）"
    if [ -t 0 ]; then
      local pw
      read -r -s -p "请输入 MySQL root 密码（直接回车跳过）：" pw; echo
      if [ -n "$pw" ] && MYSQL_PWD="$pw" mysql -uroot -h127.0.0.1 <<<"$sql"; then
        return 0
      fi
    fi
    warn "未删除数据库，请手动执行：$(echo "$sql" | tr '\n' ' ')"
  fi
}

cmd_uninstall() {
  need_root uninstall
  local purge=0 remove_deps=0 yes=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --purge) purge=1 ;;
      --remove-deps) remove_deps=1 ;;
      -y|--yes) yes=1 ;;
      *) die "未知参数 $1（可用：--purge --remove-deps -y）" ;;
    esac
    shift
  done
  [ "$remove_deps" = 0 ] || [ "$purge" = 1 ] || die "--remove-deps 需要和 --purge 一起使用"
  case "$ANJING_DIR" in
    ""|/|/usr|/usr/*bin|/etc|/opt|/home|/root|/var) die "安装目录 $ANJING_DIR 不安全，拒绝删除" ;;
  esac

  local mysql_pkg="" mysql_ours nats_ours user_ours
  mysql_ours="$(manifest_get MYSQL_INSTALLED_BY_ANJING)"
  mysql_pkg="$(manifest_get MYSQL_PACKAGE)"
  nats_ours="$(manifest_get NATS_INSTALLED_BY_ANJING)"
  user_ours="$(manifest_get SERVICE_USER_CREATED_BY_ANJING)"

  echo "将执行："
  echo "  - 停止并移除 AnJing 的 systemd 服务（anjing.target、anjing-*.service）"
  echo "  - 删除程序 $ANJING_DIR/bin 和控制脚本 $CONTROLLER"
  if [ "$purge" = 1 ]; then
    echo "  - 删除整个 $ANJING_DIR（配置、JWT 密钥、上传的媒体文件）"
    local db_created user_created
    db_created="$(manifest_get DB_CREATED_BY_ANJING)"
    user_created="$(manifest_get DB_USER_CREATED_BY_ANJING)"
    if [ -n "$db_created$user_created" ]; then
      echo "  - 删除安装向导创建的${db_created:+数据库 $db_created（所有聊天记录、用户数据）}${user_created:+ 和账号 $user_created}"
    else
      echo "  - 数据库 $(manifest_get DB_NAME) 是你自己提供的，保留不删"
    fi
    [ "$user_ours" = 1 ] && echo "  - 删除系统用户 anjing"
    [ "$nats_ours" = 1 ] && echo "  - 删除 $NATS_BIN"
    if [ "$remove_deps" = 1 ]; then
      if [ "$mysql_ours" = 1 ]; then
        echo "  - 卸载 MySQL 软件包 $mysql_pkg（会影响本机上所有使用 MySQL 的程序）"
      else
        echo "  - MySQL 不是 AnJing 安装的，保留"
      fi
    fi
    echo
    warn "--purge 会永久删除所有数据，无法恢复。"
  else
    echo "  保留：$ANJING_DIR 下的配置、密钥、媒体文件，以及数据库。之后运行 install 可以原样恢复。"
  fi
  echo

  if [ "$yes" != 1 ]; then
    [ -t 0 ] || die "非交互环境请加 -y 确认"
    local answer
    if [ "$purge" = 1 ]; then
      read -r -p "输入 yes 确认删除全部数据：" answer
      [ "$answer" = "yes" ] || die "已取消"
    else
      read -r -p "确认卸载？[y/N] " answer
      case "$answer" in y|Y|yes|YES) ;; *) die "已取消" ;; esac
    fi
  fi

  if command -v systemctl >/dev/null 2>&1; then
    info "停止服务"
    systemctl disable --now "$TARGET" 2>/dev/null || true
    local u
    while read -r u; do systemctl stop "$u" 2>/dev/null || true; done < <(units)
    # 只删除安装向导生成的文件，不碰别人放在这里的同名文件。
    for u in "$UNIT_DIR/$TARGET" $(units | sed "s#^#$UNIT_DIR/#"); do
      if [ -f "$u" ] && head -n1 "$u" | grep -q "Generated by anjing setup"; then
        rm -f "$u"
      fi
    done
    systemctl daemon-reload
    systemctl reset-failed 2>/dev/null || true
  fi

  if [ "$purge" = 1 ]; then
    drop_database
    info "删除 $ANJING_DIR"
    rm -rf --one-file-system "$ANJING_DIR"
    if [ "$user_ours" = 1 ] && id anjing >/dev/null 2>&1; then
      userdel anjing 2>/dev/null || warn "删除系统用户 AnJing 失败"
    fi
    if [ "$nats_ours" = 1 ]; then
      rm -f "$NATS_BIN"
    fi
    if [ "$remove_deps" = 1 ] && [ "$mysql_ours" = 1 ] && [ -n "$mysql_pkg" ]; then
      info "卸载 $mysql_pkg"
      DEBIAN_FRONTEND=noninteractive apt-get purge -y "$mysql_pkg" || warn "卸载 $mysql_pkg 失败"
      DEBIAN_FRONTEND=noninteractive apt-get autoremove -y || true
      warn "MySQL 的数据目录 /var/lib/mysql 可能仍然保留，确认不需要后可手动删除"
    fi
  else
    rm -rf "$ANJING_DIR/bin"
  fi

  # 最后再删控制脚本：如果当前正在运行的就是它，bash 已经打开了文件，删掉不影响执行。
  rm -f "$CONTROLLER"
  ok "卸载完成"
}

usage() {
  cat <<EOF
AnJing 控制脚本

用法：sudo $SELF <命令> [参数]

  install [--listen 地址]   安装或修改配置（启动网页安装向导，默认监听 0.0.0.0:8090）
  start                     启动全部服务
  stop                      停止全部服务（暂停）
  restart                   重启全部服务
  status                    查看各服务状态
  logs [服务] [-f] [-n 行数] 查看日志，服务可选：nats ${SERVICES[*]}
  enable | disable          开启 / 关闭开机自启
  upgrade [新二进制路径]      升级（默认用同目录下的 anjing），保留旧版本用于回滚
  rollback                  回滚到升级前的版本
  version                   查看已安装的版本
  uninstall [选项]           卸载
      （无选项）             只移除程序和服务，保留配置、媒体文件和数据库
      --purge               同时删除 $ANJING_DIR、数据库和 AnJing 安装的 NATS
      --purge --remove-deps 再卸载由 AnJing 安装的 MySQL
      -y                    跳过确认

安装目录：$ANJING_DIR（可用环境变量 ANJING_DIR 覆盖）
EOF
}

main() {
  local cmd="${1:-help}"
  [ $# -gt 0 ] && shift
  case "$cmd" in
    install|setup) cmd_install "$@" ;;
    start)     cmd_start ;;
    stop)      cmd_stop ;;
    restart)   cmd_restart ;;
    status)    cmd_status ;;
    logs|log)  cmd_logs "$@" ;;
    enable)    cmd_enable ;;
    disable)   cmd_disable ;;
    upgrade)   cmd_upgrade "$@" ;;
    rollback)  cmd_rollback ;;
    version)   cmd_version ;;
    uninstall) cmd_uninstall "$@" ;;
    help|-h|--help) usage ;;
    *) usage >&2; die "未知命令 $cmd" ;;
  esac
}

main "$@"
