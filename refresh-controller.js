/* Folder-scoped list cache and manual refresh guard, shared by UI and tests. */
(function (root) {
    class FolderRefreshController {
        constructor({ fetchItems, storage, cacheStorage, scope, now = Date.now, onChange = () => {}, cooldownMs = 120000 }) {
            Object.assign(this, { fetchItems, storage, cacheStorage, scope, now, onChange, cooldownMs });
            this.cache = new Map();
            this.pending = new Map();
            this.deadlines = new Map();
        }

        storageKey(folder) { return `bucketBrowser:refresh:${this.scope}:${folder}`; }

        cached(folder) {
            if (!this.cache.has(folder)) {
                try {
                    const saved = JSON.parse(this.cacheStorage?.getItem(this.storageKey(folder)) || 'null');
                    if (saved && Array.isArray(saved.items) && saved.expires > this.now()) this.cache.set(folder, saved.items);
                } catch (_) { /* Ignore damaged or unavailable session cache. */ }
            }
            return this.cache.get(folder);
        }

        invalidate(folder) {
            this.cache.delete(folder);
            try { this.cacheStorage?.removeItem(this.storageKey(folder)); } catch (_) { /* optional */ }
        }

        remaining(folder) {
            let deadline = this.deadlines.get(folder) || 0;
            try {
                // Retain timers from the previously published Yin-Yang interface.
                const stored = this.storage.getItem(this.storageKey(folder));
                const legacy = stored === null ? this.storage.getItem(`refreshTimer_${folder}`) : null;
                const value = Number(stored ?? legacy);
                if (Number.isFinite(value)) deadline = Math.max(deadline, value);
            } catch (_) { /* The in-memory guard still works if storage is unavailable. */ }
            return Math.max(0, Math.ceil((deadline - this.now()) / 1000));
        }

        state(folder) {
            return { loading: this.pending.has(folder), remaining: this.remaining(folder) };
        }

        async load(folder, { manual = false, force = false } = {}) {
            if (this.pending.has(folder)) return this.pending.get(folder);
            this.cached(folder);
            if (manual && this.remaining(folder) > 0) return this.cache.get(folder) ?? null;
            if (!manual && !force && this.cache.has(folder) && this.remaining(folder) > 0) {
                return this.cache.get(folder);
            }
            // Register synchronously, before fetchItems can yield or another click can arrive.
            const request = Promise.resolve().then(() => this.fetchItems(folder)).then(items => {
                if (!Array.isArray(items)) throw new Error('Invalid file list response');
                this.cache.set(folder, items);
                const deadline = this.now() + this.cooldownMs;
                this.deadlines.set(folder, deadline);
                try { this.storage.setItem(this.storageKey(folder), String(deadline)); } catch (_) { /* optional */ }
                try { this.cacheStorage?.setItem(this.storageKey(folder), JSON.stringify({ items, expires: deadline })); } catch (_) { /* optional */ }
                return items;
            }).finally(() => {
                this.pending.delete(folder);
                this.onChange();
            });
            this.pending.set(folder, request);
            this.onChange();
            return request;
        }
    }
    if (typeof module !== 'undefined' && module.exports) module.exports = { FolderRefreshController };
    else root.FolderRefreshController = FolderRefreshController;
})(globalThis);
