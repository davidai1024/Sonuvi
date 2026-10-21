// Sonuvi — GPL-3.0.
'use strict';
const HOST = 'com.wusir.sonuvi.browser';
const t = key => chrome.i18n.getMessage(key);
let lastError = '';
function markError(message) {
  lastError = message;
  chrome.action.setBadgeText({ text: message ? '!' : '' });
  chrome.action.setBadgeBackgroundColor({ color: '#b34739' });
  chrome.action.setTitle({ title: message || 'Sonuvi' });
}
function installMenus() {
  chrome.contextMenus.removeAll(() => {
    chrome.contextMenus.create({ id: 'sonuvi', title: 'Sonuvi', contexts: ['selection'] });
    chrome.contextMenus.create({ id: 'translate', parentId: 'sonuvi', title: t('translate'), contexts: ['selection'] });
    chrome.contextMenus.create({ id: 'read', parentId: 'sonuvi', title: t('read'), contexts: ['selection'] });
  });
}
chrome.runtime.onInstalled.addListener(installMenus);
chrome.runtime.onStartup.addListener(installMenus);
chrome.contextMenus.onClicked.addListener(async info => {
  if (!['translate', 'read'].includes(info.menuItemId)) return;
  const text = typeof info.selectionText === 'string' ? info.selectionText : '';
  if (!text.trim() || Array.from(text).length > 6000) { markError(t('limit')); return; }
  try {
    const result = await chrome.runtime.sendNativeMessage(HOST, { version: 1, action: info.menuItemId, text });
    markError(result?.ok ? '' : result?.error || t('missing'));
  } catch { markError(t('missing')); }
});
chrome.runtime.onMessage.addListener((message, sender, respond) => {
  if (sender.id !== chrome.runtime.id || message?.type !== 'status') return;
  respond({ error: lastError });
});
