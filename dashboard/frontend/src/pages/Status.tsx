import { useEffect, useState } from "react";
import { api } from "../api";
import type { StatusResponse } from "../types";

export default function Status() {
  const [status, setStatus] = useState<StatusResponse | null>(null);
  const [logText, setLogText] = useState("");
  const [error, setError] = useState("");

  const load = () => {
    api.get<StatusResponse>("/api/status").then(setStatus).catch((e) => setError(String(e.message ?? e)));
    api.getText("/api/status/gitsync-log?lines=200").then(setLogText).catch(() => setLogText(""));
  };

  useEffect(() => {
    load();
    const t = setInterval(load, 10_000);
    return () => clearInterval(t);
  }, []);

  return (
    <div>
      <div className="page-header">
        <h2>Status — pipeline gitsync → merge → hot-reload</h2>
        <button className="btn" onClick={load}>↻ Refresh</button>
      </div>
      {error && <div className="error-box">{error}</div>}
      {status && (
        <>
          <div className="cards">
            <div className="card">
              <h4>Workspace dashboard</h4>
              <div className="mono">{status.workspace_head?.slice(0, 10) ?? "chưa sẵn sàng"}</div>
              <div className="muted">HEAD của clone riêng (dashboard-workspace/)</div>
            </div>
            <div className="card">
              <h4>gitsync — lần pull gần nhất</h4>
              {status.gitsync.available ? (
                <>
                  {status.gitsync.last_start && (
                    <div>
                      START: <span className="mono">{status.gitsync.last_start.commit.slice(0, 10)}</span>{" "}
                      <span className="muted">{status.gitsync.last_start.ts}</span>
                      <div className="muted">{status.gitsync.last_start.msg}</div>
                    </div>
                  )}
                  {status.gitsync.last_done ? (
                    <div>
                      DONE: <span className="mono">{status.gitsync.last_done.commit.slice(0, 10)}</span>{" "}
                      <span className="muted">{status.gitsync.last_done.ts}</span>
                    </div>
                  ) : (
                    <div className="muted">Chưa thấy DONE trong tail log</div>
                  )}
                </>
              ) : (
                <div className="muted">Không đọc được logs/gitsync/gitsync.log (mount?)</div>
              )}
            </div>
            <div className="card">
              <h4>APISIX hot-reload</h4>
              {status.apisix.available ? (
                status.apisix.last_reloaded ? (
                  <>
                    <div>
                      ✅ reloaded lúc <span className="mono">{status.apisix.last_reloaded.ts}</span>
                    </div>
                    <div className="muted mono">{status.apisix.last_reloaded.file}</div>
                  </>
                ) : (
                  <div className="muted">Chưa thấy dòng "reloaded" trong tail error.log</div>
                )
              ) : (
                <div className="muted">Không đọc được logs/apisix/error.log (mount?)</div>
              )}
            </div>
          </div>

          {status.gitsync.recent_warnings.length > 0 && (
            <div className="findings-wrap">
              <h4>⚠️ WARN/ERROR gần nhất trong gitsync log</h4>
              <pre className="log-view small">{status.gitsync.recent_warnings.join("\n")}</pre>
            </div>
          )}

          <p className="muted">{status.hint}</p>
        </>
      )}

      <h4>gitsync.log (tail 200 dòng — tự refresh 10s)</h4>
      <pre className="log-view">{logText || "(trống)"}</pre>
    </div>
  );
}
