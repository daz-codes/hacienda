import {defineConfig} from "vitest/config";

export default defineConfig({
  test: {
    environment: "jsdom",
    include: ["test/client/**/*.test.js", "packages/*/test/**/*.test.js"],
    restoreMocks: true
  }
});
