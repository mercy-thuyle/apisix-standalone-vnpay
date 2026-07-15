import { Link } from "react-router-dom";
import type { SaveResult } from "../types";

export default function ResultBanner({ result, onClose }: { result: SaveResult; onClose: () => void }) {
  return (
    <div className="result-banner">
      <div>
        ✅ Đã commit{" "}
        <a href={result.commit_url} target="_blank" rel="noreferrer" className="mono">
          {result.commit_short}
        </a>{" "}
        — <span className="mono">{result.message}</span>
      </div>
      <div className="muted">
        ⏳ {result.next} <Link to="/status">Mở trang Status →</Link>
      </div>
      <button className="btn tiny" onClick={onClose}>✕</button>
    </div>
  );
}
