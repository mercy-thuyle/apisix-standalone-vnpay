import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Monaco bundle offline (KHÔNG CDN) — dashboard chạy trong mạng nội bộ.
export default defineConfig({
  plugins: [react()],
  build: {
    chunkSizeWarningLimit: 4000, // monaco-editor lớn — chấp nhận, bundle offline
    rollupOptions: {
      output: {
        manualChunks: { monaco: ["monaco-editor"] },
      },
    },
  },
  server: {
    port: 5173,
    proxy: {
      "/api": "http://127.0.0.1:18080",
      "/healthz": "http://127.0.0.1:18080",
    },
  },
});
