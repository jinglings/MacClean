// Applied before first paint (non-module, synchronous) so dark mode doesn't flash.
(function () {
  var pref = 'system';
  try { pref = localStorage.getItem('mc-admin-theme') || 'system'; } catch (e) { /* storage blocked */ }
  var dark = pref === 'dark' || (pref === 'system' && window.matchMedia('(prefers-color-scheme: dark)').matches);
  document.documentElement.setAttribute('data-theme', dark ? 'dark' : 'light');
})();
