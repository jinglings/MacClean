// node:sqlite still prints an ExperimentalWarning on Node 22. Swallow exactly that one;
// every other warning still reaches the default handler.
// Must be imported before anything that loads node:sqlite (main.js / cli.js use a dynamic import after it).
const originalEmitWarning = process.emitWarning;
process.emitWarning = function (warning, ...args) {
  const type = typeof args[0] === 'string' ? args[0] : args[0]?.type;
  const message = typeof warning === 'string' ? warning : warning?.message;
  const name = type || warning?.name;
  if (name === 'ExperimentalWarning' && /SQLite/i.test(String(message))) return;
  return originalEmitWarning.call(this, warning, ...args);
};
