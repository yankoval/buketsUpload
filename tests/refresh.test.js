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

function page({ initialFolder = '', listFetch = async () => [], local = storage(), session = storage() } = {}) {
    const elements = new Map();
    function element() {
        return { style: {}, dataset: {}, children: [], value: '', textContent: '', disabled: false,
            contentWindow: {}, setAttribute(k, v) { this[k] = v; },
            appendChild(child) { this.children.push(child); },
            set innerHTML(v) { this.html = v; this.children = []; }, get innerHTML() { return this.html || ''; } };
    }
    const doc = { getElementById(id) { if (!elements.has(id)) elements.set(id, element()); return elements.get(id); }, createElement: element };
    const location = { hash: initialFolder ? '#folder=' + encodeURIComponent(initialFolder) : '', pathname: '/prod/index.html', origin: 'https://example.test' };
    const listeners = {}; const timeouts = new Map(); let timerId = 0; const calls = [];
    const win = { location, innerWidth: 1024, innerHeight: 768, addEventListener: (name, fn) => (listeners[name] ??= []).push(fn) };
    const ctx = vm.createContext({ document: doc, window: win, location, localStorage: local, sessionStorage: session,
        FolderRefreshController, URLSearchParams, AbortController, console, alert() {}, confirm: () => true,
        prompt: () => 'value', setInterval: () => 1, clearInterval() {},
        setTimeout(fn) { timeouts.set(++timerId, fn); return timerId; }, clearTimeout(id) { timeouts.delete(id); },
        fetch: async (url, options) => {
            const parsed = new URL(url);
            if (parsed.searchParams.has('list')) {
                const folder = parsed.searchParams.get('folder') || ''; calls.push(folder);
                const items = await listFetch(folder, options);
                return { ok: true, json: async () => items };
            }
            if (options?.method === 'POST') return { ok: true, json: async () => ({ success: true }) };
            return { ok: true, json: async () => ({}) };
        }
    });
    const html = fs.readFileSync(require.resolve('../index.html'), 'utf8');
    const script = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)][0][1];
    vm.runInContext(script, ctx);
    return { ctx, doc, calls, timeouts, listeners, location, navigate: async folder => {
        location.hash = '#folder=' + encodeURIComponent(folder); await win.onhashchange();
    } };
}
const file = name => ({ name, type: 'file', size: 2, last_modified: '2026-09-08T00:00:00Z', tags: { status: 'finished' } });

test('page renders empty folders successfully and starts the timer', async () => {
    const p = page(); await tick();
    assert.equal(p.doc.getElementById('status').textContent, 'Bucket is empty.');
    assert.equal(p.doc.getElementById('refresh-btn').disabled, true);
    assert.equal(p.doc.getElementById('refresh-timer').textContent, 120);
});

test('filters and sorting only re-render cached data and preserve settings on refresh', async () => {
    const p = page({ listFetch: async () => [file('beta'), file('alpha')] }); await tick();
    p.ctx.updateNameFilter('alpha'); p.ctx.updateDateFilter('2026');
    p.ctx.toggleSort('name'); p.ctx.addFilter('status', 'finished');
    assert.equal(p.calls.length, 1);
    assert.equal(p.doc.getElementById('file-list').children.length, 1);
    await p.ctx.manualRefresh();
    assert.equal(p.calls.length, 1);
    assert.equal(p.doc.getElementById('filter-name').value, 'alpha');
    assert.equal(p.doc.getElementById('filter-date').value, '2026');
    assert.equal(p.doc.getElementById('file-list').children.length, 1);
    p.ctx.clearFilters(); assert.equal(p.calls.length, 1);
    assert.equal(p.doc.getElementById('file-list').children.length, 2);
});

test('late A response does not replace B and each folder gets its own cooldown', async () => {
    const a = deferred();
    const p = page({ initialFolder: 'A/', listFetch: f => f === 'A/' ? a.promise : [file('B/beta')] });
    await tick(); await p.navigate('B/');
    a.resolve([file('A/alpha')]); await tick();
    const rows = p.doc.getElementById('file-list').children;
    assert.match(rows[1].children[0].innerHTML, /beta/);
    assert.equal(p.doc.getElementById('refresh-btn').dataset.state, 'cooldown');
    await p.navigate('A/'); assert.equal(p.calls.length, 2);
    assert.match(p.doc.getElementById('file-list').children[1].children[0].innerHTML, /alpha/);
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

test('a successful tag mutation refreshes once even during cooldown', async () => {
    const p = page({ listFetch: async () => [file('alpha')] }); await tick();
    await p.ctx.removeTag('alpha', 'status');
    assert.equal(p.calls.length, 2);
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
