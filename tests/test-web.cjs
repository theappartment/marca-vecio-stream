const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const html = fs.readFileSync(path.join(__dirname, '..', 'src', 'web', 'index.html'), 'utf8');
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];
new vm.Script(script);
class Element {
  constructor(tag = 'div') { this.tag = tag; this.children = []; this.handlers = {}; this.style = {}; this.value = ''; this.checked = false; this.disabled = false; this.isConnected = true; this.textContent = ''; }
  append(...children) { this.children.push(...children); }
  appendChild(child) { this.append(child); return child; }
  replaceChildren(...children) { this.children = children; }
  set innerHTML(value) { assert.equal(value, '', 'Only empty HTML assignment allowed'); this.children = []; }
  addEventListener(type, handler) { this.handlers[type] = handler; }
  contains(node) { return this === node || this.children.some(child => child.contains?.(node)); }
  checkValidity() { return Number.isInteger(Number(this.value)) && Number(this.value) >= Number(this.min) && Number(this.value) <= Number(this.max); }
}
const nodes = new Map();
const requests = [];
const uploadRequests = [];
class UploadRequest {
  constructor() { this.upload = {}; this.headers = {}; }
  open(method, url) { this.url = url; this.method = method; }
  setRequestHeader(key, value) { this.headers[key] = value; }
  send(file) { uploadRequests.push({ url: this.url, file, headers: this.headers }); this.status = 200; this.responseText = '{"ok":true}'; queueMicrotask(() => this.onload()); }
}
const document = { hidden: false, activeElement: null, getElementById(id) { if (!nodes.has(id)) nodes.set(id, new Element()); return nodes.get(id); }, createElement(tag) { return new Element(tag); }, createTextNode(text) { return { textContent: text }; } };
const specialName = "Evento è & 'speciale'.png";
const state = { config: { videoFolder: 'C:\\contents', vlcPath: 'vlc.exe', webPort: 8090 }, playback: { isRunning: true, currentName: specialName, message: 'In riproduzione', pendingChanges: true }, priorityFrequency: 3,
  files: [{ name: specialName, kind: 'slide', enabled: true, priority: true, durationSeconds: 10, size: 20, modifiedAt: '2026-10-13' }, { name: 'Video.mp4', kind: 'video', enabled: true, priority: false, size: 40 }] };
const sandbox = { document, window: { location: { search: '' } }, localStorage: { getItem: () => 'secret', setItem() {} }, URLSearchParams,
  XMLHttpRequest: UploadRequest,
  URL: { createObjectURL: () => 'blob:test', revokeObjectURL() {} }, setTimeout: () => 0, setInterval: () => 0, confirm: () => true,
  fetch: async (url, options = {}) => { requests.push({ url, options }); return { ok: true, status: 200, json: async () => structuredClone(state), blob: async () => ({}) }; }, console };
const context = vm.createContext(sandbox);
vm.runInContext(script, context);
const flush = () => new Promise(resolve => setImmediate(resolve));
function descendants(node) { return [node, ...node.children.flatMap(child => child.children ? descendants(child) : [child])]; }
(async () => {
  await flush();
  const list = document.getElementById('fileList');
  assert.equal(list.children.length, 2);
  assert.equal(descendants(list).find(node => node.tag === 'strong').textContent, specialName);
  assert.equal(document.getElementById('priorityFrequency').value, '3');
  assert.match(document.getElementById('playbackStatus').textContent, /attesa/);
  const first = list.children[0];
  const duration = descendants(first).find(node => node.type === 'number');
  duration.value = '7';
  document.activeElement = duration;
  state.files[0].priority = false;
  vm.runInContext('renderState(' + JSON.stringify(state) + ')', context);
  assert.equal(list.children[0], first, 'Polling preserves unsaved editing');
  document.activeElement = null;
  const save = descendants(first).find(node => node.tag === 'button' && node.textContent === 'Salva');
  await save.handlers.click();
  const patch = requests.find(request => request.options.method === 'PATCH');
  assert.ok(patch.url.includes(encodeURIComponent(specialName)));
  assert.equal(JSON.parse(patch.options.body).durationSeconds, 7);
  assert.equal(patch.options.headers['X-Auth-Token'], 'secret');
  const img = descendants(list).find(node => node.tag === 'img');
  await context.loadPreview(img, state.files[0]);
  assert.equal(img.src, 'blob:test');
  const preview = requests.find(request => request.url.startsWith('/api/preview'));
  assert.equal(preview.options.headers['X-Auth-Token'], 'secret');
  assert.ok(!preview.url.includes('secret'));
  const frequency = document.getElementById('priorityFrequency'); frequency.value = '5';
  await frequency.handlers.change();
  assert.equal(JSON.parse(requests.find(request => request.url === '/api/rotation').options.body).priorityFrequency, 5);
  const globalDuration = document.getElementById('globalSlideDuration');
  globalDuration.value = '15';
  await document.getElementById('applySlideDurationBtn').handlers.click();
  assert.equal(JSON.parse(requests.find(request => request.url === '/api/slide-duration').options.body).slideDurationSeconds, 15);
  const video = list.children[1];
  assert.equal(descendants(video).filter(node => node.tag === 'img').length, 1, 'Video has thumbnail image');
  assert.equal(descendants(video).filter(node => node.type === 'number').length, 0);
  assert.equal(descendants(video).filter(node => node.type === 'checkbox').length, 1);
  document.getElementById('uploadCategory').value = 'promo';
  document.getElementById('uploadInput').files = [{name:'Promo.JPG'}, {name:'Video.mp4'}];
  await document.getElementById('uploadBtn').handlers.click();
  assert.match(uploadRequests[0].url, /priority=true/);
  assert.match(uploadRequests[1].url, /priority=false/);
  assert.equal(document.getElementById('uploadCategory').disabled, false);
  document.getElementById('uploadCategory').value = 'loop';
  document.getElementById('uploadInput').files = [{name:'Normale.png'}];
  await document.getElementById('uploadBtn').handlers.click();
  assert.match(uploadRequests[2].url, /priority=false/);
  document.getElementById('uploadCategory').value = 'reel';
  document.getElementById('uploadInput').files = [{name:'Reel.mp4'}];
  await document.getElementById('uploadBtn').handlers.click();
  assert.match(uploadRequests[3].url, /role=reel/);
  document.getElementById('uploadCategory').value = 'background';
  document.getElementById('uploadInput').files = [{name:'Sfondo.jpg'}];
  await document.getElementById('uploadBtn').handlers.click();
  assert.match(uploadRequests[4].url, /role=background/);
  console.log('PASS: web syntax, safe filenames, slide/video controls, metadata save, frequency, authenticated preview, polling preserves edits.');
})().catch(error => { console.error(error); process.exitCode = 1; });
