"""dashboard-hub — gateway multi-DC chạy trên máy LOCAL (Mac/laptop admin).

Mỗi VM APISIX vẫn chạy dashboard đầy đủ của riêng nó. Hub làm 2 việc:

1. TRANG TỔNG QUAN (http://localhost:18000): poll song song mọi peer trong
   peers.yaml → card health / DC / HEAD commit / gitsync / hot-reload.

2. REVERSE PROXY THEO SUBDOMAIN (http://<id>.localhost:18000): forward TOÀN BỘ
   request (UI tĩnh + API, mọi method GET/POST/...) tới dashboard của VM đó
   → xem VÀ CRUD trực tiếp từ hub, không cần mở dashboard từng VM.
   *.localhost tự resolve về 127.0.0.1 trên Chrome/Firefox (Safari cũ: thêm
   dòng `127.0.0.1 hcm.localhost` vào /etc/hosts).

Mac không route trực tiếp tới VM (sau jump host) → peers.yaml trỏ qua SSH tunnel
đang mở trên máy local. Tunnel tắt = peer unreachable (card báo rõ).
"""

from __future__ import annotations

import asyncio
import base64
import os
from pathlib import Path
from typing import Any, Optional

import httpx
import yaml
from fastapi import FastAPI, Request, Response
from fastapi.responses import HTMLResponse, JSONResponse

PEERS_FILE = Path(os.environ.get("PEERS_FILE", "/app/peers.yaml"))
PROBE_TIMEOUT = float(os.environ.get("PROBE_TIMEOUT", "4"))
PROXY_TIMEOUT = float(os.environ.get("PROXY_TIMEOUT", "60"))  # save = git push, có thể vài giây
HUB_PORT = int(os.environ.get("HUB_PORT", "18000"))

app = FastAPI(title="APISIX Dashboard Hub", docs_url=None, redoc_url=None)

# Header hop-by-hop — không forward qua proxy
_SKIP_REQ_HEADERS = {"host", "content-length", "connection", "keep-alive", "transfer-encoding"}
_SKIP_RESP_HEADERS = {"content-length", "connection", "keep-alive", "transfer-encoding",
                      "content-encoding"}


def load_peers() -> dict[str, dict[str, Any]]:
    """Trả {id: peer}. id = subdomain (chữ thường, a-z0-9-)."""
    if not PEERS_FILE.is_file():
        return {}
    data = yaml.safe_load(PEERS_FILE.read_text(encoding="utf-8")) or {}
    peers: dict[str, dict[str, Any]] = {}
    for p in data.get("peers", []):
        pid = str(p.get("id", "")).lower().strip()
        if pid and p.get("url"):
            peers[pid] = p
    return peers


def _peer_headers(peer: dict[str, Any]) -> dict[str, str]:
    if peer.get("auth_basic"):  # khi dashboard peer bật AUTH_MODE=basic
        return {"Authorization": "Basic " + base64.b64encode(peer["auth_basic"].encode()).decode()}
    return {}


def _peer_from_host(request: Request) -> tuple[Optional[str], Optional[dict[str, Any]]]:
    """hcm.localhost:18000 → ('hcm', peer). localhost:18000 (không subdomain) → (None, None)."""
    host = request.headers.get("host", "").split(":")[0].lower()
    parts = host.split(".")
    if len(parts) < 2:
        return None, None
    pid = parts[0]
    return pid, load_peers().get(pid)


def _hub_peers_payload(current_id: Optional[str]) -> dict[str, Any]:
    """Danh sách peer cho dropdown DC trong dashboard frontend (label: DC — hostname — ip)."""
    items = []
    for pid, p in load_peers().items():
        dc = str(p.get("dc", pid)).upper()
        label_parts = [dc]
        if p.get("hostname"):
            label_parts.append(str(p["hostname"]))
        if p.get("ip"):
            label_parts.append(str(p["ip"]))
        label = " — ".join(label_parts) if len(label_parts) > 1 else str(p.get("name", pid))
        items.append({"id": pid, "dc": dc, "label": label})
    return {"current": current_id, "hub_port": HUB_PORT, "peers": items}


# ── Trang tổng quan + API overview (chỉ khi truy cập không có subdomain) ──────

