// @ts-check
const { defineConfig } = require('@playwright/test');

module.exports = defineConfig({
  testDir: './',
  timeout: 30000,
  webServer: {
    command: 'node server.js',
    port: 3456,
    reuseExistingServer: true,
  },
  use: {
    baseURL: 'http://localhost:3456',
    channel: 'chrome',
    headless: true,
  },
});
