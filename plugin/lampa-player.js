/*
 * Lampa Player для iPhone — плагин для Lampa.
 * https://github.com/lardan099/lampa-player-plugin
 *
 * 1. Когда Lampa открывает видео во «внешнем плеере Infuse», плагин подменяет ссылку на lampaplayer://
 *    и передаёт плееру всё сразу: серии сезона, все субтитры, метки пропуска заставок и рекламы,
 *    превью кадров, позицию и ключ отметки просмотра (timeline hash). Работает и для онлайна, и для торрентов.
 * 2. Когда вы возвращаетесь в Lampa, плагин забирает у плеера позиции просмотра
 *    (http://127.0.0.1:8090/lampaplayer/progress) и ставит отметки в Lampa — с синхронизацией в CUB.
 *
 * В Lampa: Настройки → Плеер → тип плеера «Infuse» (и для торрентов тоже).
 */
(function () {
    'use strict';

    if (window.__lampa_player_ios) return;
    window.__lampa_player_ios = true;

    var VERSION = '1.2.0';
    var API = 'http://127.0.0.1:8090/lampaplayer';
    var MAX_URL = 60000;

    function isApple() {
        try {
            if (window.Lampa && Lampa.Platform && (Lampa.Platform.is('apple') || Lampa.Platform.is('apple_tv'))) return true;
        } catch (e) {}
        return /iPhone|iPad|iPod/i.test(navigator.userAgent || '');
    }

    function clean(text) {
        return String(text || '').replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ').trim();
    }

    function playUrl(url) {
        url = String(url || '').replace('&preload', '&play');
        try {
            if (window.Lampa && Lampa.Torserver && typeof Lampa.Torserver.toPlayUrl === 'function') {
                return Lampa.Torserver.toPlayUrl(url);
            }
        } catch (e) {}
        return url;
    }

    function sameUrl(a, b) {
        if (!a || !b) return false;
        var strip = function (u) { return String(u).replace('&preload', '').replace('&play', ''); };
        return strip(a) === strip(b);
    }

    function subtitles(list) {
        if (!Array.isArray(list)) return [];
        return list.filter(function (s) { return s && typeof s.url === 'string' && s.url; })
            .map(function (s) { return { u: s.url, l: clean(s.label || s.title || '') }; });
    }

    function segments(seg) {
        if (!seg || typeof seg !== 'object') return null;
        var pick = function (arr) {
            return (Array.isArray(arr) ? arr : []).filter(function (x) { return x && x.end > x.start; })
                .map(function (x) { return [Number(x.start) || 0, Number(x.end) || 0]; });
        };
        var out = { a: pick(seg.ad), s: pick(seg.skip), d: Number(seg.duration_ms) || 0 };
        return out.a.length || out.s.length ? out : null;
    }

    function itemFrom(src) {
        var timeline = src.timeline || {};
        var item = { u: playUrl(src.url), t: clean(src.title || src.path || '') };
        var subs = subtitles(src.subtitles);
        if (subs.length) item.s = subs;
        var seg = segments(src.segments);
        if (seg) item.g = seg;
        var thumbs = src.thumbnails_vtt || src.thumbnails;
        if (typeof thumbs === 'string' && thumbs) item.v = thumbs;
        // Перевод, выбранный в Lampa: у онлайн-потоков дорожка одна и без названия.
        var voice = [src.voice_name, src.translate_name, src.translation, src.voice].filter(function (v) {
            return typeof v === 'string' && v && v.length <= 60 && v.indexOf('<') < 0;
        })[0];
        if (voice) item.a = clean(voice);
        if (timeline.hash) {
            item.h = String(timeline.hash);
            if (timeline.time > 0) item.p = Math.floor(timeline.time);
        }
        return item;
    }

    function merge(base, extra) {
        for (var key in extra) {
            if (extra[key] !== undefined && extra[key] !== '' && !(Array.isArray(extra[key]) && !extra[key].length)) {
                if (base[key] === undefined || base[key] === '' || key === 'p' || key === 'h') base[key] = extra[key];
            }
        }
        return base;
    }

    function card(data) {
        var c = data.card || data.movie;
        try {
            if (!c && Lampa.Activity && Lampa.Activity.active()) c = Lampa.Activity.active().card || Lampa.Activity.active().movie;
        } catch (e) {}
        c = c || {};
        return {
            title: clean(c.title || c.name || ''),
            original: clean(c.original_title || c.original_name || ''),
            poster: c.poster_path ? 'https://image.tmdb.org/t/p/w300' + c.poster_path : ''
        };
    }

    function encode(payload) {
        var json = JSON.stringify(payload);
        var b64 = btoa(unescape(encodeURIComponent(json)));
        return b64.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
    }

    function build(data) {
        var list = (Array.isArray(data.playlist) ? data.playlist : []).filter(function (a) {
            return a && !a.separator && typeof a.url === 'string';
        });
        if (!list.length) list = [data];

        var index = 0;
        for (var i = 0; i < list.length; i++) {
            if (sameUrl(list[i].url, data.url)) { index = i; break; }
        }

        var items = list.map(itemFrom);
        // У открытой серии самые свежие данные — в самом data (позиция, сегменты, субтитры).
        items[index] = merge(items[index], itemFrom(data));

        var payload = { v: 1, i: index, c: card(data), items: items };
        var url = 'lampaplayer://lampa?d=' + encode(payload);

        // Слишком длинно — оставляем окно серий вокруг текущей, потом выкидываем превью.
        var spans = [20, 10, 5, 2, 0];
        for (var k = 0; k < spans.length && url.length > MAX_URL; k++) {
            var from = Math.max(0, index - spans[k]), to = Math.min(items.length, index + spans[k] + 1);
            payload = { v: 1, i: index - from, c: payload.c, items: items.slice(from, to) };
            url = 'lampaplayer://lampa?d=' + encode(payload);
        }
        if (url.length > MAX_URL) {
            payload.items.forEach(function (it) { delete it.v; });
            url = 'lampaplayer://lampa?d=' + encode(payload);
        }
        return url;
    }


    // --- Прогресс обратно в Lampa ---

    // Lampa хранит хэши отметок числами — отдаём так же, иначе синхронизация с аккаунтом может не узнать запись.
    function lampaHash(h) {
        return /^\d+$/.test(String(h)) ? Number(h) : h;
    }

    /** Ставит отметки просмотра. Список: [{h, t, d, pc}]. Возвращает число применённых. */
    function applyProgress(list) {
        if (!window.Lampa || !Lampa.Timeline) return -1;
        var count = 0;
        (Array.isArray(list) ? list : []).forEach(function (p) {
            if (!p || !p.h) return;
            Lampa.Timeline.update({
                hash: lampaHash(p.h),
                percent: Math.max(0, Math.min(100, Math.round(p.pc || 0))),
                time: Math.round(p.t || 0),
                duration: Math.round(p.d || 0)
            });
            count++;
        });
        if (count) {
            try { Lampa.Noty.show('Lampa Player: отметки просмотра обновлены (' + count + ')'); } catch (e) {}
        }
        return count;
    }
    // Встроенная Lampa (внутри приложения) ставит отметки напрямую через этот вызов.
    window.__lampaPlayerApplyProgress = applyProgress;

    var syncing = false;

    function sync() {
        if (syncing || !window.fetch || !window.Lampa || !Lampa.Timeline) return;
        syncing = true;
        fetch(API + '/progress', { cache: 'no-store' })
            .then(function (r) { return r.json(); })
            .then(function (list) {
                var done = (Array.isArray(list) ? list : []).filter(function (p) { return p && p.h; })
                    .map(function (p) { return String(p.h); });
                if (applyProgress(list) > 0 && done.length) {
                    fetch(API + '/ack?h=' + encodeURIComponent(done.join(',')), { cache: 'no-store' }).catch(function () {});
                }
            })
            .catch(function () {})
            .then(function () { syncing = false; });
    }

    // --- Встроенная Lampa: связь с приложением ---

    var native = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.lampaPlayer;

    function post(message) {
        try { if (native) native.postMessage(message); } catch (e) {}
    }

    function addMenu() {
        if (!native || !window.$) return;
        if ($('.menu [data-lampa-player]').length) return;
        var icon = '<svg width="24" height="24" viewBox="0 0 24 24" fill="currentColor"><path d="M8 5.14v13.72a1 1 0 0 0 1.52.85l10.6-6.86a1 1 0 0 0 0-1.7L9.52 4.29A1 1 0 0 0 8 5.14z"/></svg>';
        var btn = $('<li class="menu__item selector" data-lampa-player="1"><div class="menu__ico">' + icon +
            '</div><div class="menu__text">Lampa Player</div></li>');
        btn.on('hover:enter', function () { post({ action: 'settings' }); });
        $('.menu .menu__list').eq(0).append(btn);
        post({ action: 'menu' });
    }

    // --- Запуск ---

    var started = false;

    function start() {
        if (started || !isApple()) return;
        started = true;

        Lampa.Player.listener.follow('infuse_build_url', function (e) {
            try {
                if (e && e.data && typeof e.setUrl === 'function') e.setUrl(build(e.data));
            } catch (err) {
                console.log('Lampa Player', 'build url failed', err);
            }
        });

        document.addEventListener('visibilitychange', function () {
            if (!document.hidden) { sync(); setTimeout(sync, 2500); }
        });
        window.addEventListener('focus', sync);
        setTimeout(sync, 3000);

        addMenu();
        post({ action: 'ready', version: VERSION, ua: navigator.userAgent });
        console.log('Lampa Player', 'plugin ' + VERSION + ' ready' + (native ? ' (embedded)' : ''));
    }

    // Встроенный скрипт может выполниться раньше, чем Lampa загрузится — ждём её до минуты.
    var listening = false;
    function boot(tries) {
        if (started) return;
        if (window.appready && window.Lampa && Lampa.Player && Lampa.Player.listener) return start();
        if (!listening && window.Lampa && Lampa.Listener) {
            listening = true;
            Lampa.Listener.follow('app', function (e) { if (e.type === 'ready') start(); });
        }
        if (tries < 120) setTimeout(function () { boot(tries + 1); }, 500);
    }
    boot(0);
})();