async def _probe(client: httpx.AsyncClient, pid: str, peer: dict[str, Any]) -> dict[str, Any]:
    out: dict[str, Any] = {"id": pid, "name": peer.get("name", pid),
                           "upstream": peer["url"], "ok": False}
    base = peer["url"].rstrip("/")
    headers = _peer_headers(peer)
    try:
        meta = (await client.get(f"{base}/api/meta", headers=headers)).json()
        status = (await client.get(f"{base}/api/status", headers=headers)).json()
        gitsync = status.get("gitsync") or {}
        apisix = status.get("apisix") or {}
        out.update({
            "ok": True,
            "dc_profile": meta.get("dc_profile"),
            "branch": meta.get("branch"),
            "auth_mode": meta.get("auth_mode"),
            "workspace_head": (status.get("workspace_head") or "")[:10] or None,
            "gitsync_last_done": gitsync.get("last_done"),
            "gitsync_warnings": len(gitsync.get("recent_warnings") or []),
            "apisix_last_reloaded": apisix.get("last_reloaded"),
        })
    except Exception as e:
        out["error"] = f"{type(e).__name__}: {e}"[:200]
    return out


async def _overview() -> dict[str, Any]:
    peers = load_peers()
    async with httpx.AsyncClient(timeout=PROBE_TIMEOUT) as client:
        results = await asyncio.gather(*(_probe(client, pid, p) for pid, p in peers.items()))
    return {"peers": list(results), "hub_port": HUB_PORT, "peers_file": str(PEERS_FILE)}


PAGE = """<!doctype html>
<html lang="vi">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>APISIX Dashboard Hub</title>
<style>
:root {
  --bg:#1e1e1e; --panel:#252526; --border:#3c3c3c; --text:#cccccc; --muted:#9d9d9d;
  --link:#3794ff; --ok:#89d185; --ok-bg:#1e3a2a; --bad:#f48771; --bad-bg:#5a1d1d;
  --accent:#0e639c;
}
@media (prefers-color-scheme: light) {
  :root { --bg:#ffffff; --panel:#f8f8f8; --border:#d4d4d4; --text:#3b3b3b; --muted:#6e6e6e;
    --link:#006ab1; --ok:#1e7b34; --ok-bg:#eaf6ec; --bad:#a1260d; --bad-bg:#fdecec; --accent:#007acc; }
}
* { box-sizing:border-box; }
body { margin:0; background:var(--bg); color:var(--text); font-size:14px;
  font-family:-apple-system,"Segoe UI",Roboto,Arial,sans-serif; }
header { padding:18px 24px; border-bottom:1px solid var(--border);
  display:flex; justify-content:space-between; align-items:center; }
h1 { margin:0; font-size:17px; } h1 small { color:var(--muted); font-weight:400; }
main { padding:20px 24px; display:grid; gap:14px;
  grid-template-columns:repeat(auto-fill,minmax(340px,1fr)); }
.card { background:var(--panel); border:1px solid var(--border); border-radius:10px; padding:14px 16px; }
.card h2 { margin:0 0 8px; font-size:15px; display:flex; align-items:center; gap:8px; flex-wrap:wrap; }
.badge { padding:1px 8px; border-radius:10px; font-size:11px; font-weight:600; }
.badge.ok { background:var(--ok-bg); color:var(--ok); }
.badge.bad { background:var(--bad-bg); color:var(--bad); }
.badge.dc { background:var(--accent); color:#fff; }
.row { display:flex; justify-content:space-between; gap:10px; padding:3px 0; font-size:13px; }
.row .k { color:var(--muted); } .mono { font-family:ui-monospace,Menlo,Consolas,monospace; font-size:.92em; }
a.open { display:inline-block; margin-top:10px; padding:7px 16px; background:var(--accent);
  color:#fff; border-radius:6px; text-decoration:none; font-size:13px; font-weight:600; }
.err { color:var(--bad); font-size:12px; word-break:break-word; margin-top:6px; }
.muted { color:var(--muted); } footer { padding:0 24px 20px; color:var(--muted); font-size:12px; line-height:1.6; }
</style>
</head>
<body>
<header>
  <h1>APISIX Dashboard Hub <small>— chọn VM để xem & thao tác trực tiếp</small></h1>
  <span class="muted" id="ts"></span>
</header>
<main id="cards"><p class="muted">Đang tải…</p></main>
<footer>Toàn bộ UI + thao tác CRUD của từng VM được proxy qua hub (subdomain
<span class="mono">&lt;id&gt;.localhost</span>) — không cần mở dashboard riêng.
Khai báo VM trong <span class="mono" id="pf">peers.yaml</span> · cần SSH tunnel đang mở tới VM
· tự refresh 10s.</footer>
<script>
async function load() {
  try {
    const r = await fetch("/api/overview");
    const d = await r.json();
    document.getElementById("pf").textContent = d.peers_file;
    document.getElementById("ts").textContent = "cập nhật " + new Date().toLocaleTimeString("vi-VN");
    const port = d.hub_port;
    const cards = d.peers.map(p => {
      const badge = p.ok ? '<span class="badge ok">online</span>'
                         : '<span class="badge bad">unreachable</span>';
      const dc = p.dc_profile ? ` <span class="badge dc">DC: ${p.dc_profile.toUpperCase()}</span>` : "";
      const peerUrl = `http://${p.id}.localhost:${port}/`;
      let rows = "";
      if (p.ok) {
        rows = `
        <div class="row"><span class="k">Workspace HEAD</span><span class="mono">${p.workspace_head ?? "—"}</span></div>
        <div class="row"><span class="k">gitsync DONE</span><span class="mono">${p.gitsync_last_done ? (p.gitsync_last_done.commit||"").slice(0,10)+" · "+(p.gitsync_last_done.ts||"") : "—"}</span></div>
        <div class="row"><span class="k">APISIX reloaded</span><span class="mono">${p.apisix_last_reloaded ? p.apisix_last_reloaded.ts : "—"}</span></div>
        <div class="row"><span class="k">gitsync WARN gần đây</span><span>${p.gitsync_warnings ?? 0}</span></div>
        <div class="row"><span class="k">Auth</span><span>${p.auth_mode ?? "—"} · branch <span class="mono">${p.branch ?? "?"}</span></span></div>`;
      } else {
        rows = `<div class="err">${p.error ?? "không kết nối được"}</div>
        <div class="muted" style="font-size:12px;margin-top:4px">Kiểm tra SSH tunnel tới VM này còn mở không.</div>`;
      }
      return `<div class="card"><h2>${p.name} ${badge}${dc}</h2>${rows}
        <a class="open" href="${peerUrl}">Xem & thao tác →</a>
        <div class="muted mono" style="font-size:12px;margin-top:6px">${peerUrl} ⇄ ${p.upstream}</div></div>`;
    });
    document.getElementById("cards").innerHTML = cards.join("") ||
      '<p class="muted">Chưa khai báo peer nào trong peers.yaml</p>';
  } catch (e) {
    document.getElementById("cards").innerHTML = '<p class="err">Hub lỗi: ' + e + '</p>';
  }
}
load(); setInterval(load, 10000);
</script>
</body>
</html>"""


