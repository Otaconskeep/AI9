#!/usr/bin/env node
/**
 * Regression tests for AI9 local image selection (file-picker wiring).
 * No npm deps — Node 18+ only.
 * Run: node tools/test_local_image_select.mjs
 */
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createServer } from 'node:http';

const __dirname = dirname(fileURLToPath(import.meta.url));
const root = join(__dirname, '..');
const modPath = pathToFileURL(join(root, 'extension/localImageSelect.js')).href;

const {
  FILE_INPUT_ACCEPT,
  unsupportedFileReason,
  isSupportedImageFile,
  buildColorizePostData,
  dataUrlToObjectUrl,
  attachLocalImageSelect,
  extensionMime,
} = await import(modPath);

let failed = 0;
function check(name, fn) {
  try {
    fn();
    console.log(`[OK]   ${name}`);
  } catch (e) {
    failed += 1;
    console.error(`[FAIL] ${name}: ${e && e.message ? e.message : e}`);
  }
}

async function checkAsync(name, fn) {
  try {
    await fn();
    console.log(`[OK]   ${name}`);
  } catch (e) {
    failed += 1;
    console.error(`[FAIL] ${name}: ${e && e.message ? e.message : e}`);
  }
}

/** Minimal EventTarget for attachLocalImageSelect without jsdom. */
function makeEl(tag) {
  const listeners = new Map();
  const el = {
    tagName: String(tag || 'DIV').toUpperCase(),
    style: {},
    disabled: false,
    value: '',
    files: null,
    accept: '',
    multiple: false,
    tabIndex: 0,
    textContent: '',
    click() {
      const set = listeners.get('click');
      if (set) for (const fn of set) fn({ preventDefault() {}, stopPropagation() {} });
    },
    addEventListener(type, fn) {
      if (!listeners.has(type)) listeners.set(type, new Set());
      listeners.get(type).add(fn);
    },
    removeEventListener(type, fn) {
      const set = listeners.get(type);
      if (set) set.delete(fn);
    },
    dispatchEvent(type) {
      const set = listeners.get(type);
      if (set) for (const fn of set) fn({ preventDefault() {}, stopPropagation() {} });
    },
  };
  return el;
}

check('accept attribute includes png/jpeg', () => {
  assert.match(FILE_INPUT_ACCEPT, /image\/png/);
  assert.match(FILE_INPUT_ACCEPT, /image\/jpeg/);
  assert.match(FILE_INPUT_ACCEPT, /\.png/);
  assert.match(FILE_INPUT_ACCEPT, /\.jpg/);
});

check('extensionMime maps common types', () => {
  assert.equal(extensionMime('photo.JPG'), 'image/jpeg');
  assert.equal(extensionMime('x.png'), 'image/png');
  assert.equal(extensionMime('noext'), '');
});

check('accepts png/jpeg by mime and by extension', () => {
  assert.equal(unsupportedFileReason({ name: 'a.png', type: 'image/png' }), null);
  assert.equal(unsupportedFileReason({ name: 'a.jpg', type: 'image/jpeg' }), null);
  assert.equal(unsupportedFileReason({ name: 'a.jpeg', type: '' }), null);
  assert.ok(isSupportedImageFile({ name: 'a.webp', type: 'image/webp' }));
});

check('rejects unsupported types', () => {
  const reason = unsupportedFileReason({ name: 'notes.pdf', type: 'application/pdf' });
  assert.ok(reason && /Unsupported/i.test(reason));
});

check('buildColorizePostData shapes API body for local path', () => {
  const body = buildColorizePostData({
    imgName: 'C:\\Users\\test\\page.png',
    imgData: 'data:image/png;base64,aaa',
    imgWidth: 10,
    imgHeight: 20,
    cache: true,
    denoise: false,
    colorize: true,
    upscale: false,
    denoiseSigma: '25',
    upscaleFactor: '4',
    adjustments: { saturation: 1 },
  });
  assert.equal(body.imgName, 'C:\\Users\\test\\page.png');
  assert.equal(body.mangaTitle, 'local');
  assert.equal(body.mangaChapter, 'upload');
  assert.equal(body.imgWidth, 10);
  assert.equal(body.denoise, false);
  assert.equal(body.colorize, true);
});

check('dataUrlToObjectUrl produces blob URL', () => {
  const png =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
  const url = dataUrlToObjectUrl(png);
  assert.match(url, /^blob:/);
});

