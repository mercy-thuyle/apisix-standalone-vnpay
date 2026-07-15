// Monaco bundle offline — KHÔNG load từ CDN (VM nội bộ không có internet).
import * as monaco from "monaco-editor";
import EditorWorker from "monaco-editor/esm/vs/editor/editor.worker?worker";

self.MonacoEnvironment = {
  // Chỉ cần base worker: dashboard dùng YAML/Lua (syntax highlight basic-languages,
  // không cần language service worker riêng).
  getWorker: () => new EditorWorker(),
};

monaco.editor.defineTheme("dashboard-dark", {
  base: "vs-dark",
  inherit: true,
  rules: [{ token: "comment", foreground: "6a9955", fontStyle: "italic" }],
  colors: { "editor.background": "#111827" },
});

export default monaco;
