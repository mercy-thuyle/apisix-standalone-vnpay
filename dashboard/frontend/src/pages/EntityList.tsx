import { useCallback, useEffect, useState } from "react";
import { Link, useNavigate, useParams } from "react-router-dom";
import { api, ApiError } from "../api";
import Findings from "../components/Findings";
import HistoryPanel from "../components/HistoryPanel";
import MonacoDiff from "../components/MonacoDiff";
import ResultBanner from "../components/ResultBanner";
import type { EntityListResponse, EntityTypeMeta, Finding, SaveResult } from "../types";

interface ToggleState {
  path: string;
  disable: boolean;
  old_content: string;
  new_content: string;
  blob_sha: string | null;
}

interface DeleteState {
  path: string;
  content: string;
  blob_sha: string | null;
}

export default function EntityList({ types }: { types: EntityTypeMeta[] }) {
  const { etype = "" } = useParams();
  const meta = types.find((t) => t.name === etype);
  const navigate = useNavigate();

  const [data, setData] = useState<EntityListResponse | null>(null);
  const [error, setError] = useState("");
  const [findings, setFindings] = useState<Finding[] | null>(null);
  const [result, setResult] = useState<SaveResult | null>(null);
  const [historyPath, setHistoryPath] = useState<string | null>(null);
  const [showCreate, setShowCreate] = useState(false);
  const [toggle, setToggle] = useState<ToggleState | null>(null);
  const [del, setDel] = useState<DeleteState | null>(null);
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);

  const load = useCallback(() => {
    setData(null);
    setError("");
    api
      .get<EntityListResponse>(`/api/entities/${etype}`)
      .then(setData)
      .catch((e) => setError(String(e.message ?? e)));
  }, [etype]);

  useEffect(() => {
    load();
    setResult(null);
    setFindings(null);
    setHistoryPath(null);
  }, [load]);

  const handleApiError = (e: unknown) => {
    if (e instanceof ApiError && typeof e.detail === "object" && e.detail) {
      const d = e.detail as Record<string, unknown>;
      if (d.findings) {
        setFindings(d.findings as Finding[]);
        return;
      }
      if (d.message) {
        setError(String(d.message));
        return;
      }
    }
    setError(String((e as Error).message ?? e));
  };

  const openToggle = async (path: string, disable: boolean) => {
    setFindings(null);
    setError("");
    try {
      const res = await api.post<ToggleState>(`/api/entities/${etype}/toggle`, {
        path,
        disable,
        preview: true,
      });
      setToggle({ ...res, path, disable });
      setNote("");
    } catch (e) {
      handleApiError(e);
    }
  };

  const confirmToggle = async () => {
    if (!toggle) return;
    setBusy(true);
    try {
      const res = await api.post<SaveResult>(`/api/entities/${etype}/toggle`, {
        path: toggle.path,
        disable: toggle.disable,
        note,
        base_blob: toggle.blob_sha,
      });
      setResult(res);
      setToggle(null);
      load();
    } catch (e) {
      handleApiError(e);
      setToggle(null);
    } finally {
      setBusy(false);
    }
  };

  const openDelete = async (path: string) => {
    setFindings(null);
    setError("");
    try {
      const res = await api.get<{ content: string; blob_sha: string | null }>(
        `/api/entities/${etype}/file?path=${encodeURIComponent(path)}`,
      );
      setDel({ path, content: res.content, blob_sha: res.blob_sha });
      setNote("");
    } catch (e) {
      handleApiError(e);
    }
  };

  const confirmDelete = async () => {
    if (!del) return;
    setBusy(true);
    try {
      const res = await api.post<SaveResult>(`/api/entities/${etype}/delete`, {
        path: del.path,
        note,
        base_blob: del.blob_sha,
      });
      setResult(res);
      setDel(null);
      load();
    } catch (e) {
      handleApiError(e);
      setDel(null);
    } finally {
      setBusy(false);
    }
  };

  if (!meta) return <div className="error-box">Entity type không hợp lệ: {etype}</div>;

  return (
    <div>
      <div className="page-header">
        <h2>
          {meta.label} {meta.core && <span className="badge core">core</span>}
        </h2>
        <button className="btn primary" onClick={() => setShowCreate(true)}>
          ➕ Tạo mới
        </button>
      </div>

      {result && <ResultBanner result={result} onClose={() => setResult(null)} />}
      {error && <div className="error-box">{error}</div>}
      {findings && <Findings findings={findings} />}
      {!data && !error && <p className="muted">Đang tải (git pull)...</p>}

      {data && (
        <table className="entity-table">
          <thead>
            <tr>
              <th>File</th>
              {meta.grouped && <th>Workload</th>}
              <th>{meta.id_field === "username" ? "Usernames" : "IDs"}</th>
              <th>Trạng thái</th>
              <th>Thao tác</th>
            </tr>
          </thead>
          <tbody>
            {data.files.map((f) => (
              <tr key={f.path} className={f.disabled ? "disabled-row" : ""}>
                <td className="mono">{f.file}</td>
                {meta.grouped && <td>{f.group ?? <span className="muted">—</span>}</td>}
                <td>
                  {f.parse_error ? (
                    <span className="badge error" title={f.parse_error}>parse error</span>
                  ) : (
                    f.items.map((it) => (
                      <div key={String(it.id)}>
                        <span className="mono">{it.id}</span>
                        {it.name && <span className="muted"> — {it.name}</span>}
                      </div>
                    ))
                  )}
                </td>
                <td>
                  {f.disabled ? (
                    <span className="badge off">disabled</span>
                  ) : (
                    <span className="badge on">enabled</span>
                  )}
                </td>
                <td className="actions">
                  <Link className="btn tiny" to={`/entities/${etype}/edit?path=${encodeURIComponent(f.path)}`}>
                    Sửa
                  </Link>
                  <button className="btn tiny" onClick={() => openToggle(f.path, !f.disabled)}>
                    {f.disabled ? "Enable" : "Disable"}
                  </button>
                  <button className="btn tiny danger" onClick={() => openDelete(f.path)}>
                    Xoá
                  </button>
                  <button className="btn tiny" onClick={() => setHistoryPath(f.path)}>
                    Lịch sử
                  </button>
                </td>
              </tr>
            ))}
            {data.files.length === 0 && (
              <tr>
                <td colSpan={5} className="muted">Chưa có file nào.</td>
              </tr>
            )}
          </tbody>
        </table>
      )}

      {showCreate && (
        <CreateDialog
          meta={meta}
          groups={data?.groups ?? []}
          onCancel={() => setShowCreate(false)}
          onCreated={(path, content) =>
            navigate(`/entities/${etype}/edit?path=${encodeURIComponent(path)}&new=1`, {
              state: { content },
            })
          }
        />
      )}

      {toggle && (
        <div className="modal-backdrop">
          <div className="modal">
            <h3>{toggle.disable ? "Disable (comment toàn file)" : "Enable (bỏ comment)"} — {toggle.path.split("/").pop()}</h3>
            <p className="muted">
              {toggle.disable
                ? "File bị comment toàn bộ — merge-fragments.sh sẽ SKIP, entity biến mất khỏi APISIX nhưng file + lịch sử vẫn còn trong repo."
                : "Bỏ comment toàn bộ — entity sẽ hoạt động trở lại sau khi gitsync pull + hot-reload."}
            </p>
            <MonacoDiff original={toggle.old_content} modified={toggle.new_content} />
            <div className="form-row">
              <label>Ghi chú commit (optional):</label>
              <input value={note} onChange={(e) => setNote(e.target.value)} maxLength={200} />
            </div>
            <div className="modal-actions">
              <button className="btn" onClick={() => setToggle(null)} disabled={busy}>Huỷ</button>
              <button className="btn primary" onClick={confirmToggle} disabled={busy}>
                {busy ? "Đang push..." : "Xác nhận — Push lên main"}
              </button>
            </div>
          </div>
        </div>
      )}

      {del && (
        <div className="modal-backdrop">
          <div className="modal">
            <h3>⚠️ Xoá file — {del.path.split("/").pop()}</h3>
            <p className="muted">
              Cân nhắc dùng <b>Disable</b> thay vì xoá để giữ lịch sử/template. Xoá vẫn
              revert được qua Git nhưng file biến mất khỏi repo.
            </p>
            <MonacoDiff original={del.content} modified={""} />
            <div className="form-row">
              <label>Ghi chú commit (optional):</label>
              <input value={note} onChange={(e) => setNote(e.target.value)} maxLength={200} />
            </div>
            <div className="modal-actions">
              <button className="btn" onClick={() => setDel(null)} disabled={busy}>Huỷ</button>
              <button className="btn danger" onClick={confirmDelete} disabled={busy}>
                {busy ? "Đang push..." : "Xoá — Push lên main"}
              </button>
            </div>
          </div>
        </div>
      )}

      {historyPath && <HistoryPanel path={historyPath} onClose={() => setHistoryPath(null)} />}
    </div>
  );
}

