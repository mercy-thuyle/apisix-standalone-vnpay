// Light/dark theme — lưu localStorage, mặc định dark (tông VS Code Dark+).
import monaco from "./monaco";

export type Theme = "dark" | "light";
const STORAGE_KEY = "dashboard-theme";

export function getTheme(): Theme {
  const saved = localStorage.getItem(STORAGE_KEY);
  return saved === "light" ? "light" : "dark";
}

export function applyTheme(theme: Theme): void {
  document.documentElement.dataset.theme = theme;
  localStorage.setItem(STORAGE_KEY, theme);
  // setTheme là global — đổi theme mọi editor/diff đang mở cùng lúc
  monaco.editor.setTheme(theme === "dark" ? "dashboard-dark" : "dashboard-light");
}

export function monacoTheme(): string {
  return getTheme() === "dark" ? "dashboard-dark" : "dashboard-light";
}
