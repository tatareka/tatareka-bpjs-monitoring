#!/bin/bash
# Build the tatareka-bpjs-monitoring RPM into rpm/dist/.   build.sh [version] [release]
set -euo pipefail
cd "$(dirname "$0")/.."
VER=${1:-$(tr -d ' \n' < VERSION)}; REL=${2:-$(date +%y%m%d%H)}
NAME=tatareka-bpjs-monitoring; TOP=$PWD/rpm/build; N=$NAME-$VER
rm -rf "$TOP" rpm/dist; mkdir -p "$TOP"/{SOURCES,SPECS,BUILD,RPMS,SRPMS} "$TOP/tmp/$N"
cp -a bpjs_monitoring.py setup.sh etc web README.md LICENSE NOTICE "$TOP/tmp/$N/"; cp -a rpm/files "$TOP/tmp/$N/files"
tar -C "$TOP/tmp" -czf "$TOP/SOURCES/$N.tar.gz" "$N"
# --target: built on a Mac the package would be labelled os=darwin and dnf would refuse it on every server
rpmbuild --define "_topdir $TOP" --define "ver $VER" --define "rel $REL" --define "_unitdir /usr/lib/systemd/system" \
  --define "_dbpath $TOP/rpmdb" --define "_sysconfdir /etc" --target noarch-redhat-linux -ba rpm/$NAME.spec >"$TOP/build.log" 2>&1 \
  || { tail -30 "$TOP/build.log"; exit 1; }
for r in "$TOP"/RPMS/noarch/*.rpm; do
  [ "$(rpm -qp --qf '%{os}' "$r" 2>/dev/null)" = linux ] || { echo "build.sh: $r is not labelled os=linux" >&2; exit 1; }
done
mkdir -p rpm/dist; cp "$TOP"/RPMS/noarch/*.rpm "$TOP"/SRPMS/*.rpm rpm/dist/
ls -l rpm/dist/
