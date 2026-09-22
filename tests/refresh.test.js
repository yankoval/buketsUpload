const assert = require('node:assert/strict');
const test = require('node:test');
const fs = require('node:fs');
const vm = require('node:vm');
const { FolderRefreshController } = require('../refresh-controller');

function storage() {
    const values = new Map();
    return { getItem: k => values.get(k) ?? null, setItem: (k, v) => values.set(k, String(v)), removeItem: k => values.delete(k) };
}
function deferred() {
    let resolve, reject;
    const promise = new Promise((a, b) => { resolve = a; reject = b; });
    return { promise, resolve, reject };
}
const tick = () => new Promise(resolve => setImmediate(resolve));

test('rapid clicks share one request and cooldown starts only after completion', async () => {
    const wait = deferred(); let count = 0; let now = 1000;
    const c = new FolderRefreshController({ storage: storage(), scope: 'prod', now: () => now,
        fetchItems: () => { count++; return wait.promise; } });
    const a = c.load('A', { manual: true }); const b = c.load('A', { manual: true });
    assert.equal(c.state('A').loading, true);
    assert.equal(c.remaining('A'), 0);
    await tick(); assert.equal(count, 1);
    wait.resolve([]); await Promise.all([a, b]);
    assert.equal(c.remaining('A'), 120);
    await c.load('A', { manual: true }); assert.equal(count, 1);
    now += 120000;
    await c.load('A', { manual: true }); assert.equal(count, 2);
});

test('per-folder timers and caches survive reload without another list request', async () => {
    const local = storage(), session = storage(); let calls = 0;
    const opts = { storage: local, cacheStorage: session, scope: 'prod', now: () => 1000,
        fetchItems: async f => { calls++; return [{ name: f }]; } };
    const first = new FolderRefreshController(opts);
    await first.load('A');
    const reloaded = new FolderRefreshController(opts);
    assert.equal(reloaded.remaining('A'), 120);
    assert.deepEqual(await reloaded.load('A'), [{ name: 'A' }]);
    assert.equal(calls, 1);
    assert.equal(reloaded.remaining('B'), 0);
    await reloaded.load('B'); assert.equal(calls, 2);
    const otherScope = new FolderRefreshController({ ...opts, scope: 'test' });
    assert.equal(otherScope.remaining('A'), 0);
});

test('old timer storage is honored; corrupted values do not disable refresh', () => {
    const local = storage();
    local.setItem('refreshTimer_A', '121000'); local.setItem('refreshTimer_B', 'bad');
    const c = new FolderRefreshController({ storage: local, scope: 'prod', now: () => 1000 });
    assert.equal(c.remaining('A'), 120); assert.equal(c.remaining('B'), 0);
});

test('failed and malformed responses release the guard and permit retry', async () => {
    let attempt = 0;
    const c = new FolderRefreshController({ storage: storage(), scope: 'prod', fetchItems: async () => {
        if (++attempt === 1) throw new Error('offline');
        if (attempt === 2) return {};
        return [];
    } });
    await assert.rejects(c.load('A'), /offline/);
    assert.deepEqual(c.state('A'), { loading: false, remaining: 0 });
    await assert.rejects(c.load('A'), /Invalid file list/);
    await c.load('A', { manual: true }); assert.equal(attempt, 3);
});

test('unavailable browser storage retains in-memory protection', async () => {
    let calls = 0;
    const unavailable = { getItem() { throw new Error('blocked'); }, setItem() { throw new Error('blocked'); } };
    const c = new FolderRefreshController({ storage: unavailable, cacheStorage: unavailable, scope: 'prod',
        fetchItems: async () => { calls++; return []; } });
    await c.load('A'); await c.load('A', { manual: true });
    assert.equal(calls, 1); assert.equal(c.remaining('A'), 120);
});