check('popup.html wires Select an image + file input', () => {
  const html = readFileSync(join(root, 'extension/popup.html'), 'utf8');
  assert.match(html, /id="select-local-image"/);
  assert.match(html, />Select an image</);
  assert.match(html, /id="local-image-input"/);
  assert.match(html, /type="file"/);
  assert.match(html, /id="force-run"/);
});

check('popup.js no longer renames Force Colorize to Select an Image', () => {
  const js = readFileSync(join(root, 'extension/popup.js'), 'utf8');
  assert.doesNotMatch(js, /textContent\s*=\s*["']Select an Image["']/);
  assert.match(js, /attachLocalImageSelect/);
  assert.match(js, /FORCE_RUN_ACTIVE_LABEL/);
  assert.match(js, /browser\.tabs\.sendMessage/);
  assert.doesNotMatch(js, /chrome\.tabs\.sendMessage/);
});

check('localImageSelect.js is shipped next to popup', () => {
  assert.ok(existsSync(join(root, 'extension/localImageSelect.js')));
});

check('manifest version bumped for local select', () => {
  const manifest = JSON.parse(readFileSync(join(root, 'extension/manifest.json'), 'utf8'));
  const [maj, min, patch] = manifest.version.split('.').map(Number);
  assert.ok(maj > 0 || min > 6 || (min === 6 && patch >= 6), `version ${manifest.version}`);
});

await checkAsync('button click invokes fileInput.click() synchronously', async () => {
  const button = makeEl('button');
  const fileInput = makeEl('input');
  const statusEl = makeEl('span');
  let clickCount = 0;
  fileInput.click = () => { clickCount += 1; };

  attachLocalImageSelect({
    button,
    fileInput,
    statusEl,
    getSettings: () => ({ cache: false, denoise: false, colorize: true, upscale: false }),
    colorizeFn: async () => ({ colorImgData: 'data:image/webp;base64,AAAA' }),
    openResultFn: async () => {},
  });

  button.click();
  assert.equal(clickCount, 1, 'input.click() must run from the user gesture handler');
  assert.equal(fileInput.accept, FILE_INPUT_ACCEPT);
  // Must not use display:none (breaks programmatic click in some browsers)
  assert.notEqual(fileInput.style.display, 'none');
});

await checkAsync('cancel (empty files) does not error; unsupported types surface message', async () => {
  const button = makeEl('button');
  const fileInput = makeEl('input');
  const statusEl = makeEl('span');
  const posts = [];

  attachLocalImageSelect({
    button,
    fileInput,
    statusEl,
    getSettings: () => ({}),
    colorizeFn: async (postData) => { posts.push(postData); return { colorImgData: 'data:image/webp;base64,AA' }; },
    openResultFn: async () => {},
  });

  fileInput.files = null;
  fileInput.dispatchEvent('change');
  assert.equal(posts.length, 0);
  assert.equal(statusEl.textContent, '');

  fileInput.files = [{ name: 'x.pdf', type: 'application/pdf' }];
  fileInput.dispatchEvent('change');
  await new Promise((r) => setTimeout(r, 10));
  assert.equal(posts.length, 0);
  assert.match(statusEl.textContent, /Unsupported/i);
});

await checkAsync('mock API accepts local JPG/PNG payloads (upload path)', async () => {
  const server = createServer((req, res) => {
    if (req.method === 'POST' && req.url === '/colorize-image-data') {
      let body = '';
      req.on('data', (c) => { body += c; });
      req.on('end', () => {
        const json = JSON.parse(body);
        assert.ok(json.imgData && json.imgData.includes('base64'));
        assert.equal(json.mangaTitle, 'local');
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({
          colorImgData: 'data:image/webp;base64,QUJDRA==',
          cached: false,
        }));
      });
      return;
    }
    res.writeHead(404);
    res.end();
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const { port } = server.address();

  const postData = buildColorizePostData({
    imgName: 'x.jpg',
    imgData: 'data:image/jpeg;base64,/9j/4AAQ',
    imgWidth: 1,
    imgHeight: 1,
    cache: false,
    denoise: false,
    colorize: true,
    upscale: false,
  });
  const resp = await fetch(`http://127.0.0.1:${port}/colorize-image-data`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(postData),
  });
  assert.equal(resp.status, 200);
  const out = await resp.json();
  assert.ok(out.colorImgData.startsWith('data:image/webp'));
  server.close();
});

if (failed) {
  console.error(`\n${failed} test(s) failed`);
  process.exit(1);
}
console.log('\nAll local image selection regression tests passed.');
