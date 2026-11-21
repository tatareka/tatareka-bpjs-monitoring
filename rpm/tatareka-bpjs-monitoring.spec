Name:           tatareka-bpjs-monitoring
Version:        %{ver}
Release:        %{rel}
Summary:        Status klaim BPJS di SIMGOS diperbarui setiap malam, dan Dashboard Klaim BPJS di menu Monitoring
License:        Apache-2.0
URL:            https://repo.tatareka.com
Source0:        %{name}-%{version}.tar.gz
BuildArch:      noarch
Requires:       simgos, python3, /usr/bin/mysql, openssl, php, systemd
%global webapp  /var/www/html/production/webapps/application
%{?systemd_requires}

%description
SIMGOS baru mengetahui keputusan BPJS atas suatu klaim (disetujui, pending, tidak layak) ketika ada petugas yang
membuka Monitoring > Status Klaim dari BPJS untuk satu tanggal pulang. Paket ini membuka layanan web SIMGOS yang sama
setiap malam pukul 01.00 untuk tanggal pulang dalam 180 hari terakhir yang masih memiliki klaim yang belum disetujui
BPJS: setiap tanggal pada malam pertama, lalu seminggu sekali pada hari yang sama dengan hari pulangnya. Hanya berjalan
di server yang dipakai petugas untuk BPJS, tidak pernah di salinannya. Paket ini tidak memegang akses BPJS: panggilan
dilakukan oleh SIMGOS dengan akses rumah sakit. Menambahkan "Dashboard Klaim BPJS" ke menu Monitoring SIMGOS: semua
klaim final 180 hari terakhir beserta posisinya di BPJS. Periksa: tatareka-bpjs-monitoring status.

%prep
%setup -q

%install
install -d %{buildroot}/opt/%{name} %{buildroot}%{_unitdir} %{buildroot}/etc/%{name} %{buildroot}/usr/bin
install -m 0700 bpjs_monitoring.py setup.sh %{buildroot}/opt/%{name}/
install -m 0644 README.md LICENSE NOTICE %{buildroot}/opt/%{name}/
install -m 0644 etc/monitoring.ini %{buildroot}/etc/%{name}/monitoring.ini
install -m 0644 files/%{name}.service files/%{name}.timer files/%{name}-dashboard.service files/%{name}-dashboard.timer %{buildroot}%{_unitdir}/
install -D -m 0644 web/api.php %{buildroot}%{webapp}/%{name}/api.php
install -D -m 0644 web/BpjsMonitoring.js %{buildroot}%{webapp}/SIMpel/packages/classic/BpjsMonitoring.js
install -D -m 0644 files/%{name}.conf %{buildroot}/etc/httpd/conf.d/%{name}.conf
printf '#!/bin/sh\nexec /usr/bin/python3 /opt/%{name}/bpjs_monitoring.py "$@"\n' > %{buildroot}/usr/bin/%{name}
chmod 0755 %{buildroot}/usr/bin/%{name}

%post
/opt/%{name}/setup.sh install || :

%preun
if [ $1 -eq 0 ]; then /opt/%{name}/setup.sh remove || :; fi

%postun
systemctl daemon-reload >/dev/null 2>&1 || :

%files
%dir /opt/%{name}
/opt/%{name}/bpjs_monitoring.py
/opt/%{name}/setup.sh
/opt/%{name}/README.md
/opt/%{name}/LICENSE
/opt/%{name}/NOTICE
%dir /etc/%{name}
%config(noreplace) /etc/%{name}/monitoring.ini
%{_unitdir}/%{name}.service
%{_unitdir}/%{name}.timer
%{_unitdir}/%{name}-dashboard.service
%{_unitdir}/%{name}-dashboard.timer
%dir %{webapp}/%{name}
%{webapp}/%{name}/api.php
%{webapp}/SIMpel/packages/classic/BpjsMonitoring.js
%config(noreplace) /etc/httpd/conf.d/%{name}.conf
/usr/bin/%{name}

%changelog
* Sat Nov 21 2026 Yanuar Aristya <aris@tatareka.com> - 1.0.0-26112102
- The read-only account bpjs_mon connects the way SIMGOS does: host, port and socket from SIMGOS's local.php, account
  host as the database server sees this server (was always 'bpjs_mon'@'localhost'). A working account is left as it is.
* Sat Nov 21 2026 Yanuar Aristya <aris@tatareka.com> - 1.0.0-26112101
- SIMGOS access right DASHBOARD KLAIM BPJS (909802, PLUGINS > TATAREKA KLAIM): only users who hold it see the menu
  item, and api.php answers 403 without it. First install gives it to the Admin SIMRS users who can open Monitoring;
  updates never change who holds it. Users outside Admin SIMRS lose the menu until it is ticked for their group and user.
* Fri Nov 20 2026 Yanuar Aristya <aris@tatareka.com> - 1.0.0-26112003
- bpjs_mon's login file is read with --defaults-file, so only it counts (1.0.0-26112002 let a [client] login in root's
  /root/.my.cnf override it).
* Fri Nov 20 2026 Yanuar Aristya <aris@tatareka.com> - 1.0.0-26112002
- The read-only account bpjs_mon keeps its login in /etc/tatareka-bpjs-monitoring/mysql.cnf (root only) instead of a
  section of root's own /root/.my.cnf; setup.sh install moves an existing [clientbpjsmon] there.
- Dashboard: the "Dicek ke BPJS" column is wide enough for its date.
* Fri Nov 20 2026 Yanuar Aristya <aris@tatareka.com> - 1.0.0-26112001
- First release, split out of tatareka-ai-klaim (Aris 2026-11-20). Two parts:
- BPJS status refresh: every night at 01:00, if a staff computer has called BPJS through SIMGOS in the last 24 hours,
  ask SIMGOS's Monitoring Klaim about the discharge dates of the last 180 days that still have a final claim BPJS has
  not approved (inacbg.hasil_grouping.KLAIM <> 3): each the first night, then weekly on its discharge weekday (a
  missed turn the next night that runs); 3 calls per date and care type, 1 s apart; a failing date is skipped, 3 in a
  row stop; at most 60 minutes. One setting: refresh = on | off in /etc/tatareka-bpjs-monitoring/monitoring.ini.
- Dashboard Klaim BPJS: a screen in SIMGOS's Monitoring menu (after AI Klaim when that is installed; properti_config
  909902, BpjsMonitoring.js, endpoint /apps/tatareka-bpjs-monitoring/api.php for logged-in SIMGOS users only). Every
  final claim discharged in the last 180 days with its BPJS status (approved, pending, tidak layak, in verification,
  not at BPJS yet): tiles (needs attention = pending + tidak layak + not at BPJS after 30 days; approved with the
  amount cut), a per-discharge-month table, the claim list with filters; double-click opens Coding & Grouping. Data
  rebuilt every 15 minutes and after each nightly run (dashboard.json, web group only).
- Read-only MySQL account bpjs_mon: inacbg.grouping, inacbg.hasil_grouping, bpjs.klaim, logs.bridge_log (TGL_REQUEST,
  ACCESS_FROM_IP only).