function page({ initialFolder = '', listFetch = async () => [], tagFetch = async () => ({ status: 'finished' }), local = storage(), session = storage() } = {}) {
    local.setItem('ymq_gw_url', 'https://example.test/api'); local.setItem('ymq_api_key', 'test-key');
    const knownTags = new Map();
    const elements = new Map();
    function element() {
        return { style: {}, dataset: {}, children: [], value: '', textContent: '', disabled: false,
            contentWindow: {}, setAttribute(k, v) { this[k] = v; },
            appendChild(child) { this.children.push(child); },
            set innerHTML(v) { this.html = v; this.children = []; }, get innerHTML() { return this.html || ''; } };
    }
    const doc = { getElementById(id) { if (!elements.has(id)) elements.set(id, element()); return elements.get(id); }, createElement: element };
    const location = { hash: initialFolder ? '#folder=' + encodeURIComponent(initialFolder) : '', pathname: '/prod/index.html', origin: 'https://example.test' };
    const listeners = {}; const timeouts = new Map(); let timerId = 0; const calls = [], tagCalls = [], warnings = [];
    const win = { location, innerWidth: 1024, innerHeight: 768, addEventListener: (name, fn) => (listeners[name] ??= []).push(fn) };
    const ctx = vm.createContext({ document: doc, window: win, location, localStorage: local, sessionStorage: session,
        FolderRefreshController, URLSearchParams, AbortController, console: { ...console, warn: message => warnings.push(message) }, alert() {}, confirm: () => true,
        prompt: () => 'value', setInterval: () => 1, clearInterval() {},
        setTimeout(fn) { timeouts.set(++timerId, fn); return timerId; }, clearTimeout(id) { timeouts.delete(id); },
        fetch: async (url, options) => {
            const { action, params = {} } = options?.body ? JSON.parse(options.body) : {};
            if (action === 'capabilities') return { ok: true, json: async () => ({ apiVersion: 2, actions: ['get-object-tagging'] }) };
            if (action === 'list-objects-v2') {
                const folder = params.Prefix || ''; calls.push(folder);
                const raw = await listFetch(folder, options, new URLSearchParams({ cursor: params.ContinuationToken || '' }));
                const items = Array.isArray(raw) ? raw : raw.items;
                for (const item of items) if (item.tags) knownTags.set(item.name, item.tags);
                const data = { KeyCount: items.length, Contents: items.filter(i => i.type === 'file').map(i => ({ Key: i.name, Size: i.size, LastModified: i.last_modified })),
                    CommonPrefixes: items.filter(i => i.type === 'folder').map(i => ({ Prefix: i.name })), IsTruncated: !!raw.next_token, NextContinuationToken: raw.next_token };
                return { ok: true, json: async () => data };
            }
            if (action === 'get-object-tagging') {
                const key = params.Key; tagCalls.push(key);
                const tags = knownTags.get(key) || await tagFetch(key);
                return { ok: true, json: async () => ({ TagSet: Object.entries(tags).map(([Key, Value]) => ({ Key, Value })) }) };
            }
            if (action === 'remove-object-tag') return { ok: true, json: async () => ({ success: true, TagSet: [] }) };
            return { ok: true, json: async () => ({}) };
        }
    });
    const html = fs.readFileSync(require.resolve('../index.html'), 'utf8');
    const script = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)][0][1];
    vm.runInContext(script, ctx);
    return { ctx, doc, calls, tagCalls, warnings, timeouts, listeners, location, navigate: async folder => {
        location.hash = '#folder=' + encodeURIComponent(folder); await win.onhashchange();
    } };
}
const file = name => ({ name, type: 'file', size: 2, last_modified: '2026-09-08T00:00:00Z', tags: { status: 'finished' } });

test('download tag denial is reported separately without reloading the folder', async () => {
    const p = page({ listFetch: async () => [file('test.txt')] }); await tick();
    const alerts = [], actions = [];
    p.ctx.alert = text => alerts.push(text);
    p.ctx.apiCall = async action => {
        actions.push(action);
        if (action === 'get-download-url') return { url: 'https://example.test/download' };
        throw new Error('Writes outside test prefix are disabled');
    };
    await p.ctx.downloadFile('test.txt');
    assert.equal(p.location.href, 'https://example.test/download');
    assert.deepEqual(actions, ['get-download-url', 'set-object-tag']);
    assert.match(alerts[0], /^Скачивание запущено, но отметка downloadStatus не сохранена:/);
    assert.equal(p.calls.length, 1);
});

