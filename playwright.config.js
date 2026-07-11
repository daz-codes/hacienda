import {defineConfig} from "@playwright/test";

export default defineConfig({
  testDir: "test/browser",
  use: {baseURL: "http://127.0.0.1:5161"},
  webServer: {
    command: "node test/browser/server.mjs",
    port: 5161,
    reuseExistingServer: false
  }
});
