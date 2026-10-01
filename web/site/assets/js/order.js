import { boot, escapeHTML } from './common.js';
import { errorMessage } from './api.js';
import { t, onLangChange } from './i18n.js';
import { mountOrder, fetchOrder, renderSavedOrders } from './order-view.js';

boot();

const form = document.getElementById('lookup');
const noInput = document.getElementById('no');
const emailInput = document.getElementById('lemail');
const msg = document.getElementById('lookup-msg');
const btn = document.getElementById('lookup-btn');
const box = document.getElementById('order-box');
const savedBox = document.getElementById('saved');
const loading = document.getElementById('loading');
let view = null;

function showError(text) {
  msg.innerHTML = text ? `<div class="alert err" role="alert"><svg class="i" aria-hidden="true"><use href="/assets/img/icons.svg#alert"/></svg><span>${escapeHTML(text)}</span></div>` : '';
}

function show(order, auth) {
  form.hidden = true;
  savedBox.hidden = true;
  loading.hidden = true;
  box.hidden = false;
  document.getElementById('back').hidden = false;
  view = mountOrder(box, order, auth);
}

form.addEventListener('submit', async e => {
  e.preventDefault();
  showError('');
  const no = noInput.value.trim().toUpperCase();
  const email = emailInput.value.trim();
  if (!no || !email) { showError(t('order.needBoth')); return; }
  btn.classList.add('loading');
  btn.disabled = true;
  try {
    show(await fetchOrder(no, { email }), { email });
  } catch (err) {
    showError(errorMessage(err, 'err.orderNotFound'));
  } finally {
    btn.classList.remove('loading');
    btn.disabled = false;
  }
});

async function init() {
  const q = new URLSearchParams(location.search);
  const no = q.get('no'), token = q.get('token');
  if (no) noInput.value = no;
  if (no && token) {
    form.hidden = true;
    loading.hidden = false;
    try {
      show(await fetchOrder(no, { token }), { token });
      return;
    } catch (err) {
      loading.hidden = true;
      form.hidden = false;
      showError(errorMessage(err, 'err.orderLinkBad'));
    }
  }
  renderSavedOrders(savedBox);
}

init();
onLangChange(() => { view?.redraw(); if (!form.hidden) renderSavedOrders(savedBox); });
