// Прогон плагина в Node на моке Lampa: node plugin/test-plugin.js
const fs = require('fs');
const path = require('path');
const assert = require('assert');

const handlers = {};
const updates = [];
let fetched = [];

global.navigator = { userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)' };
global.document = { hidden: false, addEventListener() {} };
global.window = global;
global.window.addEventListener = () => {};
global.appready = true;
global.btoa = (s) => Buffer.from(s, 'binary').toString('base64');
global.unescape = unescape;
global.setTimeout = () => {};
global.fetch = (url) => {
    fetched.push(url);
    if (url.includes('/progress')) {
        return Promise.resolve({ json: () => Promise.resolve([{ h: '123456', t: 754.4, d: 1855, pc: 40.6 }]) });
    }
    return Promise.resolve({ json: () => Promise.resolve({}) });
};
global.Lampa = {
    Platform: { is: (p) => p === 'apple' },
    Torserver: { toPlayUrl: (u) => u },
    Activity: { active: () => ({ card: { name: 'Тед Лассо', original_name: 'Ted Lasso', poster_path: '/abc.jpg' } }) },
    Player: { listener: { follow: (name, fn) => { handlers[name] = fn; } } },
    Timeline: { update: (p) => updates.push(p) },
    Noty: { show() {} },
    Listener: { follow() {} },
};

eval(fs.readFileSync(path.join(__dirname, 'lampa-player.js'), 'utf8'));
assert(handlers.infuse_build_url, 'hook registered');

function decode(url) {
    const d = new URL(url.replace('lampaplayer://', 'http://x/')).searchParams.get('d');
    const b64 = d.replace(/-/g, '+').replace(/_/g, '/');
    return JSON.parse(Buffer.from(b64, 'base64').toString('utf8'));
}

// Онлайн (MODS): плейлист с сегментами и субтитрами.
const episodes = [1, 2, 3].map((n) => ({
    title: 'Серия ' + n + ' / ',
    url: 'https://api.lampa.stream/on/play/X' + n + '/Ted.Lasso.S01E0' + n + '_hdr?play',
    segments: { ad: [], skip: [{ start: 100 + n, end: 120 + n }], duration_ms: 1800000 },
    subtitles: [{ label: 'RUS - [FORCED]', url: 'https://s/f' + n + '.vtt' }, { label: 'ENG', url: 'https://s/e' + n + '.vtt' }],
    thumbnails_vtt: 'https://api.lampa.stream/thumbs/' + n + '.vtt',
    timeline: { hash: 1000 + n, time: n === 2 ? 300 : 0 },
}));
let result;
handlers.infuse_build_url({ data: Object.assign({}, episodes[1], { playlist: episodes }), setUrl: (u) => { result = u; } });
assert(result.startsWith('lampaplayer://lampa?d='), 'url built');
let payload = decode(result);
assert.strictEqual(payload.i, 1);
assert.strictEqual(payload.items.length, 3);
assert.strictEqual(payload.items[1].p, 300);
assert.strictEqual(payload.items[1].h, '1002');
assert.deepStrictEqual(payload.items[0].g, { a: [], s: [[101, 121]], d: 1800000 });
assert.strictEqual(payload.items[2].s.length, 2);
assert.strictEqual(payload.c.title, 'Тед Лассо');
console.log('online ok, url length', result.length);

// Торрент: ссылки TorrServer, субтитры из раздачи, без сегментов.
const files = [1, 2].map((n) => ({
    title: 'Show.S01E0' + n + '.mkv',
    url: 'http://127.0.0.1:8090/stream/Show.S01E0' + n + '.mkv?link=abc&index=' + n + '&preload',
    subtitles: [{ label: 'Show.S01E0' + n + '.srt', url: 'http://127.0.0.1:8090/stream/x.srt?link=abc&index=9&play' }],
    timeline: { hash: 'h' + n, time: 0 },
}));
handlers.infuse_build_url({ data: Object.assign({}, files[0], { playlist: files }), setUrl: (u) => { result = u; } });
payload = decode(result);
assert(payload.items[0].u.endsWith('&play'), 'preload → play');
assert.strictEqual(payload.items[1].h, 'h2');
console.log('torrent ok');

// Огромный плейлист урезается окном вокруг текущей серии.
const big = Array.from({ length: 200 }, (_, n) => ({ title: 'E' + n, url: 'https://x/' + 'a'.repeat(900) + n, timeline: { hash: n } }));
handlers.infuse_build_url({ data: Object.assign({}, big[150], { playlist: big }), setUrl: (u) => { result = u; } });
payload = decode(result);
assert(result.length <= 60000, 'fits');
assert.strictEqual(payload.items[payload.i].t, 'E150');
console.log('big ok: items', payload.items.length, 'length', result.length);

// Прогресс обратно в Lampa.
(async () => {
    // sync() стартует по таймеру, дёрнем вручную через событие видимости — проще вызвать fetch-цепочку снова:
    fetched = [];
    const visibility = [];
    global.document.addEventListener = (name, fn) => visibility.push(fn);
    // Перезапустить плагин нельзя (защита от двойной загрузки), поэтому повторяем sync через глобальный хук:
    delete global.window.__lampa_player_ios;
    eval(fs.readFileSync(path.join(__dirname, 'lampa-player.js'), 'utf8'));
    visibility[0]();
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));
    assert.deepStrictEqual(updates[0], { hash: '123456', percent: 41, time: 754, duration: 1855 });
    assert(fetched.some((u) => u.includes('/ack?h=123456')), 'ack sent');
    console.log('progress sync ok');
})();
