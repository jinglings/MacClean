import { boot, getConfig, planName, money, escapeHTML } from './common.js?v=20261002.1';
import { api, errorMessage } from './api.js?v=20261002.1';
import { t, onLangChange } from './i18n.js?v=20261002.1';
import { mountOrder, saveOrder, renderSavedOrders, fetchOrder } from './order-view.js?v=20261002.1';

boot();

const form = document.getElementById('buy-form');
const choices = document.getElementById('plan-choices');
const emailInput = document.getElementById('email');
const emailErr = document.getElementById('email-err');
const msg = document.getElementById('form-msg');
const submit = document.getElementById('submit-btn');
const orderBox = document.getElementById('order-box');
const savedBox = document.getElementById('saved');

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;
let cfg;
let view = null;

function selectedPlan() {
  const id = form.querySelector('input[name="plan"]:checked')?.value;
  return cfg.plans.find(p => p.id === id);
}

function renderChoices() {
  const want = choices.querySelector('input:checked')?.value
    || new URLSearchParams(location.search).get('plan')
    || (cfg.plans.find(p => p.highlight) || cfg.plans[0]).id;
  choices.innerHTML = cfg.plans.map(p => `
    <label class="choice">
      <input type="radio" name="plan" value="${escapeHTML(p.id)}" ${p.id === want ? 'checked' : ''}>
      <span class="box">
        <b><span>${escapeHTML(planName(p))}</span><span>${escapeHTML(money(p.price, p.currency || 'CNY'))}</span></b>
        <span>${escapeHTML(t('price.devices', { n: p.devices }))}</span>
      </span>
    </label>`).join('');
  if (!choices.querySelector('input:checked')) choices.querySelector('input')?.click();
  renderSummary();
}

function renderSummary() {
  const p = selectedPlan();
  if (!p) return;
  document.getElementById('sum-plan').textContent = planName(p);
  document.getElementById('sum-devices').textContent = t('price.devices', { n: p.devices });
  document.getElementById('sum-total').textContent = money(p.price, p.currency || 'CNY');
}

function showError(text) {
  msg.innerHTML = text ? `<div class="alert err" role="alert"><svg class="i" aria-hidden="true"><use href="/assets/img/icons.svg#alert"/></svg><span>${escapeHTML(text)}</span></div>` : '';
}

function validateEmail() {
  const v = emailInput.value.trim();
  const bad = !EMAIL_RE.test(v);
  emailInput.setAttribute('aria-invalid', String(bad));
  emailErr.hidden = !bad;
  emailErr.textContent = bad ? t(v ? 'buy.emailBad' : 'buy.emailEmpty') : '';
  return !bad;
}

form.addEventListener('change', e => { if (e.target.name === 'plan') renderSummary(); });
emailInput.addEventListener('blur', () => { if (emailInput.value) validateEmail(); });
emailInput.addEventListener('input', () => { if (emailInput.getAttribute('aria-invalid') === 'true') validateEmail(); });

form.addEventListener('submit', async e => {
  e.preventDefault();
  showError('');
  if (!validateEmail()) { emailInput.focus(); return; }
  const plan = selectedPlan();
  if (!plan) { showError(t('buy.pickPlan')); return; }
  const payMethod = form.querySelector('input[name="payMethod"]:checked')?.value || 'wechat';

  submit.classList.add('loading');
  submit.disabled = true;
  try {
    const order = await api('/api/orders', {
      method: 'POST',
      body: { plan: plan.id, email: emailInput.value.trim(), payMethod },
    });
    const createdAt = new Date().toISOString();
    saveOrder({ orderNo: order.orderNo, token: order.accessToken, amount: order.amount, status: order.status, createdAt });
    showOrder({ ...order, plan: plan.id, planName: plan.name, devices: plan.devices, createdAt }, order.accessToken);
  } catch (err) {
    showError(err.kind === 'rate' ? t('err.rateOrders') : errorMessage(err));
  } finally {
    submit.classList.remove('loading');
    submit.disabled = false;
  }
});

function showOrder(order, token) {
  form.hidden = true;
  savedBox.hidden = true;
  orderBox.hidden = false;
  document.getElementById('restart').hidden = false;
  view = mountOrder(orderBox, order, { token });
  history.replaceState(null, '', `${location.pathname}?no=${encodeURIComponent(order.orderNo)}&token=${encodeURIComponent(token)}`);
  orderBox.focus({ preventScroll: true });
  orderBox.scrollIntoView({ behavior: 'smooth', block: 'start' });
}

async function init() {
  cfg = await getConfig();
  renderChoices();
  renderSavedOrders(savedBox);
  // Returning to buy.html?no=…&token=… (e.g. after a reload) reopens that order.
  const q = new URLSearchParams(location.search);
  if (q.get('no') && q.get('token')) {
    try {
      const order = await fetchOrder(q.get('no'), { token: q.get('token') });
      showOrder(order, q.get('token'));
    } catch { /* fall back to the form */ }
  }
}

init();
onLangChange(() => {
  if (!cfg) return;
  renderChoices();
  renderSavedOrders(savedBox);
  if (emailInput.getAttribute('aria-invalid') === 'true') validateEmail();
  view?.redraw();
});