test('missing download URL never attempts a tag mutation', async () => {
    const p = page(); await tick();
    const alerts = [], actions = [];
    p.ctx.alert = text => alerts.push(text);
    p.ctx.console.error = () => {};
    p.ctx.apiCall = async action => { actions.push(action); return {}; };
    await p.ctx.downloadFile('test.txt');
    assert.deepEqual(actions, ['get-download-url']);
    assert.equal(p.location.href, undefined);
    assert.match(alerts[0], /^Не удалось начать скачивание:/);
});

test('page renders empty folders successfully and starts the timer', async () => {
    const p = page(); await tick();
    assert.equal(p.doc.getElementById('status').textContent, '');
    assert.equal(p.doc.getElementById('refresh-btn').disabled, true);
    assert.equal(p.doc.getElementById('refresh-timer').textContent, 120);
});

test('filters and sorting only re-render cached data and preserve settings on refresh', async () => {
    const p = page({ listFetch: async () => [file('beta'), file('alpha')] }); await tick();
    p.ctx.updateNameFilter('alpha'); p.ctx.updateDateFilter('2026');
    p.ctx.toggleSort('name'); p.ctx.addFilter('status', 'finished');
    assert.equal(p.calls.length, 1);
    assert.equal(p.doc.getElementById('file-list').children.filter(r => r.style.display !== 'none').length, 1);
    await p.ctx.manualRefresh();
    assert.equal(p.calls.length, 1);
    assert.equal(p.doc.getElementById('filter-name').value, 'alpha');
    assert.equal(p.doc.getElementById('filter-date').value, '2026');
    assert.equal(p.doc.getElementById('file-list').children.filter(r => r.style.display !== 'none').length, 1);
    p.ctx.clearFilters(); assert.equal(p.calls.length, 1);
    assert.equal(p.doc.getElementById('file-list').children.length, 2);
});

test('late A response does not replace B and each folder gets its own cooldown', async () => {
    const a = deferred();
    const p = page({ initialFolder: 'A/', listFetch: f => f === 'A/' ? a.promise : [file('B/beta')] });
    await tick(); await p.navigate('B/');
    a.resolve([file('A/alpha')]); await tick();
    const rows = p.doc.getElementById('file-list').children;
    assert.match(rows[1].children[0].children[0].textContent, /beta/);
    assert.equal(p.doc.getElementById('refresh-btn').dataset.state, 'cooldown');
    await p.navigate('A/'); await tick(); assert.equal(p.calls.length, 2);
    assert.match(p.doc.getElementById('file-list').children[1].children[0].children[0].textContent, /alpha/);
});

test('rapid manual clicks during initial load do not duplicate network calls', async () => {
    const wait = deferred(); const p = page({ listFetch: () => wait.promise });
    const a = p.ctx.manualRefresh(); const b = p.ctx.manualRefresh(); await tick();
    assert.equal(p.calls.length, 1); assert.equal(p.doc.getElementById('refresh-btn').disabled, true);
    wait.resolve([file('alpha')]); await Promise.all([a, b]);
    assert.equal(p.doc.getElementById('file-list').children.length, 1);
});

test('network timeout releases loading UI and offers retry without a new cooldown', async () => {
    let fail = true;
    const p = page({ listFetch: (_, opts) => fail ? new Promise((resolve, reject) => {
        opts.signal.addEventListener('abort', () => reject(new Error('timeout')));
    }) : [] });
    await tick(); [...p.timeouts.values()].forEach(fn => fn()); await tick();
    assert.equal(p.doc.getElementById('refresh-btn').dataset.state, 'error');
    assert.equal(p.doc.getElementById('refresh-btn').disabled, false);
    fail = false; await p.ctx.manualRefresh();
    assert.equal(p.doc.getElementById('refresh-btn').dataset.state, 'cooldown');
});

