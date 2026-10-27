'use strict';

// Pure rules shared by the main process and the tests. No Electron imports, so they run under plain Node.

const ALLOWED_PERMISSIONS = new Set([
  'notifications',
  'media', // microphone, for calls
  'clipboard-sanitized-write',
  'clipboard-read',
  'fullscreen',
]);

// Google Voice and the Google sign-in pages, over HTTPS only.
function isGoogleUrl(url) {
  try {
    const { protocol, hostname } = new URL(url);
    return protocol === 'https:' && (hostname === 'google.com' || hostname.endsWith('.google.com'));
  } catch {
    return false;
  }
}

// `extraOrigin` is set only by the test run, which serves a local page in place of Google Voice.
function isAppUrl(url, extraOrigin) {
  if (isGoogleUrl(url)) return true;
  try {
    return Boolean(extraOrigin) && new URL(url).origin === extraOrigin;
  } catch {
    return false;
  }
}

function isAllowedPermission(permission, requestingUrl, extraOrigin) {
  return ALLOWED_PERMISSIONS.has(permission) && isAppUrl(requestingUrl, extraOrigin);
}

// Chromium's normal user agent for this platform. Electron adds an "Electron/x" token by
// default, and Google can refuse sign-in when it sees one.
function chromeUserAgent(chromeVersion, platform) {
  const os = {
    darwin: 'Macintosh; Intel Mac OS X 10_15_7',
    win32: 'Windows NT 10.0; Win64; x64',
  }[platform] ?? 'X11; Linux x86_64';
  return `Mozilla/5.0 (${os}) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/${chromeVersion} Safari/537.36`;
}

// Limits what a page can put into a native notification.
function notificationPayload(input) {
  const text = (value, max) => (typeof value === 'string' ? value.slice(0, max) : '');
  return {
    title: text(input?.title, 200) || 'Google Voice',
    body: text(input?.body, 1000),
  };
}

module.exports = { isGoogleUrl, isAppUrl, isAllowedPermission, chromeUserAgent, notificationPayload };
