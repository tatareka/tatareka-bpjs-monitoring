<?php
/**
 * tatareka-bpjs-monitoring — endpoint for the "Dashboard Klaim BPJS" screen in SIMGOS's Monitoring menu.
 *
 *   GET ?action=dashboard   the claims and their BPJS status (dashboard.json, rebuilt every 15 minutes by root)
 *
 * Auth: the browser's SIMGOS session cookie is forwarded to /webservice/authentication/isAuthenticate; no valid
 * session -> 401. Read-only: this file only reads dashboard.json.
 */
declare(strict_types=1);
header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');
header('X-Content-Type-Options: nosniff');

const DATA = '/var/lib/tatareka-bpjs-monitoring/dashboard.json';

function out(array $d, int $code = 200): never { http_response_code($code); echo json_encode($d, JSON_UNESCAPED_UNICODE); exit; }
function fail(int $code, string $msg): never { out(['success' => false, 'message' => $msg], $code); }

function logged_in(): void {
    $cookie = $_SERVER['HTTP_COOKIE'] ?? '';
    if ($cookie === '') fail(401, 'Silakan login ke SIMGOS');
    for ($try = 0; $try < 2; $try++) {               // a busy SIMGOS is not a logged-out user: 503, the screen retries
        $ch = curl_init('http://127.0.0.1/webservice/authentication/isAuthenticate');
        curl_setopt_array($ch, [CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => 15, CURLOPT_CONNECTTIMEOUT => 5,
                                CURLOPT_HTTPHEADER => ['Cookie: ' . $cookie, 'Accept: application/json']]);
        $body = curl_exec($ch);
        $http = (int) curl_getinfo($ch, CURLINFO_HTTP_CODE);
        curl_close($ch);
        $r = is_string($body) ? json_decode($body, true) : null;
        if ($http === 200 && is_array($r)) break;
        $r = null;
    }
    if ($r === null) fail(503, 'SIMGOS sedang sibuk, coba lagi sebentar');
    if (empty($r['success']) || empty($r['data']['ID'])) fail(401, 'Sesi SIMGOS tidak valid');
}

$action = (string) ($_GET['action'] ?? '');
if ($_SERVER['REQUEST_METHOD'] !== 'GET' || $action !== 'dashboard') fail(400, 'Permintaan tidak dikenal');
logged_in();
if (!is_readable(DATA)) fail(503, 'Data belum tersedia: jalankan tatareka-bpjs-monitoring dashboard di server SIMGOS');
$body = (string) file_get_contents(DATA);
http_response_code(200);
echo '{"success":true,"data":' . $body . '}';