test('a successful tag mutation updates only its row and rechecks the tag filter', async () => {
    const p = page({ listFetch: async () => [file('alpha'), file('beta')], tagFetch: async () => ({}) }); await tick();
    p.ctx.addFilter('status', 'finished');
    const rows = p.doc.getElementById('file-list').children;
    const otherCell = rows[1].children[0];
    await p.ctx.removeTag('alpha', 'status');
    assert.equal(p.calls.length, 1);
    assert.deepEqual(p.tagCalls, ['alpha', 'beta']);
    assert.equal(rows[0].style.display, 'none');
    assert.equal(rows[1].children[0], otherCell);
});

test('metadata pages finish before sequential tags; first row appears before the second response', async () => {
    const second = deferred();
    const p = page({ listFetch: async (_, __, params) => params.get('cursor') ?
        { items: [{ ...file('b.json'), tags: undefined }], next_token: null } :
        { items: [{ ...file('a.txt'), tags: undefined }], next_token: 'next' },
        tagFetch: key => key === 'b.json' ? second.promise : {} });
    await tick();
    assert.equal(p.calls.length, 2);
    assert.deepEqual(p.tagCalls, ['a.txt', 'b.json']);
    const rows = p.doc.getElementById('file-list').children;
    assert.equal(rows[0].style.display, '');
    assert.equal(rows[1].style.display, 'none');
    assert.equal(typeof rows[0].children[0].children[0].onclick, 'function');
    second.resolve({}); await tick();
    assert.equal(rows[1].style.display, '');
});

test('metadata filters avoid tag calls for excluded files and tag filters hide nonmatching rows', async () => {
    const wait = deferred();
    const p = page({ listFetch: () => wait.promise, tagFetch: async () => ({ status: 'other' }) });
    p.ctx.updateNameFilter('alpha'); p.ctx.addFilter('status', 'finished');
    wait.resolve({ items: ['alpha', 'beta'].map(name => ({ ...file(name), tags: undefined })) });
    await tick();
    assert.deepEqual(p.tagCalls, ['alpha']);
    assert.equal(p.doc.getElementById('file-list').children[0].style.display, 'none');
});

test('a late tag response from a previous folder cannot alter the current folder', async () => {
    const wait = deferred();
    const p = page({ initialFolder: 'A/', listFetch: async folder => ({ items: [{ ...file(folder + 'x'), tags: undefined }] }),
        tagFetch: key => key.startsWith('A/') ? wait.promise : {} });
    await tick(); await p.navigate('B/'); await tick();
    const rows = p.doc.getElementById('file-list').children;
    wait.resolve({}); await tick();
    assert.equal(p.doc.getElementById('file-list').children, rows);
    assert.match(rows[1].children[0].children[0].textContent, /x/);
});

test('tag requests follow metadata sorting and a failed row can retry independently', async () => {
    const wait = deferred(); let fail = true;
    const p = page({ listFetch: () => wait.promise, tagFetch: async key => {
        if (key === 'alpha' && fail) throw new Error('offline');
        return {};
    } });
    p.ctx.toggleSort('name');
    wait.resolve({ items: ['beta', 'alpha'].map(name => ({ ...file(name), tags: undefined })) });
    await tick();
    assert.deepEqual(p.tagCalls, ['alpha', 'beta']);
    const rows = p.doc.getElementById('file-list').children;
    assert.match(rows[0].children[0].textContent, /теги не загружены/);
    const unaffected = rows[1].children[0];
    fail = false;
    rows[0].children[0].children[0].onclick(); await tick();
    assert.deepEqual(p.tagCalls, ['alpha', 'beta', 'alpha']);
    assert.equal(p.calls.length, 1);
    assert.equal(rows[1].children[0], unaffected);
    assert.equal(rows[0].children.length, 5);
});

