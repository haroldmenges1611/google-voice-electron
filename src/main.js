'use strict';

const fs = require('node:fs');
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
const PANEL_SIZE = { width: 780, height: 700 };
const POPUP_SIZE = { width: 780, height: 700 };
const WINDOW_SIZE = { width: 1100, height: 760 };

// 'window' runs like a normal app (Dock icon, resizable window); 'menubar' is a panel under the tray icon.
let mode = 'window';
let settings = {};
let quitting = false;

let tray = null;
let panel = null;
const popups = new Set();
const liveNotifications = new Set(); // keeps a notification alive until it is closed or clicked

function report(event, data = {}) {
  if (TEST_MODE) console.log(`GV_EVENT ${JSON.stringify({ event, ...data })}`);
}

function loadSettings() {
  try {
    settings = JSON.parse(fs.readFileSync(path.join(app.getPath('userData'), 'settings.json'), 'utf8'));
  } catch {
    settings = {};
  }
  mode = settings.mode === 'menubar' ? 'menubar' : 'window';
}

function saveSettings(patch) {
  settings = { ...settings, ...patch };
  try {
    fs.writeFileSync(path.join(app.getPath('userData'), 'settings.json'), JSON.stringify(settings));
  } catch (error) {
    console.error('could not save settings:', error);
  }
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
    const existing = [...popups].find((popup) => !popup.isDestroyed());
    if (existing) {
      if (url !== 'about:blank') {
        // Only one pop-up at a time: reuse it instead of opening another.
        existing.loadURL(url);
        existing.show();
        existing.focus();
        return { action: 'deny' };
      }
      // A script-driven pop-up (sign-in) needs a fresh window it can talk to; replace the old one.
      existing.destroy();
    }
    return { action: 'allow', overrideBrowserWindowOptions: POPUP_SIZE };
  }
  openInBrowser(url);
  return { action: 'deny' };
}

function trackPopup(popup) {
  popups.add(popup);
  popup.on('closed', () => popups.delete(popup));
  popup.webContents.setWindowOpenHandler(handleWindowOpen);
  popup.webContents.on('did-create-window', trackPopup);
  popup.webContents.on('will-prevent-unload', (event) => event.preventDefault());
  guardNavigation(popup.webContents);
}

function createPanel() {
  const windowed = mode === 'window';
  const win = new BrowserWindow({
    ...(windowed ? { ...WINDOW_SIZE, ...settings.windowBounds, minWidth: 520, minHeight: 480 } : PANEL_SIZE),
    title: 'Google Voice',
    show: false,
    frame: windowed,
    resizable: windowed,
    fullscreenable: windowed,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      // Keep the page running while the panel is hidden, so new messages still arrive.
      backgroundThrottling: false,
    },
  });

  panel = win;
  const { webContents } = win;
  webContents.setWindowOpenHandler(handleWindowOpen);
  guardNavigation(webContents);

  webContents.on('did-create-window', trackPopup);
  // Never let a page's "leave site?" prompt keep a window open.
  webContents.on('will-prevent-unload', (event) => event.preventDefault());

  webContents.on('render-process-gone', (_event, details) => {
    report('render-gone', { reason: details.reason });
    webContents.reload();
  });

  webContents.on('did-finish-load', () => {
    if (TEST_MODE) probePage();
  });

  // Hide when focus moves elsewhere, but not while a sign-in pop-up is in front.
  win.on('blur', () => {
    if (!windowed && popups.size === 0) win.hide();
  });

  if (windowed) {
    win.once('ready-to-show', () => win.show());
    // Closing the window keeps the app running (so texts still arrive); Cmd-Q quits.
    win.on('close', (event) => {
      if (!quitting) {
        event.preventDefault();
        win.hide();
      }
    });
    let saveTimer = null;
    const rememberBounds = () => {
      clearTimeout(saveTimer);
      saveTimer = setTimeout(() => {
        if (!win.isDestroyed() && !win.isMinimized() && !win.isFullScreen()) saveSettings({ windowBounds: win.getBounds() });
      }, 500);
    };
    win.on('resize', rememberBounds);
    win.on('move', rememberBounds);
  }

  win.on('closed', () => {
    if (panel === win) panel = null;
  });

  win.loadURL(HOME_URL);
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
  if (mode === 'window' && panel.isMinimized()) panel.restore();
  if (mode === 'menubar' && tray) {
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
    ...modeItems(),
    { type: 'separator' },
    { label: 'Quit Google Voice', accelerator: 'Command+Q', click: () => app.quit() },
  ]);
}

function modeItems() {
  return [
    {
      label: 'Menu Bar Mode',
      type: 'checkbox',
      checked: mode === 'menubar',
      click: (item) => applyMode(item.checked ? 'menubar' : 'window'),
    },
    {
      label: 'Open at Login',
      type: 'checkbox',
      checked: app.getLoginItemSettings().openAtLogin,
      click: (item) => app.setLoginItemSettings({ openAtLogin: item.checked }),
    },
  ];
}

function buildAppMenu() {
  Menu.setApplicationMenu(Menu.buildFromTemplate([
    {
      label: 'Google Voice',
      submenu: [
        { role: 'about', label: 'About Google Voice' },
        { type: 'separator' },
        ...modeItems(),
        { type: 'separator' },
        { role: 'hide' },
        { role: 'hideOthers' },
        { role: 'unhide' },
        { type: 'separator' },
        { label: 'Quit Google Voice', accelerator: 'Command+Q', click: () => app.quit() },
      ],
    },
    { role: 'editMenu' }, // gives Cmd-C, Cmd-V and Cmd-A in the page
    {
      label: 'View',
      submenu: [
        { label: 'Reload', accelerator: 'Command+R', click: () => panel && panel.webContents.reload() },
        { type: 'separator' },
        { role: 'resetZoom' },
        { role: 'zoomIn' },
        { role: 'zoomOut' },
        { role: 'togglefullscreen' },
      ],
    },
    { role: 'windowMenu' },
  ]));
}

// Switches between normal-window and menu-bar mode, rebuilding the window to match.
function applyMode(next) {
  mode = next;
  saveSettings({ mode });
  popups.forEach((popup) => popup.destroy());
  if (panel) panel.destroy();
  if (mode === 'menubar') {
    if (app.dock) app.dock.hide();
    if (!tray) createTrayIfPossible();
  } else {
    if (tray) tray.destroy();
    tray = null;
    if (app.dock) app.dock.show();
  }
  buildAppMenu();
  createPanel();
  if (mode === 'menubar') showPanel();
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
  loadSettings();
  configureSession();
  buildAppMenu();
  ipcMain.on('gv:notify', onNotify);
  if (mode === 'menubar') {
    if (app.dock) app.dock.hide();
    createTrayIfPossible();
  } else if (app.dock && !app.isPackaged) {
    app.dock.setIcon(path.join(__dirname, '..', 'packaging', 'icon.png')); // dev runs only; the .app has its own
  }
  createPanel();
}

function createTrayIfPossible() {
  try {
    createTray();
  } catch (error) {
    console.error('menu bar icon unavailable:', error);
    report('tray-error', { message: String(error) });
  }
}

if (app.requestSingleInstanceLock()) {
  app.on('second-instance', showPanel);
  app.on('activate', () => {
    if (mode === 'window') showPanel(); // Dock icon clicked
  });
  app.on('window-all-closed', () => {}); // stay in the menu bar
  app.on('before-quit', () => {
    quitting = true;
    // Destroy rather than close, so no window can veto the quit.
    BrowserWindow.getAllWindows().forEach((win) => win.destroy());
  });
  app.whenReady().then(start);
} else {
  app.quit();
}
