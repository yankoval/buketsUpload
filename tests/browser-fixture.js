// Browser-only fixture served by preview.py?fixture=1. Never published with the app.
const originalFetch = window.fetch.bind(window);
window.fetch = async (url, options) => {
    if (url !== 'https://fixture.invalid/api') return originalFetch(url, options);
    const { action, params } = JSON.parse(options.body);
    const answer = data => ({ ok: true, json: async () => data });
    if (action === 'capabilities') return answer({ apiVersion: 2, actions: ['get-object-tagging'] });
    if (action === 'get-download-url') return answer({});
    if (action === 'list-objects-v2') {
        await new Promise(resolve => setTimeout(resolve, 600));
        return answer({ KeyCount: 45, Contents: Array.from({ length: 45 }, (_, i) => ({
            Key: `demo-${String(i + 1).padStart(2, '0')}.json`, Size: 1234, LastModified: '2026-09-18T10:00:00Z'
        })), CommonPrefixes: [], IsTruncated: false });
    }
    if (action === 'get-object-tagging') {
        await new Promise(resolve => setTimeout(resolve, 1000));
        return answer({ TagSet: [{ Key: 'check', Value: 'finished' }] });
    }
    return { ok: false, status: 403, json: async () => ({ error: 'Fixture: mutations disabled' }) };
};