# ── Catch-all: subdomain → reverse proxy; không subdomain → hub UI ────────────

@app.api_route("/{path:path}",
               methods=["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"])
async def gateway(request: Request, path: str) -> Response:
    pid, peer = _peer_from_host(request)

    # Endpoint dành riêng của hub — chặn TRƯỚC khi proxy (mọi host, kể cả subdomain):
    # frontend dashboard gọi để biết mình đang sau hub → render dropdown chọn VM.
    if path == "__hub/peers":
        return JSONResponse(_hub_peers_payload(pid if peer else None))

    if peer is None:
        # Hub UI (localhost:18000, không có subdomain peer)
        if path in ("", "index.html"):
            return HTMLResponse(PAGE)
        if path == "healthz":
            return JSONResponse({"ok": True})
        if path == "api/overview":
            return JSONResponse(await _overview())
        return JSONResponse(status_code=404, content={
            "detail": f"Không có route '{path}' trên hub. Truy cập peer qua subdomain: "
                      f"http://<id>.localhost:{HUB_PORT}/ (id trong peers.yaml)."})

    # Reverse proxy toàn bộ request tới dashboard của peer
    upstream = peer["url"].rstrip("/")
    url = f"{upstream}/{path}"
    headers = {k: v for k, v in request.headers.items() if k.lower() not in _SKIP_REQ_HEADERS}
    headers.update(_peer_headers(peer))
    body = await request.body()
    try:
        async with httpx.AsyncClient(timeout=PROXY_TIMEOUT) as client:
            resp = await client.request(request.method, url, params=request.query_params,
                                        headers=headers, content=body)
    except httpx.HTTPError as e:
        return JSONResponse(status_code=502, content={
            "detail": f"Hub không gọi được {upstream} ({type(e).__name__}) — "
                      "kiểm tra SSH tunnel tới VM này còn mở không."})
    resp_headers = {k: v for k, v in resp.headers.items()
                    if k.lower() not in _SKIP_RESP_HEADERS}
    return Response(content=resp.content, status_code=resp.status_code,
                    headers=resp_headers, media_type=resp.headers.get("content-type"))


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=HUB_PORT)
