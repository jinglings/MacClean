import './suppress-warnings.js';

const { loadConfig } = await import('./config.js');
const { createApp } = await import('./app.js');

const config = loadConfig(process.env, { accessLog: process.env.ACCESS_LOG === '1' });
const app = createApp(config);
const address = await app.start();
console.log(`[macclean] listening on http://${address.address}:${address.port} (data: ${config.dataDir}${config.isDev ? ', development' : ''})`);

let stopping = false;
for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, async () => {
    if (stopping) return;
    stopping = true;
    console.log(`[macclean] ${signal} received, shutting down`);
    const force = setTimeout(() => process.exit(1), 10_000);
    force.unref();
    await app.close();
    process.exit(0);
  });
}
