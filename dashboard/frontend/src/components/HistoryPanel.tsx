import { useEffect, useState } from "react";
import { api } from "../api";
import type { CommitInfo } from "../types";

interface HistoryResponse {
  commits: CommitInfo[];
  file_history_url: string;
}

export default function HistoryPanel({ path, onClose }: { path: string; onClose: () => void }) {
  const [data, setData] = useState<HistoryResponse | null>(null);
  const [error, setError] = useState("");

  useEffect(() => {
    api
      .get<HistoryResponse>(`/api/git/history?path=${encodeURIComponent(path)}&limit=30`)
      .then(setData)
      .catch((e) => setError(String(e.message ?? e)));
  }, [path]);

  return (
    <div className="side-panel">
      <div className="side-panel-header">
        <h3>Lịch sử — {path.split("/").pop()}</h3>
        <button className="btn" onClick={onClose}>✕</button>
      </div>
      {error && <div className="error-box">{error}</div>}
      {!data && !error && <p className="muted">Đang tải...</p>}
      {data && (
        <>
          <p>
            <a href={data.file_history_url} target="_blank" rel="noreferrer">
              Xem toàn bộ trên GitLab ↗
            </a>
          </p>
          <ul className="commit-list">
            {data.commits.map((c) => (
              <li key={c.sha}>
                <div>
                  <a href={c.web_url} target="_blank" rel="noreferrer" className="mono">
                    {c.short}
                  </a>{" "}
                  <span className="muted">{new Date(c.date).toLocaleString("vi-VN")}</span>
                </div>
                <div>{c.subject}</div>
                <div className="muted">{c.author}</div>
                <button
                  className="btn tiny"
                  disabled
                  title="Phase sau — hiện tại revert thủ công qua trang commit GitLab (nút Revert/Options trên GitLab)"
                >
                  Revert commit này
                </button>
              </li>
            ))}
          </ul>
        </>
      )}
    </div>
  );
}
