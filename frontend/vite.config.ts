import { defineConfig } from 'vite';
import preact from '@preact/preset-vite';

// The bridge server (server.mjs) exposes the RPC backend over a WebSocket at
// /rpc. During `vite dev` we proxy that path to the bridge so the workbench can
// talk to the real `pi-zig --mode rpc` process from the dev origin.
const BRIDGE_PORT = process.env.BRIDGE_PORT ?? '8787';

export default defineConfig({
  plugins: [preact()],
  server: {
    host: '127.0.0.1',
    proxy: {
      '/rpc': {
        target: `ws://127.0.0.1:${BRIDGE_PORT}`,
        ws: true,
        changeOrigin: true,
      },
    },
  },
  build: {
    outDir: 'dist',
    emptyOutDir: true,
  },
});
