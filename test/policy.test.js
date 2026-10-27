'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const policy = require('../src/policy');

test('only HTTPS Google hosts count as Google Voice pages', () => {
  assert.equal(policy.isGoogleUrl('https://voice.google.com/'), true);
  assert.equal(policy.isGoogleUrl('https://accounts.google.com/signin'), true);
  assert.equal(policy.isGoogleUrl('https://google.com/'), true);
  assert.equal(policy.isGoogleUrl('http://voice.google.com/'), false);
  assert.equal(policy.isGoogleUrl('https://google.com.evil.example/'), false);
  assert.equal(policy.isGoogleUrl('https://evilgoogle.com/'), false);
  assert.equal(policy.isGoogleUrl('not a url'), false);
  assert.equal(policy.isGoogleUrl(undefined), false);
});

test('the test origin is allowed only on its exact origin', () => {
  assert.equal(policy.isAppUrl('http://127.0.0.1:5000/x', 'http://127.0.0.1:5000'), true);
  assert.equal(policy.isAppUrl('http://127.0.0.1:5001/', 'http://127.0.0.1:5000'), false);
  assert.equal(policy.isAppUrl('http://127.0.0.1:5000/', null), false);
});

test('permissions are granted only for allowed kinds on Google pages', () => {
  assert.equal(policy.isAllowedPermission('notifications', 'https://voice.google.com/', null), true);
  assert.equal(policy.isAllowedPermission('media', 'https://voice.google.com/', null), true);
  assert.equal(policy.isAllowedPermission('geolocation', 'https://voice.google.com/', null), false);
  assert.equal(policy.isAllowedPermission('notifications', 'https://example.com/', null), false);
});

test('the user agent is Chromium without the Electron token', () => {
  const ua = policy.chromeUserAgent('150.0.0.0', 'darwin');
  assert.match(ua, /^Mozilla\/5\.0 \(Macintosh;/);
  assert.match(ua, /Chrome\/150\.0\.0\.0 Safari\/537\.36$/);
  assert.doesNotMatch(ua, /Electron/);
});

test('notification text is limited and the title is never empty', () => {
  assert.deepEqual(
    policy.notificationPayload({ title: 'Alice', body: 'Code 123' }),
    { title: 'Alice', body: 'Code 123' },
  );
  assert.equal(policy.notificationPayload({ title: 42 }).title, 'Google Voice');
  assert.equal(policy.notificationPayload(null).body, '');
  assert.equal(policy.notificationPayload({ title: 'x'.repeat(500) }).title.length, 200);
});
