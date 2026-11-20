#!/bin/bash
# tatareka-bpjs-monitoring setup. Run by the RPM (%post install, %preun remove); safe to run again at any time.
#
#   setup.sh install   read-only MySQL account bpjs_mon, the "Dashboard Klaim BPJS" screen in SIMGOS, the timers
#   setup.sh remove    take the screen out of SIMGOS and stop the timers (files are removed by rpm; the account stays,
#                      it can only read)
#
# The account bpjs_mon may read which claims are final and their value (inacbg.grouping, inacbg.hasil_grouping), BPJS's
# status and amounts as SIMGOS stored them (bpjs.klaim) and two columns of SIMGOS's BPJS call log (when, and from which
# computer: no address, request or answer). Its login is kept in
# /etc/tatareka-bpjs-monitoring/mysql.cnf (root only). Creating it needs a MySQL admin login: root's own, else SIMGOS's database login
# (webservice local.php), else, in a terminal, the MySQL root password asked once and never saved.
set -u
export HOME=${HOME:-/root}
APP=/opt/tatareka-bpjs-monitoring
LOGIN=/etc/tatareka-bpjs-monitoring/mysql.cnf
DATA=/var/lib/tatareka-bpjs-monitoring
WS_CONF=/var/www/html/production/webapps/webservice/config/autoload/local.php
WS_CACHE=/var/www/html/production/webapps/webservice/data/cache
# How the screen loads: SIMGOS loads packages/classic/<package>.js for every properti_config row whose VALUE is
# {"enabled": true, "package": ...} (as tatareka-ai-klaim's 909901). Set "enabled": false in the row to hide it.
PC_ID=909902
PC_VALUE='{"enabled": true, "package": "BpjsMonitoring"}'
API_URL=/apps/tatareka-bpjs-monitoring/api.php
say() { echo "tatareka-bpjs-monitoring: $*"; }

ADMIN=""
cleanup() { case "$ADMIN" in /*) rm -f "$ADMIN";; esac; }
trap cleanup EXIT
mycnf() {   # user password host port -> temporary options file (mode 600)
  local f; f=$(mktemp /tmp/ttrk-my.XXXXXX) || return 1
  python3 - "$f" "$@" <<'PY'
import sys
f, user, pw, host, port = sys.argv[1:6]
q = lambda v: '"' + v.replace("\\", "\\\\").replace('"', '\\"') + '"'
lines = ["[client]", "user=" + q(user), "password=" + q(pw)]
if host: lines.append("host=" + q(host))
if port: lines.append("port=" + port)
open(f, "w").write("\n".join(lines) + "\n")
PY
  echo "$f"
}
admin() {
  [ -n "$ADMIN" ] && { [ "$ADMIN" != - ]; return; }
  if mysql -N -e "SELECT 1" >/dev/null 2>&1; then ADMIN=own; return 0; fi
  local f u
  u=$(php -r '$c = @include $argv[1]; $a = $c["db"]["adapters"]["SIMpelAdapter"] ?? [];
      echo implode("\n", [$a["username"] ?? "", $a["password"] ?? "", $a["hostname"] ?? "", $a["port"] ?? ""]);' \
      "$WS_CONF" 2>/dev/null)
  if [ -n "$(sed -n 1p <<< "$u")" ] &&
     f=$(mycnf "$(sed -n 1p <<< "$u")" "$(sed -n 2p <<< "$u")" "$(sed -n 3p <<< "$u")" "$(sed -n 4p <<< "$u")"); then
    if mysql --defaults-file="$f" -N -e "SELECT 1" >/dev/null 2>&1; then ADMIN=$f; return 0; fi
    rm -f "$f"
  fi
  if [ -t 0 ]; then
    local pw
    read -r -s -p "MySQL root password (used once for setup, not saved): " pw; echo
    if [ -n "$pw" ] && f=$(mycnf root "$pw" localhost ""); then
      if mysql --defaults-file="$f" -N -e "SELECT 1" >/dev/null 2>&1; then ADMIN=$f; return 0; fi
      rm -f "$f"
    fi
  fi
  ADMIN=-; return 1
}
db() {
  admin || return 1
  if [ "$ADMIN" = own ]; then mysql -N -B "$@"; else mysql --defaults-file="$ADMIN" -N -B "$@"; fi
}
ro() { [ -f $LOGIN ] && MYSQL_GROUP_SUFFIX=bpjsmon mysql --defaults-file=$LOGIN "$@"; }
account_ok() {   # can read what it needs, and cannot write
  ro -N -e "SELECT 1 FROM inacbg.hasil_grouping LIMIT 1" >/dev/null 2>&1 \
    && ro -N -e "SELECT COUNT(*) FROM (SELECT TGL_REQUEST, ACCESS_FROM_IP FROM logs.bridge_log LIMIT 1) x" >/dev/null 2>&1 \
    && ro -N -e "SELECT 1 FROM bpjs.klaim LIMIT 1" >/dev/null 2>&1 \
    && ! ro -e "UPDATE inacbg.hasil_grouping SET KLAIM=KLAIM WHERE NOPEN='0'" >/dev/null 2>&1
}
login_move() {   # 1.0.0-26112001 kept the login in root's own /root/.my.cnf: move it into $LOGIN
  [ -f /root/.my.cnf ] && grep -q '^\[clientbpjsmon\]' /root/.my.cnf || return 0
  python3 - "$LOGIN" <<'PY2'
import os, re, sys
p = "/root/.my.cnf"; s = open(p).read()
m = re.search(r"^\[clientbpjsmon\][^\[]*", s, re.M)
if not os.path.exists(sys.argv[1]):
    fd = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    os.write(fd, (m.group(0).strip() + "\n").encode()); os.close(fd)
s = (s[:m.start()] + s[m.end():]).strip()
if s: open(p, "w").write(s + "\n")
else: os.remove(p)   # only our section was in it
PY2
  say "bpjs_mon: login moved from /root/.my.cnf to $LOGIN"
}

install_account() {
  login_move
  if account_ok; then say "read-only account bpjs_mon works (unchanged)"; return 0; fi
  local pw="Bm_$(openssl rand -hex 12)-Ro7" err   # no '#': it starts a comment in an option file
  if ! err=$(db 2>&1 <<SQL
CREATE USER IF NOT EXISTS 'bpjs_mon'@'localhost' IDENTIFIED BY '$pw';
ALTER USER 'bpjs_mon'@'localhost' IDENTIFIED BY '$pw';
GRANT SELECT ON inacbg.grouping TO 'bpjs_mon'@'localhost';
GRANT SELECT ON inacbg.hasil_grouping TO 'bpjs_mon'@'localhost';
GRANT SELECT (TGL_REQUEST, ACCESS_FROM_IP) ON logs.bridge_log TO 'bpjs_mon'@'localhost';
GRANT SELECT ON bpjs.klaim TO 'bpjs_mon'@'localhost';
SQL
  ); then
    say "could not create the read-only account bpjs_mon (${err:0:200}): run $APP/setup.sh install in a terminal and enter the MySQL root password when asked"
    return 1
  fi
  (umask 077; printf '[clientbpjsmon]\nuser=bpjs_mon\npassword=%s\nhost=localhost\n' "$pw" > $LOGIN)
  account_ok && say "read-only account bpjs_mon created" || say "account bpjs_mon created but cannot read: check $APP/setup.sh install"
}

webgroup() {   # PHP-FPM's group: api.php runs as it, whatever the web server (apache on RHEL)
  local f=$(ls /etc/php-fpm.d/*.conf 2>/dev/null | head -1) g=""
  [ -n "$f" ] && g=$(sed -n 's/^\s*group\s*=\s*//p' "$f" | head -1)
  echo "${g:-apache}"
}

