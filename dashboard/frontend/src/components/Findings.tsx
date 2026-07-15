import type { Finding } from "../types";

const ICON: Record<string, string> = { error: "⛔", warning: "⚠️", info: "ℹ️" };

export default function Findings({ findings }: { findings: Finding[] }) {
  if (!findings.length) return <div className="findings ok">✅ Không có vấn đề nào.</div>;
  return (
    <ul className="findings">
      {findings.map((f, i) => (
        <li key={i} className={`finding ${f.level}`}>
          <span>{ICON[f.level] ?? "•"}</span>
          <span className="rule">[{f.rule}{f.line ? `:${f.line}` : ""}]</span>
          <span>{f.message}</span>
        </li>
      ))}
    </ul>
  );
}
