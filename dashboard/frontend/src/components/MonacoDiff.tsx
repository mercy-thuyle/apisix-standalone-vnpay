import { useEffect, useRef } from "react";
import monaco from "../monaco";
import { monacoTheme } from "../theme";

interface Props {
  original: string;
  modified: string;
  language?: string;
  height?: string;
}

export default function MonacoDiff({
  original,
  modified,
  language = "yaml",
  height = "55vh",
}: Props) {
  const containerRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!containerRef.current) return;
    const editor = monaco.editor.createDiffEditor(containerRef.current, {
      theme: monacoTheme(),
      readOnly: true,
      renderSideBySide: true,
      minimap: { enabled: false },
      scrollBeyondLastLine: false,
      fontSize: 12,
      automaticLayout: true,
    });
    const o = monaco.editor.createModel(original, language);
    const m = monaco.editor.createModel(modified, language);
    editor.setModel({ original: o, modified: m });
    return () => {
      editor.dispose();
      o.dispose();
      m.dispose();
    };
  }, [original, modified, language]);

  return <div ref={containerRef} className="monaco-box" style={{ height }} />;
}
