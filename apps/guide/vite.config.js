export default {
  base: process.env.CI ? '/capacitor/' : '/',
  server: { port: 5174 },
  build: { outDir: '../../dist-guide' },
}
