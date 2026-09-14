import { useEffect, useState } from "react";
import { Link, useLocation, useParams, useSearchParams } from "react-router-dom";
import { api, ApiError } from "../api";
import Findings from "../components/Findings";
import HistoryPanel from "../components/HistoryPanel";
import MonacoEditor from "../components/MonacoEditor";
import ResultBanner from "../components/ResultBanner";
import SaveDialog from "../components/SaveDialog";
import type { EntityTypeMeta, FileResponse, Finding, SaveResult } from "../types";

export default function EntityEdit({ types }: { types: EntityTypeMeta[] }) {
  const { etype = "" } = useParams();
  const [searchParams] = useSearchParams();
  const location = useLocation();
  const meta = types.find((t) => t.name === etype);

  const path = searchParams.get("path") ?? "";
  const isNew = searchParams.get("new") === "1";

  const [original, setOriginal] = useState("");
  const [content, setContent] = useState("");
  const [baseBlob, setBaseBlob] = useState<string | null>(null);
  const [loaded, setLoaded] = useState(false);
  const [error, setError] = useState("");
  const [conflict, setConflict] = useState(false);
  const [findings, setFindings] = useState<Finding[] | null>(null);
  const [showSave, setShowSave] = useState(false);
  const [showHistory, setShowHistory] = useState(false);
  const [busy, setBusy] = useState(false);
  const [result, setResult] = useState<SaveResult | null>(null);
  const [saved, setSaved] = useState(false);

  useEffect(() => {
    if (isNew) {
      const tpl = (location.state as { content?: string } | null)?.content ?? "";
      setOriginal("");
      setContent(tpl);
      setBaseBlob(null);
      setLoaded(true);
      return;
    }
    api
      .get<FileResponse>(`/api/entities/${etype}/file?path=${encodeURIComponent(path)}`)
      .then((res) => {
        setOriginal(res.content);
        setContent(res.content);
        setBaseBlob(res.blob_sha);
        setLoaded(true);
      })
      .catch((e) => setError(String((e as Error).message ?? e)));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [etype, path, isNew]);

  const runValidate = async (): Promise<boolean> => {
    setError("");
    try {
      const res = await api.post<{ findings: Finding[]; has_errors: boolean }>(
        `/api/entities/${etype}/validate`,
        { path, content, is_new: isNew && !saved },
      );
      setFindings(res.findings);
      return !res.has_errors;
    } catch (e) {
      setError(String((e as Error).message ?? e));
      return false;
    }
  };

  const openSave = async () => {
    const ok = await runValidate();
    if (ok) setShowSave(true);
  };

  const doSave = async (note: string) => {
    setBusy(true);
    setError("");
    try {
      const res = await api.post<SaveResult>(`/api/entities/${etype}/save`, {
        path,
        content,
        note,
        base_blob: baseBlob,
        action: isNew && !saved ? "create" : "update",
      });
      setResult(res);
      setShowSave(false);
      setConflict(false);
      setSaved(true);
      setOriginal(content.endsWith("\n") ? content : content + "\n");
      if (res.findings) setFindings(res.findings);
      // refresh blob sha để tiếp tục sửa được ngay
      const fresh = await api.get<FileResponse>(
        `/api/entities/${etype}/file?path=${encodeURIComponent(path)}`,
      );
      setBaseBlob(fresh.blob_sha);
    } catch (e) {
      setShowSave(false);
      if (e instanceof ApiError && e.status === 409 && typeof e.detail === "object" && e.detail) {
        const d = e.detail as { message?: string; current_content?: string; current_blob?: string };
        setConflict(true);
        setError(d.message ?? "Conflict");
        if (d.current_content != null) setOriginal(d.current_content);
        if (d.current_blob != null) setBaseBlob(d.current_blob);
      } else if (e instanceof ApiError && e.status === 422 && typeof e.detail === "object" && e.detail) {
        setFindings((e.detail as { findings?: Finding[] }).findings ?? null);
      } else {
        setError(String((e as Error).message ?? e));
      }
    } finally {
      setBusy(false);
    }
  };

  if (!meta) return <div className="error-box">Entity type không hợp lệ: {etype}</div>;

  return (
    <div>
      <div className="page-header">
        <h2>
          <Link to={`/entities/${etype}`}>{meta.label}</Link> / <span className="mono">{path.split("/").pop()}</span>
          {isNew && !saved && <span className="badge on"> mới</span>}
        </h2>
        <div>
          <button className="btn" onClick={() => setShowHistory(true)} disabled={isNew && !saved}>
            Lịch sử
          </button>{" "}
          <button className="btn" onClick={runValidate}>Kiểm tra</button>{" "}
          <button className="btn primary" onClick={openSave} disabled={!loaded || content === original}>
            Lưu...
          </button>
        </div>
      </div>
      <p className="muted mono">{path}</p>

      {result && <ResultBanner result={result} onClose={() => setResult(null)} />}
      {conflict && (
        <div className="error-box">
          ⚠️ {error} — Panel bên trái của diff lúc Lưu sẽ là bản MỚI trên main; nội dung
          bạn đang sửa vẫn giữ nguyên trong editor.
        </div>
      )}
      {!conflict && error && <div className="error-box">{error}</div>}

      {loaded ? (
        <MonacoEditor value={content} onChange={setContent} height="65vh" />
      ) : (
        <p className="muted">Đang tải (git pull mới nhất trước khi mở form)...</p>
      )}

      {findings && (
        <div className="findings-wrap">
          <h4>Kết quả kiểm tra</h4>
          <Findings findings={findings} />
        </div>
      )}

      {showSave && (
        <SaveDialog
          title={`Diff — ${path.split("/").pop()}`}
          original={original}
          modified={content}
          busy={busy}
          onConfirm={doSave}
          onCancel={() => setShowSave(false)}
        />
      )}

      {showHistory && <HistoryPanel path={path} onClose={() => setShowHistory(false)} />}
    </div>
  );
}
