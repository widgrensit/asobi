import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// The build emits hashed chunks and a manifest. It does NOT emit a document:
// asobi_console_shell renders the shell, because the two values the shell has
// to carry - the CSP nonce and the ops API base - are only known per response.
//
// Three settings are load-bearing for the CSP and are not style choices:
//
//   codeSplitting: false  one chunk. script-src is a bare nonce with no host
//                         source, and a nonce does not propagate to a module's
//                         static imports, so a second chunk would be refused.
//   modulePreload         Vite's preload helper is an inline <script>. Off.
//   cssCodeSplit          one stylesheet, linked by the shell from the
//                         manifest rather than injected by script.
export default defineConfig({
  base: '/console/',
  plugins: [react()],
  build: {
    outDir: '../priv/console',
    emptyOutDir: true,
    manifest: 'manifest.json',
    modulePreload: false,
    cssCodeSplit: false,
    assetsInlineLimit: 8192,
    target: 'es2022',
    sourcemap: false,
    rollupOptions: {
      input: 'src/main.jsx',
      output: {
        codeSplitting: false,
        entryFileNames: 'assets/[name]-[hash].js',
        chunkFileNames: 'assets/[name]-[hash].js',
        assetFileNames: 'assets/[name]-[hash][extname]',
      },
    },
  },
});
