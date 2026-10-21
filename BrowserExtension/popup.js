// Sonuvi — GPL-3.0.
'use strict';
const t = key => chrome.i18n.getMessage(key);
for (const element of document.querySelectorAll('[data-message]')) element.textContent = t(element.dataset.message);
const status = document.getElementById('status');
const button = document.getElementById('retry');
async function check() {
  status.textContent = t('connecting'); button.disabled = true;
  try {
    const result = await chrome.runtime.sendNativeMessage('com.wusir.sonuvi.browser', { version: 1, action: 'ping' });
    status.textContent = result?.ok ? t('connected') : result?.error || t('missing');
  } catch { status.textContent = t('missing'); }
  button.disabled = false;
}
button.addEventListener('click', check);
check();
