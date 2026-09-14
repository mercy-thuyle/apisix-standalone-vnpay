import { useEffect, useState } from "react";
import { NavLink, Navigate, Route, Routes } from "react-router-dom";
import { api } from "./api";
import EntityEdit from "./pages/EntityEdit";
import EntityList from "./pages/EntityList";
import Status from "./pages/Status";
import { applyTheme, getTheme, type Theme } from "./theme";
import type { HubInfo, Meta } from "./types";

// Thứ tự áp dụng/ghi đè plugin theo APISIX — khớp PLUGIN_CHAIN phía backend
// https://apisix.apache.org/docs/apisix/terminology/plugin/
const PLUGIN_CHAIN = ["upstreams", "services", "plugin_configs", "routes",
  "consumer_groups", "consumers"];

export default function App() {
  const [meta, setMeta] = useState<Meta | null>(null);
  const [error, setError] = useState("");
  const [theme, setTheme] = useState<Theme>(getTheme());
  const [hub, setHub] = useState<HubInfo | null>(null);

  // Đang chạy sau dashboard-hub? Hub chặn /__hub/peers trước khi proxy và trả peer list;
  // truy cập thẳng trên VM thì backend trả 404 → giữ badge DC tĩnh.
  useEffect(() => {
    fetch("/__hub/peers")
      .then((r) => (r.ok ? r.json() : null))
      .then((d: HubInfo | null) => {
        if (d && d.peers?.length) setHub(d);
      })
      .catch(() => {});
  }, []);

  const switchPeer = (id: string) => {
    if (!id || id === hub?.current) return;
    const { protocol, port, pathname } = window.location;
    // Giữ nguyên trang đang xem (vd /entities/upstreams) khi đổi VM
    window.location.href = `${protocol}//${id}.localhost${port ? `:${port}` : ""}${pathname}`;
  };

  const toggleTheme = () => {
    const next: Theme = theme === "dark" ? "light" : "dark";
    setTheme(next);
    applyTheme(next);
  };

  useEffect(() => {
    api.get<Meta>("/api/meta").then(setMeta).catch((e) => setError(String(e.message ?? e)));
  }, []);

  if (error) return <div className="error-box" style={{ margin: 24 }}>Không kết nối được backend: {error}</div>;
  if (!meta) return <div className="muted" style={{ margin: 24 }}>Đang tải...</div>;

  return (
    <div className="layout">
      <aside className="sidebar">
        <div className="brand">
          <div className="brand-title">APISIX Standalone</div>
          <div className="brand-sub">Config Dashboard</div>
          {hub ? (
            <select
              className="dc-select"
              value={hub.current ?? ""}
              onChange={(e) => switchPeer(e.target.value)}
              title="Chọn VM APISIX (qua dashboard-hub)"
            >
              {hub.current === null && <option value="">— chọn VM —</option>}
              {hub.peers.map((p) => (
                <option key={p.id} value={p.id}>{p.label}</option>
              ))}
            </select>
          ) : (
            meta.dc_profile && <span className="badge dc">DC: {meta.dc_profile.toUpperCase()}</span>
          )}
        </div>
        <nav>
          <div className="nav-section">Chuỗi override plugin</div>
          <div className="nav-hint">
            càng xuống dưới càng ưu tiên ghi đè (Consumer cao nhất)
          </div>
          {meta.entity_types
            .filter((t) => PLUGIN_CHAIN.includes(t.name))
            .map((t) => (
              <NavLink key={t.name} to={`/entities/${t.name}`} className="nav-link">
                {t.label}
              </NavLink>
            ))}
          <div className="nav-section">Ngoài chuỗi override</div>
          {meta.entity_types
            .filter((t) => !PLUGIN_CHAIN.includes(t.name))
            .map((t) => (
              <NavLink key={t.name} to={`/entities/${t.name}`} className="nav-link">
                {t.label}
              </NavLink>
            ))}
          <div className="nav-section">Hệ thống</div>
          <NavLink to="/status" className="nav-link">📡 Status / Hot-reload</NavLink>
        </nav>
        <div className="sidebar-footer">
          <button className="btn tiny" onClick={toggleTheme} style={{ justifySelf: "start" }}>
            {theme === "dark" ? "☀️ Light mode" : "🌙 Dark mode"}
          </button>
          <div className="muted">
            Actor: <b>{meta.actor}</b> ({meta.auth_mode})
          </div>
          <div className="muted">
            Branch: <span className="mono">{meta.branch}</span>
          </div>
          <a href={meta.gitlab_web_url} target="_blank" rel="noreferrer">GitLab ↗</a>
        </div>
      </aside>
      <main className="content">
        <Routes>
          <Route path="/" element={<Navigate to="/entities/routes" replace />} />
          <Route path="/entities/:etype" element={<EntityList types={meta.entity_types} />} />
          <Route path="/entities/:etype/edit" element={<EntityEdit types={meta.entity_types} />} />
          <Route path="/status" element={<Status />} />
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </main>
    </div>
  );
}
