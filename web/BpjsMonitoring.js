/*
 * Dashboard Klaim BPJS (rpm tatareka-bpjs-monitoring): a screen in SIMGOS's Monitoring menu showing every final claim
 * of the last 180 days and where it stands at BPJS (approved, pending, tidak layak, in verification, not seen yet).
 * Loaded by SIMGOS after login through properti_config 909902; overrides only, no SIMGOS file edited.
 * Data: /apps/tatareka-bpjs-monitoring/api.php?action=dashboard (rebuilt every 15 minutes on the server).
 */
(function () {
    if (window.TtrkBpjsMonLoaded) return;
    window.TtrkBpjsMonLoaded = true;
    var API = '/apps/tatareka-bpjs-monitoring/api.php';
    // SIMGOS access right DASHBOARD KLAIM BPJS (aplikasi.modules, registered by setup.sh; the same ID is in api.php).
    // Asked the way SIMGOS's own screens ask; the rights are those of the user's login.
    var RIGHT = '909802';
    function allowed() {
        try { return webservice.app.xpriv(RIGHT, false) === true; } catch (e) { return false; }
    }

    var STATUS = {   // order = how they are listed
        pending: ['Pending', '#ca6f1e'], tidak_layak: ['Tidak layak', '#c0392b'], verifikasi: ['Proses verifikasi', '#2e86c1'],
        unseen: ['Belum ada di BPJS', '#7b7d7d'], approved: ['Disetujui', '#1e8449']
    };
    var CARE = {1: 'Rawat Inap', 2: 'Rawat Jalan'};
    var BULAN = ['Jan', 'Feb', 'Mar', 'Apr', 'Mei', 'Jun', 'Jul', 'Agu', 'Sep', 'Okt', 'Nov', 'Des'];
    var LATE_DAYS = 30;   // a final claim BPJS still does not list after this many days since discharge needs a look

    function esc(s) {
        return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
            return {'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'}[c];
        });
    }
    function rp(v) {
        if (v == null) return '';
        return 'Rp ' + Math.round(v).toString().replace(/\B(?=(\d{3})+(?!\d))/g, '.');
    }
    function rpShort(v) {   // Rp 1,2 M / Rp 345 jt for the tiles
        if (!v) return 'Rp 0';
        if (v >= 1e9) return 'Rp ' + (v / 1e9).toFixed(1).replace('.', ',') + ' M';
        if (v >= 1e6) return 'Rp ' + Math.round(v / 1e6) + ' jt';
        return rp(v);
    }
    function badge(k) {
        var x = STATUS[k] || [k, '#7b7d7d'];
        return '<span style="display:inline-block;padding:1px 8px;border-radius:9px;color:#fff;background:' + x[1] +
               ';font-size:11px;font-weight:600;white-space:nowrap">' + esc(x[0]) + '</span>';
    }
    function daysSince(d) { return Math.floor((Date.now() - new Date(d + 'T00:00:00').getTime()) / 864e5); }
    function late(r) { return r.status === 'unseen' && daysSince(r.pulang) > LATE_DAYS; }
    function attention(r) { return r.status === 'pending' || r.status === 'tidak_layak' || late(r); }
    function month(d) { return BULAN[+d.slice(5, 7) - 1] + ' ' + d.slice(0, 4); }

    // Double-click opens SIMGOS's own Coding & Grouping for the claim, as its patient dashboard does.
    function openCodingGrouping(r, grid) {
        if (!Ext.ClassManager.get('plugins.kemkes.eklaim.tipe.Workspace') || !Ext.ClassManager.get('data.store.Pendaftaran')) {
            Ext.Msg.alert('Dashboard Klaim BPJS', 'Coding & Grouping tidak tersedia di SIMGOS ini.'); return;
        }
        var st = Ext.create('data.store.Pendaftaran');
        st.setQueryParams({NOMOR: r.nopen});
        grid.setLoading('Membuka Coding & Grouping…');
        st.load({callback: function (recs, op, ok) {
            grid.setLoading(false);
            var rec = ok && recs && recs[0];
            if (!rec) { Ext.Msg.alert('Dashboard Klaim BPJS', 'Data pendaftaran ' + esc(r.nopen) + ' tidak ditemukan.'); return; }
            var win = Ext.create('Ext.window.Window', {
                title: 'Coding & Grouping - <strong>' + esc(r.nopen) + '</strong>', ui: 'window-cyan',
                header: {margin: 0, padding: '5 10 5 10'}, width: 280, height: 135, modal: true, layout: 'fit', border: true,
                items: {xtype: 'plugins-kemkes-eklaim-tipe-workspace'}
            });
            win.show();
            var g = win.down('plugins-kemkes-eklaim-tipe-workspace');
            g.loadRecord(rec);
            g.on({buka: function () { win.close(); }});
        }});
    }

    var CSS = '<style>' +
        '.ttrk-bm{font-size:13px;color:#333;padding:10px 12px 4px}' +
        '.ttrk-bm .tiles{display:flex;flex-wrap:wrap;gap:10px;margin-bottom:12px}' +
        '.ttrk-bm .tile{flex:1 1 150px;min-width:150px;border:1px solid #dde1e4;border-left:4px solid #ccc;border-radius:4px;' +
        'padding:8px 10px;background:#fff;cursor:pointer}' +
        '.ttrk-bm .tile:hover{background:#f6f8f9}.ttrk-bm .tile.on{background:#eef4fb}' +
        '.ttrk-bm .tile .n{font-size:22px;font-weight:600;line-height:1.2}' +
        '.ttrk-bm .tile .l{font-size:12px;color:#555}.ttrk-bm .tile .s{font-size:11px;color:#777;margin-top:2px}' +
        '.ttrk-bm table{border-collapse:collapse;width:100%;font-size:12px}' +
        '.ttrk-bm th,.ttrk-bm td{padding:4px 8px;border-bottom:1px solid #eceff1;text-align:right;white-space:nowrap}' +
        '.ttrk-bm th{color:#666;font-weight:600;background:#f7f8f9}.ttrk-bm td:first-child,.ttrk-bm th:first-child{text-align:left}' +
        '.ttrk-bm tr.m{cursor:pointer}.ttrk-bm tr.m:hover td{background:#f6f8f9}.ttrk-bm tr.on td{background:#eef4fb}' +
        '.ttrk-bm .bar{display:inline-block;height:8px;border-radius:2px;vertical-align:middle}' +
        '.ttrk-bm .muted{color:#888}.ttrk-bm h4{margin:4px 0 6px;font-size:12px;color:#555;text-transform:uppercase;letter-spacing:.04em}' +
        '</style>';

    Ext.define('TtrkBpjsMon.Dashboard', {
        extend: 'Ext.panel.Panel',
        xtype: 'ttrk-bpjsmon-dashboard',
        layout: 'border',
        initComponent: function () {
            var me = this, cb = function (name, data, value, width) {
                return {xtype: 'combobox', itemId: name, store: data, value: value, queryMode: 'local', editable: false,
                        width: width || 170, listeners: {change: function () { me.applyFilter(); }}};
            };
            me.filter = {status: 'attention', month: ''};
            me.items = [{
                region: 'north', itemId: 'summary', split: true, collapsible: true, header: false, height: 300,
                scrollable: true, html: '<div class="ttrk-bm muted">Memuat…</div>',
                listeners: {
                    afterrender: function (c) {
                        c.getEl().on('click', function (e) {
                            var t = e.getTarget('[data-status]'), m = e.getTarget('[data-month]');
                            if (t) me.setStatus(t.getAttribute('data-status'));
                            if (m) me.setMonth(m.getAttribute('data-month'));
                        });
                    }
                }
            }, {
                region: 'center', xtype: 'grid', itemId: 'grid',
                emptyText: 'Tidak ada klaim untuk pilihan ini.',
                store: Ext.create('Ext.data.Store', {fields: ['nopen', 'sep', 'norm', 'nama', 'pulang', 'care', 'cbg', 'status',
                    'status_text', 'rp_rs', 'rp_klaim', 'rp_aju', 'rp_setuju', 'fpk', 'asked'], data: []}),
                columns: [
                    {text: 'Status BPJS', dataIndex: 'status', width: 140, renderer: function (v, m, r) {
                        var h = badge(v);
                        if (v === 'unseen') h += '<br><span style="color:' + (late(r.data) ? '#c0392b' : '#777') + ';font-size:11px">' +
                            daysSince(r.get('pulang')) + ' hari sejak pulang</span>';
                        return h;
                    }},
                    {text: 'Pasien', dataIndex: 'nama', flex: 1, minWidth: 220, renderer: function (v, m, r) {
                        return esc(v) + '<br><span style="color:#777;font-size:11px">RM ' + esc(r.get('norm')) + ' · ' + esc(r.get('sep')) + '</span>';
                    }},
                    {text: 'Pulang', dataIndex: 'pulang', width: 95, renderer: function (v) { return v ? Ext.util.Format.date(v, 'd-m-Y') : ''; }},
                    {text: 'Jenis', dataIndex: 'care', width: 95, renderer: function (v) { return CARE[v] || ''; }},
                    {text: 'INA-CBG', dataIndex: 'cbg', width: 95},
                    {text: 'Nilai klaim', dataIndex: 'rp_klaim', width: 115, align: 'right', renderer: rp},
                    {text: 'Diajukan', dataIndex: 'rp_aju', width: 115, align: 'right', renderer: rp},
                    {text: 'Disetujui', dataIndex: 'rp_setuju', width: 115, align: 'right', renderer: function (v, m, r) {
                        if (v == null || r.get('status') !== 'approved') return '';
                        var cut = (r.get('rp_aju') || 0) - v;
                        return rp(v) + (cut > 0 ? '<br><span style="color:#c0392b;font-size:11px">−' + rp(cut) + '</span>' : '');
                    }},
                    {text: 'FPK', dataIndex: 'fpk', width: 120},
                    {text: 'Dicek ke BPJS', dataIndex: 'asked', width: 145, renderer: function (v) {
                        return v ? esc(v.replace('T', ' ')) : '<span style="color:#aaa">belum</span>';
                    }}
                ],
                tbar: {overflowHandler: 'menu', items: [
                    cb('fStatus', [['attention', 'Perlu perhatian'], ['pending', 'Pending'], ['tidak_layak', 'Tidak layak'],
                                   ['verifikasi', 'Proses verifikasi'], ['unseen', 'Belum ada di BPJS'], ['approved', 'Disetujui'],
                                   ['', 'Semua status']], 'attention'),
                    cb('fCare', [['', 'Semua jenis'], [1, 'Rawat Inap'], [2, 'Rawat Jalan']], '', 130),
                    cb('fMonth', [['', 'Semua bulan']], '', 130),
                    {xtype: 'textfield', itemId: 'fText', emptyText: 'Cari nama / RM / SEP / FPK', width: 200,
                     listeners: {change: {fn: function () { me.applyFilter(); }, buffer: 250}}}
                ]},
                bbar: [{xtype: 'tbtext', itemId: 'count'}, '->', {xtype: 'tbtext', itemId: 'info'},
                       {text: 'Muat Ulang', iconCls: 'x-fa fa-refresh', ui: 'soft-gray', handler: function () { me.load(); }}],
                listeners: {itemdblclick: function (g, r) { openCodingGrouping(r.data, me.down('#grid')); }}
            }];
            me.callParent(arguments);
            me.on('afterrender', function () { me.load(); });
        },

        load: function () {
            var me = this;
            me.setLoading('Memuat…');
            Ext.Ajax.request({
                url: API, method: 'GET', params: {action: 'dashboard'},
                success: function (resp) {
                    me.setLoading(false);
                    var d = {};
                    try { d = Ext.decode(resp.responseText).data || {}; } catch (e) {}
                    me.data = d;
                    me.rows = d.rows || [];
                    var months = {};
                    me.rows.forEach(function (r) { months[r.pulang.slice(0, 7)] = 1; });
                    me.down('#fMonth').getStore().loadData([['', 'Semua bulan']].concat(
                        Object.keys(months).sort().reverse().map(function (k) { return [k, month(k)]; })));
                    me.renderSummary();
                    me.applyFilter();
                },
                failure: function (resp) {
                    me.setLoading(false);
                    var msg = {401: 'Sesi SIMGOS sudah berakhir. Silakan login ulang.',
                               403: 'Akun Anda tidak memiliki hak akses DASHBOARD KLAIM BPJS di SIMGOS (Manajemen Pengguna, ' +
                                    'PLUGINS > TATAREKA KLAIM).',
                               404: 'Dashboard Klaim BPJS belum aktif di server SIMGOS (alamat ' + API + ' tidak ditemukan). ' +
                                    'Minta tim IT menjalankan /opt/tatareka-bpjs-monitoring/setup.sh install.',
                               503: 'Data belum tersedia atau SIMGOS sedang sibuk. Coba lagi sebentar lagi.'}[resp.status] ||
                              'Data tidak dapat dimuat (HTTP ' + resp.status + ').';
                    me.down('#summary').setHtml('<div class="ttrk-bm" style="color:#c0392b">' + esc(msg) + '</div>');
                }
            });
        },

        setStatus: function (s) { this.down('#fStatus').setValue(s); },
        setMonth: function (m) { var f = this.down('#fMonth'); f.setValue(f.getValue() === m ? '' : m); },

        renderSummary: function () {
            var me = this, rows = me.rows, sum = {}, n = {}, cur = me.down('#fStatus').getValue(), mon = me.down('#fMonth').getValue();
            Object.keys(STATUS).forEach(function (k) { n[k] = 0; sum[k] = 0; });
            var lateN = 0, lateRp = 0, cut = 0;
            rows.forEach(function (r) {
                n[r.status]++;
                sum[r.status] += (r.status === 'approved' ? r.rp_setuju : r.rp_aju || r.rp_klaim) || 0;
                if (late(r)) { lateN++; lateRp += r.rp_klaim || 0; }
                if (r.status === 'approved' && r.rp_aju && r.rp_setuju != null) cut += Math.max(0, r.rp_aju - r.rp_setuju);
            });
            var att = n.pending + n.tidak_layak + lateN;
            function tile(key, label, count, sub, color) {
                return '<div class="tile' + (cur === key ? ' on' : '') + '" data-status="' + key + '" style="border-left-color:' + color + '">' +
                    '<div class="n">' + count.toLocaleString('id-ID') + '</div><div class="l">' + label + '</div><div class="s">' + sub + '</div></div>';
            }
            var h = '<div class="ttrk-bm">' + '<div class="tiles">' +
                tile('attention', 'Perlu perhatian', att, 'pending, tidak layak, dan belum ada di BPJS &gt; ' + LATE_DAYS + ' hari', '#8e44ad') +
                tile('approved', 'Disetujui', n.approved, rpShort(sum.approved) + (cut ? ' · dipotong ' + rpShort(cut) : ''), STATUS.approved[1]) +
                tile('pending', 'Pending', n.pending, rpShort(sum.pending) + ' diajukan', STATUS.pending[1]) +
                tile('tidak_layak', 'Tidak layak', n.tidak_layak, rpShort(sum.tidak_layak) + ' diajukan', STATUS.tidak_layak[1]) +
                tile('verifikasi', 'Proses verifikasi', n.verifikasi, rpShort(sum.verifikasi) + ' diajukan', STATUS.verifikasi[1]) +
                tile('unseen', 'Belum ada di BPJS', n.unseen, lateN + ' lebih dari ' + LATE_DAYS + ' hari (' + rpShort(lateRp) + ')', STATUS.unseen[1]) +
                '</div>';
            // per discharge month: count by status as a stacked bar, then the figures
            var bym = {};
            rows.forEach(function (r) {
                var k = r.pulang.slice(0, 7), m = bym[k] = bym[k] || {total: 0, klaim: 0, setuju: 0};
                m.total++; m[r.status] = (m[r.status] || 0) + 1; m.klaim += r.rp_klaim || 0;
                if (r.status === 'approved') m.setuju += r.rp_setuju || 0;
            });
            var max = Math.max.apply(null, Object.keys(bym).map(function (k) { return bym[k].total; }).concat([1]));
            h += '<h4>Per bulan pulang</h4><table><tr><th>Bulan</th><th style="text-align:left">Status</th><th>Klaim final</th>' +
                 '<th>Disetujui</th><th>Pending</th><th>Tidak layak</th><th>Verifikasi</th><th>Belum ada</th><th>Nilai klaim</th><th>Disetujui (Rp)</th></tr>';
            Object.keys(bym).sort().reverse().forEach(function (k) {
                var m = bym[k], bar = '';
                Object.keys(STATUS).forEach(function (s) {
                    if (m[s]) bar += '<span class="bar" title="' + STATUS[s][0] + ' ' + m[s] + '" style="width:' +
                        Math.max(2, Math.round(160 * m[s] / max)) + 'px;background:' + STATUS[s][1] + '"></span>';
                });
                var pct = m.total ? Math.round(100 * (m.approved || 0) / m.total) : 0;
                h += '<tr class="m' + (mon === k ? ' on' : '') + '" data-month="' + k + '"><td>' + month(k) + '</td><td style="text-align:left">' + bar + '</td>' +
                     '<td>' + m.total + '</td><td>' + (m.approved || 0) + ' <span class="muted">(' + pct + '%)</span></td>' +
                     '<td>' + (m.pending || '') + '</td><td>' + (m.tidak_layak || '') + '</td><td>' + (m.verifikasi || '') + '</td>' +
                     '<td>' + (m.unseen || '') + '</td><td>' + rp(m.klaim) + '</td><td>' + rp(m.setuju) + '</td></tr>';
            });
            h += '</table><div class="muted" style="margin:6px 0 2px;font-size:11px">Klaim yang sudah final di SIMGOS dan pulang dalam ' +
                 esc(me.data.window_days || 180) + ' hari terakhir. Klik kotak atau bulan untuk menyaring daftar di bawah; klik dua kali klaim untuk membuka Coding &amp; Grouping.</div></div>';
            me.down('#summary').setHtml(CSS + h);
        },

        applyFilter: function () {
            var me = this;
            if (!me.rows) return;
            var s = me.down('#fStatus').getValue(), c = me.down('#fCare').getValue(), mo = me.down('#fMonth').getValue(),
                t = (me.down('#fText').getValue() || '').toLowerCase();
            var rows = me.rows.filter(function (r) {
                if (s === 'attention' ? !attention(r) : s && r.status !== s) return false;
                if (c && r.care !== c) return false;
                if (mo && r.pulang.slice(0, 7) !== mo) return false;
                if (t && ((r.nama || '') + ' ' + (r.norm || '') + ' ' + (r.sep || '') + ' ' + (r.fpk || '')).toLowerCase().indexOf(t) < 0) return false;
                return true;
            });
            var order = {tidak_layak: 0, pending: 1, unseen: 2, verifikasi: 3, approved: 4};
            rows.sort(function (a, b) { return (order[a.status] - order[b.status]) || (a.pulang < b.pulang ? -1 : 1); });
            var g = me.down('#grid');
            g.getStore().loadData(rows);
            me.down('#count').setHtml(rows.length.toLocaleString('id-ID') + ' klaim');
            var d = me.data || {}, rf = d.refresh || {};
            me.down('#info').setHtml('<span style="color:#777;font-size:11px">' +
                (rf.runs_here ? 'Status BPJS diperbarui otomatis tiap malam' : 'Pembaruan otomatis tidak berjalan: ' + esc(rf.why || '')) +
                (d.built ? ' · data ' + esc(String(d.built).replace('T', ' ')) : '') + '</span>');
            me.renderSummary();
        }
    });

    /*
     * SIMGOS's Monitoring module (monitoring.Workspace, packages/classic/monitoring.js) builds its left menu and then
     * calls addMenus(), an empty hook. "Dashboard Klaim BPJS" is added there, after "AI Klaim" when that is installed. The
     * override calls the previous one first (callParent), so other packages' items stay, whichever loads first. Only
     * users who hold the access right DASHBOARD KLAIM BPJS get the item.
     */
    Ext.ClassManager.onCreated(function () {
        Ext.override(Ext.ClassManager.get('monitoring.Workspace'), {
            addMenus: function () {
                var r = this.callParent(arguments);
                var f = this.down('com-form'), menus = f && f.menuConfig && f.menuConfig.menus;
                if (menus && allowed() && !menus.some(function (m) { return m.className === 'TtrkBpjsMon.Dashboard'; })) {
                    var at = menus.some(function (m) { return m.className === 'SimgosAi.Worklist'; }) ? 1 : 0;
                    menus = menus.slice();
                    menus.splice(at, 0, {text: 'Dashboard Klaim BPJS', leaf: true, iconCls: 'x-fa fa-tachometer',
                                         className: 'TtrkBpjsMon.Dashboard', idClassName: 'ttrk_bpjsmon_dashboard'});
                    f.setMenus(menus);
                }
                return r === undefined ? true : r;
            }
        });
    }, null, 'monitoring.Workspace');
})();
