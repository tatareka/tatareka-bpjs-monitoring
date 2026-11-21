#!/bin/bash
# tatareka-bpjs-monitoring setup. Run by the RPM (%post install, %preun remove); safe to run again at any time.
#
#   setup.sh install   read-only MySQL account bpjs_mon, the "Dashboard Klaim BPJS" screen in SIMGOS and the access
#                      right for it, the timers
#   setup.sh remove    take the screen, the access right and its grants out of SIMGOS and stop the timers (files are
#                      removed by rpm; the account stays, it can only read)
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
# Who sees the screen is a SIMGOS access right, added the way SIMGOS's own plugins add theirs: a heading under
# 90 PLUGINS (shared with tatareka-ai-klaim, whose right is 909801) and under it the right itself. Neither row has a
# screen (no CLASS, no CONFIG), so nothing new shows in SIMGOS except in the access trees of Manajemen Pengguna.
# BpjsMonitoring.js and api.php carry the same ID.
IZ_HEAD=9098; IZ_HEAD_NAME="TATAREKA KLAIM"
IZ_ID=909802; IZ_NAME="DASHBOARD KLAIM BPJS"
IZ_GROUP="Admin SIMRS"   # SIMGOS group (master.referensi JENIS 43) whose users get the right when it is first added
IZ_MON=26                # SIMGOS's own module MONITORING, where the menu is
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

izin_state() {   # ok | absent | partial (heading only) | noplugins | taken (an ID belongs to something else) | unknown
  local r
  r=$(db -e "SELECT CONCAT(ID, '=', NAMA) FROM aplikasi.modules WHERE ID IN ('90', '$IZ_HEAD', '$IZ_ID') ORDER BY ID" 2>/dev/null) || { echo unknown; return; }
  case $r in
    "90=PLUGINS") echo absent ;;
    "90=PLUGINS"$'\n'"$IZ_HEAD=$IZ_HEAD_NAME") echo partial ;;
    "90=PLUGINS"$'\n'"$IZ_HEAD=$IZ_HEAD_NAME"$'\n'"$IZ_ID=$IZ_NAME") echo ok ;;
    ""|"$IZ_HEAD="*|"$IZ_ID="*) echo noplugins ;;
    *) echo taken ;;
  esac
}

# Adds the two rows where they are missing and, in the same transaction, gives the right to the hospital's SIMGOS
# admins: to the group $IZ_GROUP, and to those of its active users who can open Monitoring through that group. A user
# in SIMGOS holds a right through two rows (the group's and their own), so both are written, the heading's included,
# as Manajemen Pengguna does. Only rows that do not exist are inserted; none is changed. This runs once, when the
# right is first added: later installs and updates give it to nobody, so what the hospital ticks or unticks stays.
sql_izin() {
  cat <<SQL
START TRANSACTION;
INSERT INTO aplikasi.modules (ID, NAMA, LEVEL, DESKRIPSI, STATUS, CLASS, HAVE_CHILD, MENU_HOME, MENU_MASTER, PACKAGE_NAME, INTERNAL_PACKAGE)
SELECT '$IZ_HEAD', '$IZ_HEAD_NAME', 2, 'Tatareka Klaim', 1, NULL, 1, 0, 0, NULL, 0 FROM DUAL
 WHERE NOT EXISTS (SELECT 1 FROM aplikasi.modules WHERE ID = '$IZ_HEAD');
INSERT INTO aplikasi.modules (ID, NAMA, LEVEL, DESKRIPSI, STATUS, CLASS, HAVE_CHILD, MENU_HOME, MENU_MASTER, PACKAGE_NAME, INTERNAL_PACKAGE)
SELECT '$IZ_ID', '$IZ_NAME', 3, 'Dashboard Klaim BPJS di Monitoring: klaim final dan statusnya di BPJS (rpm tatareka-bpjs-monitoring)', 1, NULL, 0, 0, 0, NULL, 0 FROM DUAL
 WHERE NOT EXISTS (SELECT 1 FROM aplikasi.modules WHERE ID = '$IZ_ID');
SET @g = (SELECT ID FROM master.referensi WHERE JENIS = 43 AND STATUS = 1 AND TRIM(DESKRIPSI) = '$IZ_GROUP' ORDER BY ID LIMIT 1);
INSERT INTO aplikasi.group_pengguna_akses_module (GROUP_PENGGUNA, MODUL, STATUS)
SELECT @g, m.ID, 1 FROM aplikasi.modules m
 WHERE m.ID IN ('$IZ_HEAD', '$IZ_ID') AND @g IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM aplikasi.group_pengguna_akses_module x WHERE x.GROUP_PENGGUNA = @g AND x.MODUL = m.ID);
INSERT INTO aplikasi.pengguna_akses (PENGGUNA, GROUP_PENGGUNA_AKSES_MODULE, STATUS)
SELECT u.PENGGUNA, g.ID, 1
  FROM (SELECT DISTINCT pa.PENGGUNA
          FROM aplikasi.pengguna_akses pa
          JOIN aplikasi.group_pengguna_akses_module gm ON gm.ID = pa.GROUP_PENGGUNA_AKSES_MODULE
          JOIN aplikasi.pengguna p ON p.ID = pa.PENGGUNA
         WHERE pa.STATUS = 1 AND gm.STATUS = 1 AND gm.GROUP_PENGGUNA = @g AND gm.MODUL = '$IZ_MON' AND p.STATUS = 1) u
  JOIN aplikasi.group_pengguna_akses_module g ON g.GROUP_PENGGUNA = @g AND g.MODUL IN ('$IZ_HEAD', '$IZ_ID') AND g.STATUS = 1
 WHERE NOT EXISTS (SELECT 1 FROM aplikasi.pengguna_akses x WHERE x.PENGGUNA = u.PENGGUNA AND x.GROUP_PENGGUNA_AKSES_MODULE = g.ID);
