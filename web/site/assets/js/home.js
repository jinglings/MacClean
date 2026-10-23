import { boot, getConfig, planName, planFeatures, money, escapeHTML } from './common.js?v=20261023.1';
import { t, onLangChange } from './i18n.js?v=20261023.1';

boot();

// Manual tabs: no scroll hijacking, timed slides or decorative animation.
const tabs = [...document.querySelectorAll('[role="tab"]')];
function selectTab(index, focus = false) {
  tabs.forEach((tab, i) => {
    tab.setAttribute('aria-selected', String(i === index));
    tab.tabIndex = i === index ? 0 : -1;
    document.getElementById(tab.getAttribute('aria-controls')).hidden = i !== index;
  });
  if (focus) tabs[index].focus();
}
tabs.forEach((tab, index) => {
  tab.addEventListener('click', () => selectTab(index));
  tab.addEventListener('keydown', event => {
    let next;
    if (event.key === 'ArrowRight') next = (index + 1) % tabs.length;
    if (event.key === 'ArrowLeft') next = (index + tabs.length - 1) % tabs.length;
    if (event.key === 'Home') next = 0;
    if (event.key === 'End') next = tabs.length - 1;
    if (next !== undefined) { event.preventDefault(); selectTab(next, true); }
  });
});

async function renderPlans() {
  const box = document.getElementById('plans');
  const cfg = await getConfig();
  box.innerHTML = cfg.plans.map(p => `
    <article class="plan${p.highlight ? ' hl' : ''}">
      ${p.highlight ? `<span class="badge">${escapeHTML(t('price.badge'))}</span>` : ''}
      <h3>${escapeHTML(planName(p))}</h3>
      <p class="devices">${escapeHTML(t('price.devices', { n: p.devices }))}</p>
      <div class="price"><span class="amt">${escapeHTML(money(p.price, p.currency || 'CNY'))}</span><span class="once">${escapeHTML(t('price.once'))}</span></div>
      <ul>${planFeatures(p).map(f => `<li><svg class="i" aria-hidden="true"><use href="/assets/img/icons.svg#check"/></svg><span>${escapeHTML(f)}</span></li>`).join('')}</ul>
      <a class="btn ${p.highlight ? 'btn-primary' : 'btn-ghost'}" href="/buy.html?plan=${encodeURIComponent(p.id)}">${escapeHTML(t('price.buy', { name: planName(p) }))}</a>
    </article>`).join('');
}
renderPlans();
onLangChange(renderPlans);
