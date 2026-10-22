import fs from 'node:fs/promises';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
const root = new URL('../BrowserExtension/', import.meta.url);
const manifest = JSON.parse(await fs.readFile(new URL('manifest.json', root), 'utf8'));
const id = [...createHash('sha256').update(Buffer.from(manifest.key, 'base64')).digest('hex').slice(0, 32)].map(value => String.fromCharCode(97 + parseInt(value, 16))).join('');
assert.equal(id, 'mgadkmbkjhbofgafpdkdclljmbdlnbac');
assert.deepEqual(manifest.permissions, ['contextMenus', 'nativeMessaging']);
assert.equal(manifest.host_permissions, undefined);
assert.equal(manifest.content_scripts, undefined);
let install, click, startup;
const menus = [], messages = [], badges = [];
const chrome = {
  i18n: { getMessage: key => key },
  action: { setBadgeText: value => badges.push(value.text), setBadgeBackgroundColor() {}, setTitle() {} },
  contextMenus: { removeAll: done => { menus.length = 0; done(); }, create: menu => menus.push(menu), onClicked: { addListener: listener => click = listener } },
  runtime: { id: 'test', onInstalled: { addListener: listener => install = listener }, onStartup: { addListener: listener => startup = listener }, onMessage: { addListener() {} }, sendNativeMessage: async (host, data) => { messages.push({ host, data }); return { ok: true }; } }
};
vm.runInNewContext(await fs.readFile(new URL('background.js', root), 'utf8'), { chrome });
install();
assert.equal(menus.length, 3);
assert.equal(menus[0].title, 'Sonuvi');
assert.equal(menus[1].parentId, 'sonuvi');
assert.equal(menus[2].parentId, 'sonuvi');
assert(menus.every(menu => menu.contexts.length === 1 && menu.contexts[0] === 'selection'));
startup(); assert.equal(menus.length, 3);
await click({ menuItemId: 'translate', selectionText: 'Selected only', pageUrl: 'https://private.invalid/sensitive', otherText: 'Must not transmit' });
assert.equal(messages.length, 1);
assert.deepEqual(JSON.parse(JSON.stringify(messages[0])), { host: 'com.wusir.sonuvi.browser', data: { version: 1, action: 'translate', text: 'Selected only' } });
await click({ menuItemId: 'read', selectionText: 'Read this' });
assert.equal(messages[1].data.action, 'read');
await click({ menuItemId: 'sonuvi', selectionText: 'Not an action' });
await click({ menuItemId: 'read', selectionText: '' });
await click({ menuItemId: 'translate', selectionText: 'a'.repeat(200001) });
assert.equal(messages.length, 2);
chrome.runtime.sendNativeMessage = async () => { throw Error('Native host unavailable'); };
await click({ menuItemId: 'read', selectionText: 'Retry fixture' });
assert.equal(badges.at(-1), '!');
console.log('PASS: browser extension menus, minimal permissions, selected-text-only messages, validation and connection failures');