test('SignJS expand/collapse cannot reset the refresh state', async () => {
    const p = page(); await tick();
    const frame = p.doc.getElementById('signjs-widget');
    const receive = p.listeners.message[0];
    receive({ origin: p.location.origin, source: frame.contentWindow, data: { type: 'signjs:layout', compact: false } });
    assert.equal(frame.style.width, '760px');
    assert.equal(p.doc.getElementById('refresh-btn').disabled, true);
    receive({ origin: p.location.origin, source: frame.contentWindow, data: { type: 'signjs:layout', compact: true } });
    assert.equal(frame.style.width, '72px'); assert.equal(p.calls.length, 1);
});

test('starts with 20 rows and fetches the next page tags only on navigation', async () => {
    const p = page({ listFetch: async () => Array.from({ length: 45 }, (_, i) => file(`file${i}`)) });
    await tick();
    const shown = () => p.doc.getElementById('file-list').children.filter(r => r.style.display !== 'none').length;
    assert.equal(shown(), 20); assert.equal(p.tagCalls.length, 20);
    p.ctx.changePage(1); await tick();
    assert.equal(shown(), 20); assert.equal(p.tagCalls.length, 40);
    p.ctx.changePage(1); await tick();
    assert.equal(shown(), 5); assert.equal(p.tagCalls.length, 45);
    assert.equal(p.doc.getElementById('page-next').disabled, true);
    p.ctx.changePage(-1); await tick();
    assert.equal(shown(), 20); assert.equal(p.tagCalls.length, 45);
});

test('numbered pagination jumps directly to the last page without reading intermediate tags', async () => {
    const p = page({ listFetch: async () => Array.from({ length: 636 }, (_, i) => file(`file${i}`)) });
    await tick();
    const numbers = () => p.doc.getElementById('page-numbers').children;
    assert.ok(numbers().some(el => el.textContent === '…'));
    assert.equal(numbers().find(el => el.textContent === '1')['aria-current'], 'page');
    numbers().find(el => el.textContent === '32').onclick();
    await tick();
    assert.equal(p.tagCalls.length, 36); // first 20 + last 16, no intermediate tags
    assert.equal(p.calls.length, 1);
    assert.equal(p.doc.getElementById('file-list').children.filter(r => r.style.display !== 'none').length, 16);
    assert.equal(numbers().find(el => el.textContent === '32')['aria-current'], 'page');
    assert.equal(p.doc.getElementById('page-next').disabled, true);
    numbers().find(el => el.textContent === '1').onclick();
    await tick();
    assert.equal(p.tagCalls.length, 36);
    assert.equal(p.doc.getElementById('page-prev').disabled, true);
});

test('service folders are hidden before pagination and remain hidden after Clear All', async () => {
    const p = page({ initialFolder: 'parent/', listFetch: async () => [
        { name: 'parent/_api-tests/', type: 'folder' },
        { name: 'parent/.cache/', type: 'folder' },
        { name: 'parent/visible/', type: 'folder' }, file('parent/_keep.txt')
    ] });
    await tick();
    assert.equal(p.doc.getElementById('file-list').children.length, 3); // parent link + folder + file
    assert.match(p.doc.getElementById('page-label').textContent, /Всего объектов: 2/);
    p.ctx.clearFilters(); await tick();
    assert.equal(p.doc.getElementById('file-list').children.length, 3);
});

test('SignJS timeout is visible and logged; trusted ready message restores widget', async () => {
    const p = page(); await tick();
    [...p.timeouts.values()].forEach(fn => fn());
    assert.equal(p.doc.getElementById('signjs-widget').dataset.health, 'error');
    assert.ok(p.warnings.some(message => message.includes('SignJS')));
    p.listeners.message[0]({ origin: p.location.origin, source: p.doc.getElementById('signjs-widget').contentWindow,
        data: { type: 'signjs:layout', compact: true } });
    assert.equal(p.doc.getElementById('signjs-health').hidden, true);
});