COMMIT;
SQL
}

# Takes the right out again: the grants of it first, then the row; the heading only when nothing else is under it.
# Every statement names the row by ID and by name, so a row that is not this package's is never touched.
sql_izin_drop() {
  local w n=0
  echo "USE aplikasi;"   # MySQL resolves the alias after DELETE against the default database (error 1046 without one)
  echo "START TRANSACTION;"
  for w in "m.ID = '$IZ_ID' AND m.NAMA = '$IZ_NAME'" "m.ID = '$IZ_HEAD' AND m.NAMA = '$IZ_HEAD_NAME' AND @lain = 0"; do
    [ $((n++)) -eq 0 ] || echo "SET @lain = (SELECT COUNT(*) FROM aplikasi.modules WHERE ID LIKE '$IZ_HEAD%' AND ID <> '$IZ_HEAD');"
    echo "DELETE pa FROM aplikasi.pengguna_akses pa JOIN aplikasi.group_pengguna_akses_module g ON g.ID = pa.GROUP_PENGGUNA_AKSES_MODULE JOIN aplikasi.modules m ON m.ID = g.MODUL WHERE $w;"
    echo "DELETE g FROM aplikasi.group_pengguna_akses_module g JOIN aplikasi.modules m ON m.ID = g.MODUL WHERE $w;"
    echo "DELETE m FROM aplikasi.modules m WHERE $w;"
  done
  echo "COMMIT;"
}

izin_holders() {   # logins the right lets through: the rule of SIMGOS's own login, active users only
  local r
  r=$(db -e "SELECT GROUP_CONCAT(DISTINCT p.LOGIN ORDER BY p.LOGIN SEPARATOR ', ')
    FROM aplikasi.group_pengguna_akses_module g
    JOIN aplikasi.pengguna_akses pa ON pa.GROUP_PENGGUNA_AKSES_MODULE = g.ID AND pa.STATUS = 1
    JOIN aplikasi.pengguna p ON p.ID = pa.PENGGUNA AND p.STATUS = 1
    WHERE g.MODUL = '$IZ_ID' AND g.STATUS = 1" 2>/dev/null)
  case $r in ""|NULL) echo "nobody yet" ;; *) echo "$r" ;; esac
}
IZ_HOW="SIMGOS, Manajemen Pengguna: tick PLUGINS > $IZ_HEAD_NAME > $IZ_NAME for a group (Group Pengguna Akses Modul), then in the access of each user who should have it"

install_izin() {
  admin || { say "no MySQL login to add the access right $IZ_ID \"$IZ_NAME\" to SIMGOS, so nobody sees the screen: run $APP/setup.sh install in a terminal"; return 1; }
  local st err h; st=$(izin_state)
  case $st in
    absent|partial)
      if err=$(sql_izin | db 2>&1) && [ "$(izin_state)" = ok ]; then
        rm -rf "${WS_CACHE:?}"/* 2>/dev/null
        h=$(izin_holders)
        say "access right: $IZ_ID \"$IZ_NAME\" added to SIMGOS (PLUGINS > $IZ_HEAD_NAME): the screen now shows only for users who hold it"
        if [ "$h" = "nobody yet" ]; then
          say "access right: nobody holds it yet (no group \"$IZ_GROUP\", or none of its users can open Monitoring). To give it: $IZ_HOW"
        else
          say "access right: given to the users of the group \"$IZ_GROUP\" who can open Monitoring: $h"
          say "access right: for anyone else: $IZ_HOW. It shows at their next login"
        fi
      else say "adding the access right $IZ_ID \"$IZ_NAME\" to SIMGOS failed (${err:0:200}), so nobody sees the screen: run $APP/setup.sh install again"; return 1; fi ;;
    ok) say "access right: $IZ_ID \"$IZ_NAME\" present (grants unchanged), held by: $(izin_holders)" ;;
    noplugins) say "SIMGOS has no module 90 PLUGINS to put the access right $IZ_ID \"$IZ_NAME\" under, so nobody sees the screen: tell Tatareka"; return 1 ;;
    taken) say "module ID $IZ_HEAD or $IZ_ID already belongs to something else in SIMGOS, so the access right \"$IZ_NAME\" could not be added and nobody sees the screen: tell Tatareka"; return 1 ;;
    *) say "SIMGOS's modules could not be read, so the access right $IZ_ID \"$IZ_NAME\" was not checked"; return 1 ;;
  esac
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
    install_izin
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
    case $(izin_state) in ok)
      sql_izin_drop | db >/dev/null 2>&1
      case $(izin_state) in
        absent)  say "SIMGOS: access right $IZ_ID and its grants removed" ;;
        partial) say "SIMGOS: access right $IZ_ID and its grants removed (heading $IZ_HEAD stays: another package's right is under it)" ;;
        *)       say "could not remove the access right $IZ_ID from SIMGOS: untick and delete it by hand (aplikasi.modules)" ;;
      esac ;;
    esac
    say "timers stopped (the read-only account bpjs_mon and $DATA stay)"
    ;;
  *) sed -n '2,5p' "$0"; exit 1 ;;
esac
