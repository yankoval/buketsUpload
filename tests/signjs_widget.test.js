const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const html = fs.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8');

test('embeds SignJS in compact production mode', () => {
    assert.match(html, /id="signjs-widget"/);
    assert.match(html, /src="cloud-sign\.html\?mode=embedded"/);
    assert.match(html, /width="72"/);
    assert.match(html, /height="72"/);
});

test('accepts layout messages only from the embedded same-origin frame', () => {
    assert.match(html, /event\.origin !== window\.location\.origin/);
    assert.match(html, /event\.source !== frame\.contentWindow/);
    assert.match(html, /event\.data\?\.type !== SIGNJS_LAYOUT_MESSAGE/);
});

test('caps the expanded widget size to the current viewport', () => {
    assert.match(html, /Math\.min\(signJsLayout\.width, maxWidth\)/);
    assert.match(html, /Math\.min\(signJsLayout\.height, maxHeight\)/);
    assert.match(html, /window\.addEventListener\('resize', applySignJsLayout\)/);
});