function CreateDialog({
  meta,
  groups,
  onCancel,
  onCreated,
}: {
  meta: EntityTypeMeta;
  groups: string[];
  onCancel: () => void;
  onCreated: (path: string, content: string) => void;
}) {
  const [entityId, setEntityId] = useState("");
  const [group, setGroup] = useState("");
  const [domain, setDomain] = useState("");
  const [scheme, setScheme] = useState("https");
  const [port, setPort] = useState(443);
  const [error, setError] = useState("");

  const submit = async () => {
    setError("");
    const params = new URLSearchParams();
    if (meta.name === "routes") {
      params.set("group", group);
      params.set("domain", domain);
      params.set("scheme", scheme);
      params.set("port", String(port));
    } else {
      params.set("entity_id", entityId);
    }
    try {
      const res = await api.get<{ path: string; content: string }>(
        `/api/entities/${meta.name}/template?${params.toString()}`,
      );
      onCreated(res.path, res.content);
    } catch (e) {
      const err = e as ApiError;
      setError(typeof err.detail === "string" ? err.detail : String(err.message));
    }
  };

  return (
    <div className="modal-backdrop">
      <div className="modal narrow">
        <h3>Tạo {meta.label} mới</h3>
        {meta.name === "routes" ? (
          <>
            <div className="form-row">
              <label>Workload (subfolder):</label>
              <input
                list="workload-list"
                value={group}
                onChange={(e) => setGroup(e.target.value)}
                placeholder="vd: hyperstore-cloudian-hcm"
              />
              <datalist id="workload-list">
                {groups.map((g) => <option key={g} value={g} />)}
              </datalist>
            </div>
            <div className="form-row">
              <label>Domain:</label>
              <input value={domain} onChange={(e) => setDomain(e.target.value)} placeholder="vd: s3-hcm.sds.infiniband.vn" />
            </div>
            <div className="form-row">
              <label>Scheme:</label>
              <select value={scheme} onChange={(e) => setScheme(e.target.value)}>
                <option value="https">https</option>
                <option value="http">http</option>
              </select>
            </div>
            <div className="form-row">
              <label>Port:</label>
              <input type="number" value={port} onChange={(e) => setPort(Number(e.target.value))} />
            </div>
            <p className="muted">
              File: <span className="mono">route-{domain || "<domain>"}-{scheme}-{port}.yaml</span>
              {" "}(convention cố định — không đổi sang workload-based)
            </p>
          </>
        ) : (
          <div className="form-row">
            <label>{meta.id_field === "username" ? "Username" : "ID"}:</label>
            <input
              value={entityId}
              onChange={(e) => setEntityId(e.target.value)}
              placeholder={meta.name === "consumers" ? "vd: bucket-ten-bucket" : `vd: ${meta.name.replace(/s$/, "")}-...`}
            />
          </div>
        )}
        {error && <div className="error-box">{error}</div>}
        <div className="modal-actions">
          <button className="btn" onClick={onCancel}>Huỷ</button>
          <button className="btn primary" onClick={submit}>Tạo template →</button>
        </div>
      </div>
    </div>
  );
}
