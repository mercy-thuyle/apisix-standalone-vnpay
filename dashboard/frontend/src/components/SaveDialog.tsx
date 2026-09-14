import { useState } from "react";
import MonacoDiff from "./MonacoDiff";

interface Props {
  title: string;
  original: string;
  modified: string;
  busy: boolean;
  onConfirm: (note: string) => void;
  onCancel: () => void;
}

/**
 * Dialog xác nhận trước khi commit — hiển thị diff old/new (yêu cầu build-prompt mục 2:
 * "Mọi write phải qua bước diff + xác nhận, không auto-save im lặng").
 * Phase 1: push thẳng main. Phase 3 sẽ thêm lựa chọn "Tạo Merge Request" tại đây.
 */
export default function SaveDialog({ title, original, modified, busy, onConfirm, onCancel }: Props) {
  const [note, setNote] = useState("");
  return (
    <div className="modal-backdrop">
      <div className="modal">
        <h3>{title}</h3>
        <p className="muted">
          Xem kỹ diff bên dưới. Xác nhận sẽ <b>commit + push thẳng lên main</b> — gitsync
          pull (~30s) rồi APISIX hot-reload.
        </p>
        <MonacoDiff original={original} modified={modified} />
        <div className="form-row">
          <label>Ghi chú commit (optional):</label>
          <input
            value={note}
            onChange={(e) => setNote(e.target.value)}
            placeholder="vd: tăng timeout read"
            maxLength={200}
          />
        </div>
        <div className="modal-actions">
          <button className="btn" onClick={onCancel} disabled={busy}>
            Huỷ
          </button>
          <button className="btn primary" onClick={() => onConfirm(note)} disabled={busy}>
            {busy ? "Đang push..." : "Xác nhận — Push lên main"}
          </button>
        </div>
      </div>
    </div>
  );
}
