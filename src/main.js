'use strict';

const path = require('node:path');
const {
  app,
  BrowserWindow,
  Menu,
  Notification,
  Tray,
  ipcMain,
  nativeImage,
  screen,
  session,
  shell,
} = require('electron');
const policy = require('./policy');

// GV_TEST=1 is set only by `npm test`. It points the panel at a local page and prints
// GV_EVENT lines. Normal runs never read GV_URL.
const TEST_MODE = process.env.GV_TEST === '1';
const HOME_URL = TEST_MODE && process.env.GV_URL ? process.env.GV_URL : 'https://voice.google.com/';
const TEST_ORIGIN = TEST_MODE ? new URL(HOME_URL).origin : null;
const PANEL_SIZE = { width: 460, height: 680 };
const POPUP_SIZE = { width: 480, height: 640 };

let tray = null;
let panel = null;
const popups = new Set();
const liveNotifications = new Set(); // keeps a notification alive until it is closed or clicked

function report(event, data = {}) {
  if (TEST_MODE) console.log(`GV_EVENT ${JSON.stringify({ event, ...data })}`);
}

function openInBrowser(url) {
  if (/^https?:\/\//.test(url)) shell.openExternal(url);
}

function guardNavigation(contents) {
  contents.on('will-navigate', (event, url) => {
    if (!policy.isAppUrl(url, TEST_ORIGIN)) {
      event.preventDefault();
      openInBrowser(url);
    }
  });
}

function handleWindowOpen({ url }) {
  // Google sign-in opens pop-ups. They are real windows in the same session, so cookies carry over.
  if (url === 'about:blank' || policy.isAppUrl(url, TEST_ORIGIN)) {
    return { action: 'allow', overrideBrowserWindowOptions: POPUP_SIZE };
  }
  openInBrowser(url);
  return { action: 'deny' };
}

function createPanel() {
  panel = new BrowserWindow({
    ...PANEL_SIZE,
    show: false,
    frame: false,
    resizable: false,
    fullscreenable: false,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      // Keep the page running while the panel is hidden, so new messages still arrive.
      backgroundThrottling: false,
    },
  });

  const { webContents } = panel;
  webContents.setWindowOpenHandler(handleWindowOpen);
  guardNavigation(webContents);

  webContents.on('did-create-window', (popup) => {
    popups.add(popup);
    popup.on('closed', () => popups.delete(popup));
    popup.webContents.setWindowOpenHandler(handleWindowOpen);
    guardNavigation(popup.webContents);
  });

  webContents.on('render-process-gone', (_event, details) => {
    report('render-gone', { reason: details.reason });
    webContents.reload();
  });

  webContents.on('did-finish-load', () => {
    if (TEST_MODE) probePage();
  });

  // Hide when focus moves elsewhere, but not while a sign-in pop-up is in front.
  panel.on('blur', () => {
    if (popups.size === 0) panel.hide();
  });

  panel.loadURL(HOME_URL);
}

function probePage() {
  panel.webContents.executeJavaScript(`({
    userAgent: navigator.userAgent,
    brands: navigator.userAgentData ? navigator.userAgentData.brands.map((b) => b.brand) : [],
    shimInstalled: Boolean(window.__gvNotificationShim),
    notificationClass: window.Notification.name,
    permission: window.Notification.permission,
  })`).then(
    (state) => report('page-state', state),
    (error) => report('page-error', { message: String(error) }),
  );
}

function onNotify(event, payload) {
  if (!policy.isAppUrl(event.sender.getURL(), TEST_ORIGIN)) return;

  const { title, body } = policy.notificationPayload(payload);
  report('notify', { title, body });
  if (!Notification.isSupported()) return;

  const notification = new Notification({ title, body });
  const done = () => liveNotifications.delete(notification);
  notification.on('click', () => {
    done();
    showPanel();
  });
  notification.on('close', done);
  liveNotifications.add(notification);
  try {
    notification.show();
  } catch (error) {
    done();
    report('notify-error', { message: String(error) });
  }
}

// Packaged builds copy assets next to app.asar (--extra-resource), so native image loading never
// has to read from inside the archive.
const ASSETS_DIR = app.isPackaged ? path.join(process.resourcesPath, 'assets') : path.join(__dirname, '..', 'assets');

function createTray() {
  const icon = nativeImage.createFromPath(path.join(ASSETS_DIR, 'trayTemplate.png'));
  tray = new Tray(icon);
  tray.setToolTip('Google Voice');
  tray.on('click', togglePanel);
  tray.on('right-click', () => tray.popUpContextMenu(buildContextMenu()));
}

function togglePanel() {
  if (panel.isVisible()) {
    panel.hide();
  } else {
    showPanel();
  }
}

function showPanel() {
  if (!panel) return;
  if (tray) {
    // Centre the panel under the menu bar icon, kept on screen.
    const anchor = tray.getBounds();
    const { workArea } = screen.getDisplayNearestPoint({ x: anchor.x, y: anchor.y });
    const wanted = anchor.x + Math.round(anchor.width / 2) - Math.round(PANEL_SIZE.width / 2);
    const x = Math.min(Math.max(wanted, workArea.x), workArea.x + workArea.width - PANEL_SIZE.width);
    panel.setPosition(x, anchor.y + anchor.height);
  }
  app.focus({ steal: true });
  panel.show();
  panel.focus();
}

function buildContextMenu() {
  return Menu.buildFromTemplate([
    { label: 'Show Google Voice', click: showPanel },
    { label: 'Reload', click: () => panel.webContents.reload() },
    { label: 'Open in Browser', click: () => openInBrowser(HOME_URL) },
    { type: 'separator' },
    {
      label: 'Open at Login',
      type: 'checkbox',
      checked: app.getLoginItemSettings().openAtLogin,
      click: (item) => app.setLoginItemSettings({ openAtLogin: item.checked }),
    },
    { type: 'separator' },
    { role: 'quit', label: 'Quit Google Voice' },
  ]);
}

function configureSession() {
  // Chromium's user agent instead of Electron's, for sign-in pages that refuse embedded apps.
  app.userAgentFallback = policy.chromeUserAgent(process.versions.chrome, process.platform);

  const ses = session.defaultSession;
  ses.setPermissionRequestHandler((_contents, permission, callback, details) => {
    callback(policy.isAllowedPermission(permission, details.requestingUrl, TEST_ORIGIN));
  });
  ses.setPermissionCheckHandler((_contents, permission, requestingOrigin) =>
    policy.isAllowedPermission(permission, requestingOrigin, TEST_ORIGIN));
}

function start() {
  if (app.dock) app.dock.hide();
  configureSession();
  Menu.setApplicationMenu(Menu.buildFromTemplate([
    { role: 'appMenu' },
    { role: 'editMenu' }, // gives Cmd-C, Cmd-V and Cmd-A in the panel
  ]));
  ipcMain.on('gv:notify', onNotify);
  createPanel();
  try {
    createTray();
  } catch (error) {
    console.error('menu bar icon unavailable:', error);
    report('tray-error', { message: String(error) });
  }
}

if (app.requestSingleInstanceLock()) {
  app.on('second-instance', showPanel);
  app.on('window-all-closed', () => {}); // stay in the menu bar
  app.whenReady().then(start);
} else {
  app.quit();
}