install_hook() {
  admin || { say "no MySQL login to add the screen to SIMGOS (properti_config $PC_ID): run $APP/setup.sh install in a terminal"; return 1; }
  if [ "$(db -e "SELECT COUNT(*) FROM aplikasi.properti_config WHERE ID=$PC_ID")" = 1 ]; then
    say "SIMGOS: screen registered (properti_config $PC_ID, unchanged: keeps your enabled setting)"; return 0
  fi
  db -e "INSERT IGNORE INTO aplikasi.properti_config (ID, NAMA, VALUE, DESKRIPSI, JENIS) VALUES ($PC_ID,
    'BPJS_MONITORING', '$PC_VALUE',
    'Dashboard Klaim BPJS (rpm tatareka-bpjs-monitoring): menu di Monitoring. enabled=false untuk menyembunyikan.', 0)" \
    || { say "adding properti_config $PC_ID failed"; return 1; }
  rm -rf "${WS_CACHE:?}"/* 2>/dev/null
  say "SIMGOS: screen registered (properti_config $PC_ID); users see Monitoring > Dashboard Klaim BPJS at their next login"
}

web_check() {   # what a browser on this server gets: the script (200) and the endpoint without a login (401)
  local js api
  js=$(curl -skL -o /dev/null --max-time 10 -w '%{http_code}' "http://127.0.0.1/apps/SIMpel/packages/classic/BpjsMonitoring.js")
  api=$(curl -skL -o /dev/null --max-time 10 -w '%{http_code}' "http://127.0.0.1$API_URL?action=dashboard")
  if [ "$js" = 200 ] && [ "$api" = 401 ]; then say "web: screen script and $API_URL are served"; return 0; fi
  say "web: the screen script answers HTTP $js (expected 200) and $API_URL HTTP $api (expected 401 without a login): the web server must serve SIMGOS's /apps folder, PHP included"
  return 1
}

case "${1:-}" in
  install)
    install -d -m 0750 -g "$(webgroup)" $DATA
    chgrp "$(webgroup)" $DATA
    install_account
    install_hook
    systemctl daemon-reload >/dev/null 2>&1
    if systemctl is-active --quiet httpd && apachectl configtest >/dev/null 2>&1; then systemctl reload httpd; fi
    systemctl enable --now tatareka-bpjs-monitoring.timer tatareka-bpjs-monitoring-dashboard.timer >/dev/null 2>&1 \
      && say "timers on: BPJS status nightly at 01:00, dashboard data every 15 minutes"
    python3 $APP/bpjs_monitoring.py dashboard 2>&1 | sed 's/^/tatareka-bpjs-monitoring: dashboard: /'
    web_check
    python3 $APP/bpjs_monitoring.py status | sed 's/^/tatareka-bpjs-monitoring: /'
    ;;
  remove)
    systemctl disable --now tatareka-bpjs-monitoring.timer tatareka-bpjs-monitoring-dashboard.timer >/dev/null 2>&1
    if admin && db -e "DELETE FROM aplikasi.properti_config WHERE ID=$PC_ID" 2>/dev/null; then
      rm -rf "${WS_CACHE:?}"/* 2>/dev/null; say "SIMGOS: screen removed (properti_config $PC_ID)"
    else say "could not delete properti_config $PC_ID: delete it by hand"; fi
    say "timers stopped (the read-only account bpjs_mon and $DATA stay)"
    ;;
  *) sed -n '2,5p' "$0"; exit 1 ;;
esac
