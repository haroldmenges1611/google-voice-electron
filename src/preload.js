'use strict';

const { contextBridge, ipcRenderer, webFrame } = require('electron');

// Runs in the page's own JavaScript world and replaces window.Notification, so notifications
// the page creates are sent to the main process. The page's Content Security Policy would
// block an inline <script> tag, but webFrame.executeJavaScript is not subject to it.
const SHIM = `(() => {
  if (window.__gvNotificationShim) return;
  Object.defineProperty(window, '__gvNotificationShim', { value: true });

  const payloadFrom = (title, options) => ({
    title: String(title ?? ''),
    body: options?.body ? String(options.body) : '',
    tag: options?.tag ? String(options.tag) : '',
  });

  class GVNotification {
    constructor(title, options) {
      window.__gvNotify(payloadFrom(title, options));
      this.title = String(title ?? '');
      this.body = options?.body ? String(options.body) : '';
      this.tag = options?.tag ? String(options.tag) : '';
    }
    close() {}
    addEventListener() {}
    removeEventListener() {}
    static get permission() { return 'granted'; }
    static requestPermission() { return Promise.resolve('granted'); }
  }

  Object.defineProperty(window, 'Notification', { value: GVNotification, writable: true, configurable: true });

  if (window.ServiceWorkerRegistration) {
    Object.defineProperty(ServiceWorkerRegistration.prototype, 'showNotification', {
      value(title, options) {
        window.__gvNotify(payloadFrom(title, options));
        return Promise.resolve();
      },
      writable: true,
      configurable: true,
    });
  }
})();`;

contextBridge.exposeInMainWorld('__gvNotify', (payload) => {
  ipcRenderer.send('gv:notify', payload);
});

window.addEventListener('DOMContentLoaded', () => {
  webFrame.executeJavaScript(SHIM).catch((error) => console.error('notification shim failed:', error));
}, { once: true });
