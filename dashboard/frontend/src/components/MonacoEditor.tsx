import { useEffect, useRef } from "react";
import monaco from "../monaco";
import { monacoTheme } from "../theme";

interface Props {
  value: string;
  language?: string;
  readOnly?: boolean;
  height?: string;
  onChange?: (value: string) => void;
}

export default function MonacoEditor({
  value,
  language = "yaml",
  readOnly = false,
  height = "60vh",
  onChange,
}: Props) {
  const containerRef = useRef<HTMLDivElement>(null);
  const editorRef = useRef<monaco.editor.IStandaloneCodeEditor | null>(null);
  const onChangeRef = useRef(onChange);
  onChangeRef.current = onChange;

  useEffect(() => {
    if (!containerRef.current) return;
    const editor = monaco.editor.create(containerRef.current, {
      value,
      language,
      theme: monacoTheme(),
      readOnly,
      minimap: { enabled: false },
      scrollBeyondLastLine: false,
      fontSize: 13,
      automaticLayout: true,
      wordWrap: "off",
      renderWhitespace: "trailing",
    });
    editor.onDidChangeModelContent(() => {
      onChangeRef.current?.(editor.getValue());
    });
    editorRef.current = editor;
    return () => editor.dispose();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [language, readOnly]);

  // Đồng bộ value từ ngoài vào (vd reload sau conflict) — không phá undo khi giống nhau
  useEffect(() => {
    const editor = editorRef.current;
    if (editor && editor.getValue() !== value) {
      editor.setValue(value);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [value]);

  return <div ref={containerRef} className="monaco-box" style={{ height }} />;
}
