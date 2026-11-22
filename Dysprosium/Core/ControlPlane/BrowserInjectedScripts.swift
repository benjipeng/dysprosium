import Foundation

/// Isolated registry of domain-agnostic WebKit JavaScript probes injected into `CleanroomWebKitSession`.
/// Keeping injected scripts in one dedicated module separates JS runtime hooks from Swift session state.
enum BrowserInjectedScripts {
    static let snifferMessageHandlerName = "dysprosiumSniffer"

    /// Lightweight anti-adblock bait defuser with zero layout-property monkey-patching
    /// (leaves `offsetHeight`, `offsetWidth`, and `getComputedStyle` untouched for 120 Hz SPA performance).
    static let genericAntiAdblockDefuser = #"""
    (function() {
        if (window.__dysprosiumBaitDefuserInstalled) return;
        window.__dysprosiumBaitDefuserInstalled = true;

        try {
            const lockGlobal = function(name, value) {
                try {
                    Object.defineProperty(window, name, {
                        configurable: true,
                        enumerable: true,
                        get: function() { return value; },
                        set: function() {}
                    });
                } catch (_) {
                    try { window[name] = value; } catch (_) {}
                }
            };

            if (typeof window.canRunAds === 'undefined') window.canRunAds = true;
            if (typeof window.cRAds === 'undefined') window.cRAds = true;
            if (typeof window.xRds === 'undefined') window.xRds = false;
            if (typeof window.isAdBlockActive === 'undefined') window.isAdBlockActive = false;
            if (typeof window.adBlockEnabled === 'undefined') window.adBlockEnabled = false;

            // Defuse `just-detect-adblock` whether its script is blocked (undefined guard)
            // or loaded (attempts to assign `globalThis.justDetectAdblock = ...` and run DOM/net bait).
            const justDetectAdblockStub = Object.freeze({
                detectAnyAdblocker: function() { return Promise.resolve(false); },
                detectDomAdblocker: function() { return Promise.resolve(false); },
                detectBraveShields: function() { return Promise.resolve(false); },
                detectOperaAdblocker: function() { return Promise.resolve(false); },
                isDetected: function() { return false; }
            });
            lockGlobal('justDetectAdblock', justDetectAdblockStub);

            // Defuse `FuckAdBlock` / `BlockAdBlock` constructors and lowercase singletons.
            const noopChain = function() {};
            noopChain.prototype.on = function(detected, fn) {
                if (!detected && typeof fn === 'function') { try { fn(); } catch (_) {} }
                return this;
            };
            noopChain.prototype.onDetected = function() { return this; };
            noopChain.prototype.onNotDetected = function(fn) {
                if (typeof fn === 'function') { try { fn(); } catch (_) {} }
                return this;
            };
            noopChain.prototype.check = function() { return false; };
            noopChain.prototype.emitEvent = function() { return this; };
            noopChain.prototype.clearEvent = function() { return this; };
            noopChain.prototype.setOption = function() { return this; };
            const noopInstance = new noopChain();
            lockGlobal('FuckAdBlock', noopChain);
            lockGlobal('BlockAdBlock', noopChain);
            lockGlobal('fuckAdBlock', noopInstance);
            lockGlobal('blockAdBlock', noopInstance);

            const origFetch = window.fetch;
            if (typeof origFetch === 'function') {
                window.fetch = function(input, init) {
                    const p = origFetch.apply(this, arguments);
                    if (init && init.mode === 'no-cors') {
                        return p.catch(function() {
                            return new Response('', { status: 200 });
                        });
                    }
                    return p;
                };
            }
        } catch (_) {}
    })();
    """#

    /// Low-overhead all-frames (`forMainFrameOnly: false`, `.atDocumentStart`) stream & manifest network/media hook:
    /// - Zero `window.open` override or `touchend` anchor hijacking (native `WKUIDelegate.createWebViewWith` handles popups & OAuth)
    /// - Zero `Element.prototype.setAttribute` or global `JSON.parse` monkey-patching
    /// - Zero unconditional `fetch().clone().text()` on non-media API calls
    /// - JS-side `Set` deduplication before posting IPC messages to Swift
    static let allFramesStreamInterceptor = #"""
    (function() {
        if (window.__dysprosiumHookInstalled) return;
        if (window.location && window.location.href === 'about:blank' && window === window.top) return;
        window.__dysprosiumHookInstalled = true;

        const MEDIA_URL_RE = /https?:\/\/[^\s"'<>\\]+?\.(?:m3u8|mp4|m4v|mpd)(?:[?&][^\s"'<>\\]*)?/gi;
        // Excludes `.ts` segments (discarded by native classifier) to eliminate 40-msg/frame HLS IPC storms.
        const CANDIDATE_RE = /\.(?:m3u8|mp4|m4v|mpd|mov|mkv|webm)(?:[?#&]|$)|mpegurl|master\.txt|r_file=chunklist/i;
        const NON_MEDIA_ASSET_RE = /\.(?:js|mjs|css|woff2?|ttf|otf|svg|ico|vtt|srt)(?:[?#]|$)/i;
        const MEDIA_API_URL_RE = /\.(?:m3u8|mpd)(?:[?#]|$)|playurl|\/player\/|\/video\/|\/stream\/|playlist|\/vod\/|\/hls\/|\/dash\/|bangumi|pgc\/|get_video/i;
        const reportedURLs = new Set();
        const reportedMediaMeta = new Set();
        const reportedMimeEvidence = new Set();
        const reportedManifests = new Set();
        let cachedScriptPoster = '';
        let posterLookupDone = false;
        let resourceObserver = null;

        function hasMediaToken(s) {
            return typeof s === 'string' && s.length >= 16 && (
                s.indexOf('.m3u8') !== -1 ||
                s.indexOf('.mp4') !== -1 ||
                s.indexOf('.m4v') !== -1 ||
                s.indexOf('.mpd') !== -1 ||
                s.indexOf('mpegurl') !== -1 ||
                s.indexOf('master.txt') !== -1
            );
        }

        function findPosterUrl() {
            if (cachedScriptPoster) return cachedScriptPoster;
            if (posterLookupDone) return '';
            posterLookupDone = true;
            try {
                const v = document.querySelector('video[poster]');
                if (v && v.poster) {
                    cachedScriptPoster = new URL(v.poster, window.location.href).href;
                    return cachedScriptPoster;
                }
                const og = document.querySelector('meta[property="og:image"], meta[name="twitter:image"]');
                if (og && og.content) {
                    cachedScriptPoster = new URL(og.content, window.location.href).href;
                    return cachedScriptPoster;
                }
            } catch (_) {}
            return '';
        }

        function resolveBaseHref() {
            try {
                if (window.location && window.location.href && window.location.href.startsWith('http')) {
                    return window.location.href;
                }
                if (document.baseURI && document.baseURI.startsWith('http')) {
                    return document.baseURI;
                }
                if (document.referrer && document.referrer.startsWith('http')) {
                    return document.referrer;
                }
            } catch (_) {}
            return window.location ? window.location.href : '';
        }

        function isVideoMIME(ct) {
            if (!ct) return false;
            const lower = ct.toLowerCase();
            if (lower.includes('mp2t')) return false;
            return lower.startsWith('video/mp4')
                || lower.startsWith('video/webm')
                || lower.startsWith('video/quicktime')
                || lower.startsWith('video/x-matroska')
                || lower.startsWith('video/x-m4v')
                || lower.startsWith('video/ogg')
                || lower.startsWith('audio/mp4')
                || lower.startsWith('audio/mpeg')
                || lower.startsWith('audio/ogg')
                || lower.startsWith('audio/webm')
                || lower.startsWith('audio/aac')
                || lower.startsWith('audio/flac');
        }

        function report(rawUrl, hint, quality, explicitPoster, bypassRegex, extraMeta) {
            try {
                if (!rawUrl || typeof rawUrl !== 'string') return;
                const unescaped = rawUrl.indexOf('\\/') !== -1 ? rawUrl.replace(/\\\//g, '/') : rawUrl;
                const trimmed = unescaped.trim();
                if (!trimmed || trimmed.startsWith('blob:') || trimmed.startsWith('data:') || trimmed.startsWith('javascript:')) return;
                if (bypassRegex) {
                    if (NON_MEDIA_ASSET_RE.test(trimmed)) return;
                } else if (!CANDIDATE_RE.test(trimmed)) {
                    return;
                }
                const baseHref = resolveBaseHref();
                const resolved = new URL(trimmed, baseHref).href;
                if (!resolved.startsWith('http://') && !resolved.startsWith('https://')) return;
                const hasMediaMeta = Boolean(extraMeta && (extraMeta.duration > 0 || extraMeta.height >= 144));
                const hasMimeEvidence = Boolean(extraMeta && typeof extraMeta.mimeType === 'string' && extraMeta.mimeType.length > 0);
                const alreadyReported = reportedURLs.has(resolved);
                // Cap only NEW URLs at 40; already-registered URLs (including #40) still get their
                // single bounded metadata or authoritative MIME upgrade.
                if (!alreadyReported && reportedURLs.size >= 40) return;
                const canUpgradeMeta = hasMediaMeta && !reportedMediaMeta.has(resolved);
                const canUpgradeMime = hasMimeEvidence && !reportedMimeEvidence.has(resolved);
                if (alreadyReported && !canUpgradeMeta && !canUpgradeMime) return;
                reportedURLs.add(resolved);
                if (hasMediaMeta) reportedMediaMeta.add(resolved);
                if (hasMimeEvidence) reportedMimeEvidence.add(resolved);
                if (reportedURLs.size >= 40 && resourceObserver) {
                    try { resourceObserver.disconnect(); } catch (_) {}
                    resourceObserver = null;
                }
                const originVal = (extraMeta && extraMeta.omitOrigin)
                    ? ''
                    : ((window.location && window.location.origin && window.location.origin !== 'null') ? window.location.origin : '');
                const payload = {
                    url: resolved,
                    hint: hint || '',
                    quality: typeof quality === 'number' ? quality : 0,
                    referer: baseHref,
                    origin: originVal,
                    title: document.title || '',
                    poster: explicitPoster || findPosterUrl(),
                    ua: navigator.userAgent || ''
                };
                if (extraMeta) {
                    if (extraMeta.omitOrigin) payload.omitOrigin = true;
                    if (typeof extraMeta.mimeType === 'string' && extraMeta.mimeType) payload.mimeType = extraMeta.mimeType;
                    if (typeof extraMeta.duration === 'number' && Number.isFinite(extraMeta.duration) && extraMeta.duration > 0) {
                        payload.duration = extraMeta.duration;
                    }
                    if (typeof extraMeta.width === 'number' && extraMeta.width > 0) payload.videoWidth = extraMeta.width;
                    if (typeof extraMeta.height === 'number' && extraMeta.height > 0) payload.videoHeight = extraMeta.height;
                }
                window.webkit.messageHandlers.dysprosiumSniffer.postMessage(payload);
            } catch (_) {}
        }

        function reportManifest(rawUrl, text, hint) {
            try {
                if (!rawUrl || typeof text !== 'string' || text.length < 16 || text.length > 524288) return;
                if (reportedManifests.size >= 24) return;
                if (!text.trimStart().startsWith('#EXTM3U')) return;
                const baseHref = resolveBaseHref();
                const resolved = new URL(String(rawUrl), baseHref).href;
                if (reportedManifests.has(resolved)) return;
                reportedManifests.add(resolved);
                reportedURLs.add(resolved);
                window.webkit.messageHandlers.dysprosiumSniffer.postMessage({
                    url: resolved,
                    hint: hint || 'm3u8-manifest',
                    manifestText: text,
                    quality: 0,
                    referer: baseHref,
                    origin: (window.location && window.location.origin !== 'null') ? window.location.origin : '',
                    title: document.title || '',
                    poster: findPosterUrl(),
                    ua: navigator.userAgent || ''
                });
            } catch (_) {}
        }

        function scanRawText(txt, hint) {
            try {
                if (!hasMediaToken(txt) || txt.length > 262144) return;
                const normalized = txt.indexOf('\\/') !== -1 ? txt.replace(/\\\//g, '/') : txt;
                if (!cachedScriptPoster) {
                    const pm = normalized.match(/"(?:i|poster|thumbnailUrl|thumbnail)"\s*:\s*"(https?:\/\/[^"\s\\]+?\.(?:jpg|jpeg|webp|png)(?:\?[^"\s\\]*)?)"/i);
                    if (pm && pm[1]) cachedScriptPoster = pm[1];
                }
                const matches = normalized.match(MEDIA_URL_RE);
                if (matches) {
                    const seenInScan = new Set();
                    for (let i = 0; i < matches.length && seenInScan.size < 20; i++) {
                        const m = matches[i];
                        if (!seenInScan.has(m)) {
                            seenInScan.add(m);
                            report(m, hint, 0, cachedScriptPoster, false);
                        }
                    }
                }
            } catch (_) {}
        }

        function walkObject(node, parentKey, depth, budget) {
            if (!node || depth > 6 || budget.left <= 0) return;
            budget.left--;
            if (typeof node === 'string') {
                if ((node.startsWith('http://') || node.startsWith('https://')) &&
                    (/\.(m3u8|mp4|m4v|mpd)([?&]|$)/i.test(node) || node.indexOf('mpegurl') !== -1 || node.indexOf('master.txt') !== -1)) {
                    const q = parseInt(parentKey, 10);
                    report(node, 'json-tree', (!isNaN(q) && q >= 144 && q <= 4320) ? q : 0, cachedScriptPoster, false);
                }
                return;
            }
            if (typeof node !== 'object') return;
            if (Array.isArray(node)) {
                for (let i = 0; i < node.length && budget.left > 0; i++) {
                    walkObject(node[i], parentKey, depth + 1, budget);
                }
                return;
            }
            if (!cachedScriptPoster) {
                const pCand = node.poster || node.thumbnailUrl || node.i;
                if (typeof pCand === 'string' && /^https?:\/\/.+\.(jpg|jpeg|webp|png)/i.test(pCand)) {
                    cachedScriptPoster = pCand;
                }
            }
            const inferredH = (node.meta && typeof node.meta.h === 'number') ? node.meta.h
                            : (typeof node.height === 'number' ? node.height : (parseInt(parentKey, 10) || 0));
            if (typeof node.url === 'string') {
                report(node.url, 'json-tree', inferredH, cachedScriptPoster, false);
            }
            const keys = Object.keys(node);
            for (let i = 0; i < keys.length && budget.left > 0; i++) {
                const k = keys[i];
                walkObject(node[k], inferredH > 0 ? String(inferredH) : k, depth + 1, budget);
            }
        }

        function inspectMediaElement(el) {
            try {
                if (!el || typeof el !== 'object') return;
                const tag = el.tagName;
                if (tag !== 'VIDEO' && tag !== 'AUDIO') return;
                const vh = (typeof el.videoHeight === 'number' && el.videoHeight >= 144) ? el.videoHeight : 0;
                const vw = (typeof el.videoWidth === 'number' && el.videoWidth >= 144) ? el.videoWidth : 0;
                const dur = (typeof el.duration === 'number' && Number.isFinite(el.duration) && el.duration > 0) ? el.duration : 0;
                const poster = (typeof el.poster === 'string' && el.poster) ? el.poster : '';
                const omitOrigin = !el.crossOrigin;
                const activeMeta = { duration: dur, width: vw, height: vh, omitOrigin: omitOrigin };
                const bareMeta = { omitOrigin: omitOrigin };

                const activeSrc = el.currentSrc || '';
                if (activeSrc) {
                    report(activeSrc, 'video-src', vh, poster, true, activeMeta);
                } else if (el.src) {
                    report(el.src, 'video-src', 0, poster, true, bareMeta);
                }
                if (typeof el.querySelectorAll === 'function') {
                    const sources = el.querySelectorAll('source[src]');
                    for (let i = 0; i < sources.length && i < 6; i++) {
                        const s = sources[i] && (sources[i].src || sources[i].getAttribute('src'));
                        if (!s) continue;
                        const isActiveSource = Boolean(activeSrc && s === activeSrc);
                        report(s, 'video-src', isActiveSource ? vh : 0, poster, true, isActiveSource ? activeMeta : bareMeta);
                    }
                }
            } catch (_) {}
        }

        window.__dysprosiumScanMediaElements = function() {
            try {
                const mediaEls = document.querySelectorAll('video, audio');
                for (let i = 0; i < mediaEls.length && i < 16; i++) {
                    inspectMediaElement(mediaEls[i]);
                }
            } catch (_) {}
        };

        const origFetch = window.fetch;
        if (typeof origFetch === 'function') {
            window.fetch = function(input, init) {
                let reqUrl = '';
                try {
                    if (typeof input === 'string') {
                        reqUrl = input;
                    } else if (input && typeof input.url === 'string') {
                        reqUrl = input.url;
                    } else if (input && typeof input.href === 'string') {
                        reqUrl = input.href;
                    } else if (input != null && typeof input.toString === 'function') {
                        const s = String(input);
                        if (s && s !== '[object Object]') reqUrl = s;
                    }
                    if (reqUrl) report(reqUrl, 'fetch', 0, '', false);
                } catch (_) {}
                const p = origFetch.apply(this, arguments);
                const isCandidate = reqUrl && CANDIDATE_RE.test(reqUrl);
                const isMediaAPI = reqUrl && MEDIA_API_URL_RE.test(reqUrl);
                // Inspect response Content-Type cheaply on all fetches (O(1) header check, zero body read unless matched),
                // so extensionless tokenized HLS/DASH/MP4 responses are captured by MIME truth.
                if (reqUrl) {
                    try {
                        Promise.resolve(p).then(function(res) {
                            if (!res || !res.headers || typeof res.headers.get !== 'function') return;
                            const ct = (res.headers.get('content-type') || '').toLowerCase();
                            const finalUrl = (res.url && res.url.length > 0) ? res.url : reqUrl;

                            if (isVideoMIME(ct)) {
                                report(finalUrl, 'video-mime', 0, '', true, { mimeType: ct });
                                return;
                            }
                            if (ct.includes('dash+xml')) {
                                report(finalUrl, 'dash-mime', 0, '', true, { mimeType: ct });
                                return;
                            }

                            const cl = parseInt(res.headers.get('content-length') || '0', 10);
                            const isHLSCT = ct.includes('mpegurl');
                            const isGenericPlainText = ct.startsWith('text/plain') && !isHLSCT && !isCandidate && !isMediaAPI;
                            if (!isHLSCT && !isCandidate && !isMediaAPI && !isGenericPlainText) return;
                            if (typeof res.clone !== 'function') return;
                            if (ct.includes('javascript') || ct.includes('css') || ct.includes('vtt') || ct.includes('image/')) return;
                            if (cl > 524288) return;
                            if (isHLSCT || isCandidate || isGenericPlainText || ct.includes('json') || ct.includes('plain')) {
                                const cloned = res.clone();
                                // Always read via a bounded stream reader (even when `Content-Length` is set, to guard
                                // against compressed payload expansion). For generic `text/plain`, abort immediately on
                                // the first chunk if leading bytes do not match `#EXTM3U` so unconsumed streams are never drained.
                                if (cloned.body && typeof cloned.body.getReader === 'function') {
                                    const reader = cloned.body.getReader();
                                    const decoder = typeof TextDecoder === 'function' ? new TextDecoder() : null;
                                    const probeDecoder = (isGenericPlainText && typeof TextDecoder === 'function') ? new TextDecoder() : null;
                                    let buf = '';
                                    let total = 0;
                                    let confirmedEXTM3U = !isGenericPlainText;
                                    (function pump() {
                                        reader.read().then(function(step) {
                                            if (step.done) {
                                                if (buf && confirmedEXTM3U) {
                                                    reportManifest(finalUrl, buf, 'fetch-manifest');
                                                    if (!isGenericPlainText) scanRawText(buf, 'fetch-body');
                                                }
                                                return;
                                            }
                                            const chunk = step.value;
                                            if (chunk) {
                                                const chunkLen = chunk.byteLength || chunk.length || 0;
                                                total += chunkLen;
                                                if (total > 524288) {
                                                    try { reader.cancel(); } catch (_) {}
                                                    return;
                                                }
                                                if (!confirmedEXTM3U) {
                                                    // Check only the leading 64 bytes before decoding the full chunk so
                                                    // non-HLS plain text never allocates a full-chunk JS string.
                                                    const probeSlice = (chunk.subarray && chunkLen > 64) ? chunk.subarray(0, 64) : chunk;
                                                    const probeText = buf + (probeDecoder ? probeDecoder.decode(probeSlice) : '');
                                                    const trimmedHead = probeText.replace(/^\uFEFF/, '').trimStart();
                                                    if (trimmedHead.length >= 7) {
                                                        if (trimmedHead.startsWith('#EXTM3U')) {
                                                            confirmedEXTM3U = true;
                                                        } else {
                                                            try { reader.cancel(); } catch (_) {}
                                                            return;
                                                        }
                                                    } else if (total >= 64) {
                                                        try { reader.cancel(); } catch (_) {}
                                                        return;
                                                    }
                                                }
                                                if (decoder) buf += decoder.decode(chunk, { stream: true });
                                            }
                                            pump();
                                        }).catch(function(){});
                                    })();
                                } else if (!isGenericPlainText && cl > 0 && cl <= 262144) {
                                    cloned.text().then(function(t) {
                                        if (typeof t === 'string' && t.length <= 524288) {
                                            reportManifest(finalUrl, t, 'fetch-manifest');
                                            scanRawText(t, 'fetch-body');
                                        }
                                    }).catch(function(){});
                                }
                            }
                        }).catch(function(){});
                    } catch (_) {}
                }
                return p;
            };
        }

        const xhrStates = new WeakMap();
        const origXHROpen = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function(method, url) {
            try {
                const reqUrl = (url && typeof url.href === 'string') ? url.href : (url ? String(url) : '');
                if (reqUrl) report(reqUrl, 'xhr', 0, '', false);
                const matchesURL = Boolean(reqUrl && (CANDIDATE_RE.test(reqUrl) || MEDIA_API_URL_RE.test(reqUrl)));
                const firstAttach = !xhrStates.has(this);
                xhrStates.set(this, {
                    reqUrl: reqUrl,
                    matchesURL: matchesURL,
                    mimeMatchedHLS: false,
                    ct: '',
                    contentLength: 0
                });
                if (firstAttach) {
                    this.addEventListener('readystatechange', function() {
                        try {
                            if (this.readyState !== 2) return;
                            const st = xhrStates.get(this);
                            if (!st || !st.reqUrl) return;
                            const ct = (this.getResponseHeader('content-type') || '').toLowerCase();
                            st.ct = ct;
                            st.contentLength = parseInt(this.getResponseHeader('content-length') || '0', 10) || 0;
                            const finalUrl = (this.responseURL && this.responseURL.length > 0) ? this.responseURL : st.reqUrl;
                            if (isVideoMIME(ct)) {
                                report(finalUrl, 'video-mime', 0, '', true, { mimeType: ct });
                            } else if (ct.includes('dash+xml')) {
                                report(finalUrl, 'dash-mime', 0, '', true, { mimeType: ct });
                            } else if (ct.includes('mpegurl')) {
                                st.mimeMatchedHLS = true;
                            }
                        } catch (_) {}
                    });
                    this.addEventListener('load', function() {
                        try {
                            const st = xhrStates.get(this);
                            if (!st || !st.reqUrl) return;
                            const finalUrl = (this.responseURL && this.responseURL.length > 0) ? this.responseURL : st.reqUrl;
                            if (!this.responseType || this.responseType === 'text') {
                                // Skip touching `responseText` on non-candidate HTML/JS/CSS/JSON/image XHRs.
                                const isPlainOrUnknownCT = !st.ct || st.ct.startsWith('text/plain') || st.ct.includes('octet-stream');
                                if (!st.matchesURL && !st.mimeMatchedHLS && (!isPlainOrUnknownCT || st.contentLength > 524288)) {
                                    return;
                                }
                                const txt = this.responseText;
                                if (typeof txt === 'string' && txt.length >= 16 && txt.length <= 524288) {
                                    const firstChar = txt.charCodeAt(0);
                                    if (firstChar === 35 || firstChar === 32 || firstChar === 10 || firstChar === 13 || firstChar === 65279) {
                                        if (txt.trimStart().startsWith('#EXTM3U')) {
                                            reportManifest(finalUrl, txt, 'xhr-manifest');
                                            return;
                                        }
                                    }
                                    if (st.matchesURL || st.mimeMatchedHLS) {
                                        scanRawText(txt, 'xhr-body');
                                    }
                                }
                            } else if (this.responseType === 'arraybuffer' && this.response && this.response.byteLength >= 16 && this.response.byteLength <= 524288) {
                                const bytes = new Uint8Array(this.response);
                                const hasEXTM3U = bytes.length >= 7
                                    && bytes[0] === 0x23 && bytes[1] === 0x45 && bytes[2] === 0x58 && bytes[3] === 0x54
                                    && bytes[4] === 0x4D && bytes[5] === 0x33 && bytes[6] === 0x55;
                                if ((hasEXTM3U || st.matchesURL || st.mimeMatchedHLS) && typeof TextDecoder === 'function') {
                                    const txt = new TextDecoder().decode(bytes);
                                    reportManifest(finalUrl, txt, 'xhr-manifest');
                                    if (st.matchesURL || st.mimeMatchedHLS) scanRawText(txt, 'xhr-body');
                                }
                            } else if ((st.matchesURL || st.mimeMatchedHLS) && this.responseType === 'json' && this.response) {
                                walkObject(this.response, '', 0, { left: 160 });
                            }
                        } catch (_) {}
                    });
                }
            } catch (_) {}
            return origXHROpen.apply(this, arguments);
        };

        const mediaProto = window.HTMLMediaElement && window.HTMLMediaElement.prototype;
        if (mediaProto) {
            const srcDesc = Object.getOwnPropertyDescriptor(mediaProto, 'src');
            if (srcDesc && srcDesc.set) {
                Object.defineProperty(mediaProto, 'src', {
                    get: srcDesc.get,
                    set: function(val) {
                        const result = srcDesc.set.call(this, val);
                        try {
                            if (val !== null && val !== undefined && String(val).trim().length > 0) {
                                const resolvedSrc = (this && this.src) ? this.src : String(val);
                                report(resolvedSrc, 'video-src', 0, (this && this.poster) || '', true, { omitOrigin: !(this && this.crossOrigin) });
                            }
                        } catch (_) {}
                        return result;
                    },
                    configurable: true
                });
            }
            const origLoad = mediaProto.load;
            if (typeof origLoad === 'function') {
                mediaProto.load = function() {
                    inspectMediaElement(this);
                    return origLoad.apply(this, arguments);
                };
            }
            const origPlay = mediaProto.play;
            if (typeof origPlay === 'function') {
                mediaProto.play = function() {
                    inspectMediaElement(this);
                    return origPlay.apply(this, arguments);
                };
            }
        }

        const sourceProto = window.HTMLSourceElement && window.HTMLSourceElement.prototype;
        if (sourceProto) {
            const sourceSrcDesc = Object.getOwnPropertyDescriptor(sourceProto, 'src');
            if (sourceSrcDesc && sourceSrcDesc.set) {
                Object.defineProperty(sourceProto, 'src', {
                    get: sourceSrcDesc.get,
                    set: function(val) {
                        const result = sourceSrcDesc.set.call(this, val);
                        try {
                            const parent = this && this.parentElement;
                            if ((!parent || parent.tagName === 'VIDEO' || parent.tagName === 'AUDIO')
                                && val !== null && val !== undefined && String(val).trim().length > 0) {
                                const resolvedSrc = (this && this.src) ? this.src : String(val);
                                report(resolvedSrc, 'video-src', 0, (parent && parent.poster) || '', true, { omitOrigin: !(parent && parent.crossOrigin) });
                            }
                        } catch (_) {}
                        return result;
                    },
                    configurable: true
                });
            }
        }

        ['loadstart', 'loadedmetadata', 'canplay', 'play', 'playing'].forEach(function(evtName) {
            document.addEventListener(evtName, function(e) {
                const target = (e && typeof e.composedPath === 'function' && e.composedPath()[0]) || (e && e.target);
                inspectMediaElement(target);
            }, true);
        });

        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', window.__dysprosiumScanMediaElements, { once: true });
        } else {
            window.__dysprosiumScanMediaElements();
        }

        if (typeof PerformanceObserver === 'function') {
            try {
                resourceObserver = new PerformanceObserver(function(list) {
                    if (reportedURLs.size >= 40) {
                        try { resourceObserver.disconnect(); } catch (_) {}
                        resourceObserver = null;
                        return;
                    }
                    const entries = list.getEntries();
                    for (let i = 0; i < entries.length; i++) {
                        const name = entries[i] && entries[i].name;
                        if (name && CANDIDATE_RE.test(name)) {
                            report(name, 'perf', 0, '', false);
                        }
                    }
                });
                resourceObserver.observe({ type: 'resource', buffered: true });
            } catch (_) {}
        }
    })();
    """#

    /// Main-frame-only (`.atDocumentEnd`, `forMainFrameOnly: true`) inline `<script>` / JSON-LD media scanner.
    /// Extracted from `allFramesStreamInterceptor` so iframes parse 0 bytes and document-start parsing stays minimal.
    static let topFrameMediaDOMScanner = #"""
    (function() {
        if (window !== window.top) return;
        if (window.location && window.location.protocol === 'about:') return;
        const MEDIA_URL_RE = /https?:\/\/[^\s"'<>\\]+?\.(?:m3u8|mp4|m4v|mpd)(?:[?&][^\s"'<>\\]*)?/gi;
        const CANDIDATE_RE = /\.(?:m3u8|mp4|m4v|mpd|mov|mkv|webm)(?:[?#&]|$)|mpegurl|master\.txt|r_file=chunklist/i;
        try {
            const scripts = document.querySelectorAll('script[type="application/ld+json"], script:not([src])');
            if (!scripts || !scripts.length) return;
            const seen = new Set();
            let poster = '';
            const v = document.querySelector('video[poster]');
            if (v && v.poster) {
                try { poster = new URL(v.poster, window.location.href).href; } catch (_) {}
            } else {
                const og = document.querySelector('meta[property="og:image"], meta[name="twitter:image"]');
                if (og && og.content) {
                    try { poster = new URL(og.content, window.location.href).href; } catch (_) {}
                }
            }
            const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.dysprosiumSniffer;
            if (!handler) return;
            for (let i = 0; i < scripts.length && i < 24 && seen.size < 20; i++) {
                const s = scripts[i];
                if (s.__dysScanned) continue;
                s.__dysScanned = true;
                const txt = s.textContent;
                if (!txt || txt.length < 24 || txt.length > 262144) continue;
                if (txt.indexOf('.m3u8') === -1 && txt.indexOf('.mp4') === -1 && txt.indexOf('.m4v') === -1 &&
                    txt.indexOf('.mpd') === -1 && txt.indexOf('mpegurl') === -1 && txt.indexOf('master.txt') === -1) {
                    continue;
                }
                const normalized = txt.indexOf('\\/') !== -1 ? txt.replace(/\\\//g, '/') : txt;
                if (!poster) {
                    const pm = normalized.match(/"(?:i|poster|thumbnailUrl|thumbnail)"\s*:\s*"(https?:\/\/[^"\s\\]+?\.(?:jpg|jpeg|webp|png)(?:\?[^"\s\\]*)?)"/i);
                    if (pm && pm[1]) poster = pm[1];
                }
                const matches = normalized.match(MEDIA_URL_RE);
                if (!matches) continue;
                for (let k = 0; k < matches.length && seen.size < 20; k++) {
                    const m = matches[k];
                    if (!CANDIDATE_RE.test(m)) continue;
                    try {
                        const resolved = new URL(m, window.location.href).href;
                        if (seen.has(resolved)) continue;
                        seen.add(resolved);
                        handler.postMessage({
                            url: resolved,
                            hint: 'inline-script',
                            quality: 0,
                            referer: window.location.href,
                            origin: window.location.origin,
                            title: document.title || '',
                            poster: poster,
                            ua: navigator.userAgent || ''
                        });
                    } catch (_) {}
                }
            }
        } catch (_) {}
    })();
    """#

    static let pageCanvasColorProbe = #"""
    (() => {
        if (document.documentElement && (document.documentElement.hasAttribute('data-darkreader-scheme') || document.querySelector('style.darkreader'))) {
            return '20,21,23';
        }
        for (const el of [document.body, document.documentElement]) {
            if (!el) continue;
            const bg = getComputedStyle(el).backgroundColor || '';
            const m = bg.match(/rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)(?:\s*,\s*([0-9.]+))?\s*\)/i);
            if (m) {
                const a = m[4] !== undefined ? parseFloat(m[4]) : 1;
                if (a >= 0.85) return `${m[1]},${m[2]},${m[3]}`;
            }
        }
        const cs = (getComputedStyle(document.documentElement).colorScheme || '').toLowerCase();
        if (cs.includes('dark') && matchMedia('(prefers-color-scheme: dark)').matches) {
            return '18,18,20';
        }
        return '255,255,255';
    })()
    """#

    static let headlessAutoPlayNudge = #"""
    (() => {
        document.querySelectorAll('video').forEach(v => {
            v.muted = true;
            try { v.play(); } catch (_) {}
        });
        const selectors = [
            'button[aria-label*="Play" i]', '.vjs-big-play-button',
            '.jw-icon-display', '.plyr__control--overlaid', '.bigPlayUI'
        ];
        for (const sel of selectors) {
            const btn = document.querySelector(sel);
            if (btn) { try { btn.click(); } catch (_) {} }
        }
    })();
    """#

    // MARK: - Data-Driven uBlock Origin / AdGuard Scriptlet Runtime Builder

    nonisolated static func buildScriptletRuntimeScript(rules: [WebKitRuleCompiler.CompiledScriptletRule]) -> String {
        guard !rules.isEmpty else { return "" }

        var defs: [[Any]] = []
        var defIndexByKey: [String: Int] = [:]
        var hostMap: [String: [Int]] = [:]
        var usedPrimitives = Set<String>()

        for rule in rules {
            usedPrimitives.insert(rule.primitive)
            let sigKey = "\(rule.primitive)\u{0000}\(rule.args.joined(separator: "\u{0001}"))\u{0000}\(rule.excludedDomains.joined(separator: ","))"
            let defIdx: Int
            if let existing = defIndexByKey[sigKey] {
                defIdx = existing
            } else {
                defIdx = defs.count
                defIndexByKey[sigKey] = defIdx
                let tuple: [Any] = rule.excludedDomains.isEmpty
                    ? [rule.primitive, rule.args]
                    : [rule.primitive, rule.args, rule.excludedDomains]
                defs.append(tuple)
            }
            for domain in rule.positiveDomains {
                hostMap[domain, default: []].append(defIdx)
            }
        }

        let packObject: [String: Any] = ["d": defs, "h": hostMap]
        guard !hostMap.isEmpty,
              JSONSerialization.isValidJSONObject(packObject),
              let packData = try? JSONSerialization.data(withJSONObject: packObject, options: [.sortedKeys]),
              let packJSONString = String(data: packData, encoding: .utf8),
              let jsStringLiteralData = try? JSONEncoder().encode(packJSONString),
              var jsStringLiteral = String(data: jsStringLiteralData, encoding: .utf8) else {
            return ""
        }

        jsStringLiteral = jsStringLiteral
            .replacingOccurrences(of: "</", with: "<\\/")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")

        // Feature-gated runtime: emit only JS helpers & switch cases required by `usedPrimitives`
        let needsMatchers = !usedPrimitives.isDisjoint(with: [
            "abort-current-inline-script", "abort-on-stack-trace", "addEventListener-defuser",
            "no-setTimeout-if", "no-setInterval-if", "adjust-setTimeout", "adjust-setInterval",
            "no-window-open-if", "no-fetch-if", "no-xhr-if",
            "json-prune-fetch-response", "json-prune-xhr-response",
            "remove-node-text", "remove-cookie", "prevent-element-src-loading", "noeval-if"
        ])
        let needsDelayMatcher = !usedPrimitives.isDisjoint(with: [
            "no-setTimeout-if", "no-setInterval-if", "adjust-setTimeout", "adjust-setInterval"
        ])
        let needsRequestMatcher = !usedPrimitives.isDisjoint(with: [
            "no-fetch-if", "no-xhr-if", "json-prune-fetch-response", "json-prune-xhr-response"
        ])
        let needsChainObserver = !usedPrimitives.isDisjoint(with: [
            "set-constant", "abort-on-property-read", "abort-on-property-write",
            "abort-current-inline-script", "abort-on-stack-trace"
        ])
        let needsJsonPrune = !usedPrimitives.isDisjoint(with: [
            "json-prune", "json-prune-fetch-response", "json-prune-xhr-response"
        ])
        let needsStorage = !usedPrimitives.isDisjoint(with: [
            "set-local-storage-item", "trusted-set-local-storage-item",
            "set-session-storage-item", "trusted-set-session-storage-item"
        ])
        let needsCookies = !usedPrimitives.isDisjoint(with: [
            "set-cookie", "set-cookie-reload", "trusted-set-cookie", "remove-cookie"
        ])
        let needsDomAttrClass = !usedPrimitives.isDisjoint(with: [
            "remove-attr", "remove-class"
        ])

        var helpers = ""
        var switchCases = ""

        if needsChainObserver {
            helpers += #"""
                const abortToken = 'Dysprosium_' + Math.random().toString(36).slice(2, 10);
                function makeAbortError() { return new ReferenceError(abortToken); }
                const throwFn = function() { throw makeAbortError(); };
                function findDescriptor(obj, prop) {
                    let cur = obj;
                    while (cur) {
                        const d = Object.getOwnPropertyDescriptor(cur, prop);
                        if (d) return { desc: d, isOwn: cur === obj };
                        cur = Object.getPrototypeOf(cur);
                    }
                    return null;
                }
                function splitChain(rawPath) {
                    const cleaned = String(rawPath || '').trim().replace(/^window\./, '');
                    return cleaned ? cleaned.split('.').filter(Boolean) : [];
                }
                function observeChain(owner, parts, installLeaf) {
                    if (!owner || (typeof owner !== 'object' && typeof owner !== 'function') || !parts.length) return;
                    if (parts.length === 1) {
                        try { installLeaf(owner, parts[0]); } catch (_) {}
                        return;
                    }
                    const head = parts[0], tail = parts.slice(1);
                    let existingVal;
                    try { existingVal = owner[head]; } catch (_) {}
                    if (existingVal && (typeof existingVal === 'object' || typeof existingVal === 'function')) {
                        observeChain(existingVal, tail, installLeaf);
                    }
                    const ownDesc = Object.getOwnPropertyDescriptor(owner, head);
                    if (ownDesc && ownDesc.configurable === false) return;
                    const prevGet = ownDesc && ownDesc.get, prevSet = ownDesc && ownDesc.set;
                    let stored = existingVal;
                    try {
                        Object.defineProperty(owner, head, {
                            configurable: true,
                            enumerable: ownDesc ? ownDesc.enumerable : true,
                            get: function() { return prevGet ? prevGet.call(this) : stored; },
                            set: function(v) {
                                if (prevSet) { prevSet.call(this, v); } else { stored = v; }
                                let effective = v;
                                if (prevGet) { try { effective = prevGet.call(this); } catch (_) {} }
                                if (effective && (typeof effective === 'object' || typeof effective === 'function')) {
                                    observeChain(effective, tail, installLeaf);
                                }
                            }
                        });
                    } catch (_) {}
                }
            """# + "\n"
        }

        if usedPrimitives.contains("set-constant") {
            helpers += #"""
                const trueFn = function() { return true; };
                const falseFn = function() { return false; };
                const resolvePromiseFn = function() { return Promise.resolve(); };
                const rejectPromiseFn = function() { return Promise.reject(); };
                const noopCallbackFn = function() { return noopFn; };
                function resolveConstant(rawVal) {
                    const token = rawVal === undefined || rawVal === null ? '' : String(rawVal);
                    switch (token) {
                        case 'true': return { ok: true, get: function() { return true; } };
                        case 'false': return { ok: true, get: function() { return false; } };
                        case 'null': return { ok: true, get: function() { return null; } };
                        case 'undefined': return { ok: true, get: function() { return undefined; } };
                        case '': case "''": case '""': case 'emptyStr': return { ok: true, get: function() { return ''; } };
                        case '0': return { ok: true, get: function() { return 0; } };
                        case '1': return { ok: true, get: function() { return 1; } };
                        case '-1': return { ok: true, get: function() { return -1; } };
                        case 'NaN': return { ok: true, get: function() { return NaN; } };
                        case 'Infinity': return { ok: true, get: function() { return Infinity; } };
                        case '-Infinity': return { ok: true, get: function() { return -Infinity; } };
                        case 'noopFunc': return { ok: true, get: function() { return noopFn; } };
                        case 'noopCallbackFunc': return { ok: true, get: function() { return noopCallbackFn; } };
                        case 'trueFunc': return { ok: true, get: function() { return trueFn; } };
                        case 'falseFunc': return { ok: true, get: function() { return falseFn; } };
                        case 'throwFunc': return { ok: true, get: function() { return throwFn; } };
                        case 'noopPromiseResolve': return { ok: true, get: function() { return resolvePromiseFn; } };
                        case 'noopPromiseReject': return { ok: true, get: function() { return rejectPromiseFn; } };
                        case 'emptyObj': { const o = {}; return { ok: true, get: function() { return o; } }; }
                        case 'emptyArr': { const a = []; return { ok: true, get: function() { return a; } }; }
                        case 'yes': return { ok: true, get: function() { return 'yes'; } };
                        case 'no': return { ok: true, get: function() { return 'no'; } };
                        case 'on': return { ok: true, get: function() { return 'on'; } };
                        case 'off': return { ok: true, get: function() { return 'off'; } };
                        default: {
                            if (/^-?\d+$/.test(token)) {
                                const num = parseInt(token, 10);
                                if (!isNaN(num) && Math.abs(num) <= 32767) return { ok: true, get: function() { return num; } };
                            }
                            return { ok: false };
                        }
                    }
                }
            """# + "\n"
            switchCases += #"""
                            case 'set-constant': {
                                const parts = splitChain(args[0]);
                                const resolved = resolveConstant(args.length > 1 ? args[1] : '');
                                if (!parts.length || !resolved.ok) break;
                                observeChain(root, parts, function(leafOwner, prop) {
                                    const own = Object.getOwnPropertyDescriptor(leafOwner, prop);
                                    if (own && own.configurable === false) return;
                                    Object.defineProperty(leafOwner, prop, {
                                        configurable: true, enumerable: own ? own.enumerable : true,
                                        get: resolved.get, set: noopFn
                                    });
                                });
                                break;
                            }
            """# + "\n"
        }

        if usedPrimitives.contains("abort-on-property-read") {
            switchCases += #"""
                            case 'abort-on-property-read': {
                                const parts = splitChain(args[0]);
                                if (!parts.length) break;
                                observeChain(root, parts, function(leafOwner, prop) {
                                    const own = Object.getOwnPropertyDescriptor(leafOwner, prop);
                                    if (own && own.configurable === false) return;
                                    Object.defineProperty(leafOwner, prop, {
                                        configurable: true, enumerable: own ? own.enumerable : true,
                                        get: throwFn, set: noopFn
                                    });
                                });
                                break;
                            }
            """# + "\n"
        }

        if usedPrimitives.contains("abort-on-property-write") {
            switchCases += #"""
                            case 'abort-on-property-write': {
                                const parts = splitChain(args[0]);
                                if (!parts.length) break;
                                observeChain(root, parts, function(leafOwner, prop) {
                                    const own = Object.getOwnPropertyDescriptor(leafOwner, prop);
                                    if (own && own.configurable === false) return;
                                    let currentVal;
                                    try { currentVal = leafOwner[prop]; } catch (_) {}
                                    Object.defineProperty(leafOwner, prop, {
                                        configurable: true, enumerable: own ? own.enumerable : true,
                                        get: function() { return currentVal; }, set: throwFn
                                    });
                                });
                                break;
                            }
            """# + "\n"
        }

        if needsMatchers {
            helpers += #"""
                function compileMatcher(pattern) {
                    if (pattern === undefined || pattern === null || pattern === '') return function() { return true; };
                    const str = String(pattern);
                    const rxMatch = /^\/(.+)\/([gimsuy]*)$/.exec(str);
                    if (rxMatch) {
                        try {
                            const re = new RegExp(rxMatch[1], rxMatch[2].replace(/[gy]/g, ''));
                            return function(haystack) { return re.test(String(haystack || '')); };
                        } catch (_) { return function() { return false; }; }
                    }
                    return function(haystack) { return String(haystack || '').indexOf(str) !== -1; };
                }
                function compilePolarizedMatcher(pattern) {
                    if (pattern === undefined || pattern === null || pattern === '') return function() { return true; };
                    const str = String(pattern);
                    if (str.length > 1 && str.charAt(0) === '!') {
                        const inner = compileMatcher(str.slice(1));
                        return function(haystack) { return !inner(haystack); };
                    }
                    return compileMatcher(str);
                }
            """# + "\n"
        }

        if needsDelayMatcher {
            helpers += #"""
                let syntheticTimerID = 900000;
                function compileDelayMatcher(rawDelay) {
                    if (rawDelay === undefined || rawDelay === null || rawDelay === '' || rawDelay === '*') {
                        return function() { return true; };
                    }
                    const str = String(rawDelay).trim();
                    if (str.charAt(0) === '!') {
                        const inv = parseInt(str.slice(1), 10);
                        return isNaN(inv) ? function() { return true; } : function(d) { return d !== inv; };
                    }
                    const target = parseInt(str, 10);
                    return isNaN(target) ? function() { return false; } : function(d) { return d === target; };
                }
            """# + "\n"
        }

        if needsRequestMatcher {
            helpers += #"""
                function compileRequestMatcher(rawSpec) {
                    if (!rawSpec || rawSpec === '*') return function() { return true; };
                    const trimmed = String(rawSpec).trim();
                    if (!trimmed) return function() { return true; };
                    if (trimmed.charAt(0) === '/') {
                        const m = compilePolarizedMatcher(trimmed);
                        return function(req) { return m(req.url) || m('url:' + req.url + ' method:' + req.method); };
                    }
                    const parts = trimmed.split(/\s+/);
                    const checks = [];
                    for (let i = 0; i < parts.length; i++) {
                        const tok = parts[i];
                        const colon = tok.indexOf(':');
                        if (colon > 0) {
                            const k = tok.slice(0, colon).toLowerCase(), v = tok.slice(colon + 1);
                            if (k === 'url' || k === 'method' || k === 'body' || k === 'credentials' || k === 'mode') {
                                const pm = compilePolarizedMatcher(v);
                                checks.push(function(req) { return pm(req[k] || ''); });
                                continue;
                            }
                        }
                        const um = compilePolarizedMatcher(tok);
                        checks.push(function(req) { return um(req.url); });
                    }
                    return function(req) {
                        for (let i = 0; i < checks.length; i++) { if (!checks[i](req)) return false; }
                        return true;
                    };
                }
            """# + "\n"
        }

        if usedPrimitives.contains("abort-current-inline-script") {
            switchCases += #"""
                            case 'abort-current-inline-script': {
                                const parts = splitChain(args[0]);
                                if (!parts.length) break;
                                const needleMatcher = compilePolarizedMatcher(args.length > 1 ? args[1] : '');
                                const checkInlineScript = function() {
                                    const doc = root.document, cs = doc && doc.currentScript;
                                    if (cs && !cs.src && needleMatcher(cs.textContent || '')) throw makeAbortError();
                                };
                                observeChain(root, parts, function(leafOwner, prop) {
                                    const own = Object.getOwnPropertyDescriptor(leafOwner, prop);
                                    if (own && own.configurable === false) return;
                                    const found = findDescriptor(leafOwner, prop);
                                    const protoGet = found && found.desc.get, protoSet = found && found.desc.set;
                                    let currentVal;
                                    if (!protoGet) { try { currentVal = leafOwner[prop]; } catch (_) {} }
                                    Object.defineProperty(leafOwner, prop, {
                                        configurable: true, enumerable: own ? own.enumerable : true,
                                        get: function() { checkInlineScript(); return protoGet ? protoGet.call(this) : currentVal; },
                                        set: function(v) { checkInlineScript(); if (protoSet) { protoSet.call(this, v); } else { currentVal = v; } }
                                    });
                                });
                                break;
                            }
            """# + "\n"
        }

        if usedPrimitives.contains("abort-on-stack-trace") {
            switchCases += #"""
                            case 'abort-on-stack-trace': {
                                const parts = splitChain(args[0]);
                                const stackArg = args.length > 1 ? args[1] : '';
                                if (!parts.length || !stackArg) break;
                                const stackMatcher = compilePolarizedMatcher(stackArg);
                                const checkStack = function() {
                                    let st = '';
                                    try { st = String((new Error()).stack || ''); } catch (_) {}
                                    if (st && stackMatcher(st)) throw makeAbortError();
                                };
                                observeChain(root, parts, function(leafOwner, prop) {
                                    const own = Object.getOwnPropertyDescriptor(leafOwner, prop);
                                    if (own && own.configurable === false) return;
                                    const found = findDescriptor(leafOwner, prop);
                                    const protoGet = found && found.desc.get, protoSet = found && found.desc.set;
                                    let currentVal;
                                    if (!protoGet) { try { currentVal = leafOwner[prop]; } catch (_) {} }
                                    Object.defineProperty(leafOwner, prop, {
                                        configurable: true, enumerable: own ? own.enumerable : true,
                                        get: function() { checkStack(); return protoGet ? protoGet.call(this) : currentVal; },
                                        set: function(v) { checkStack(); if (protoSet) { protoSet.call(this, v); } else { currentVal = v; } }
                                    });
                                });
                                break;
                            }
            """# + "\n"
        }

        if usedPrimitives.contains("addEventListener-defuser") {
            helpers += #"""
                const aeldFilters = [];
                let aeldInstalled = false;
                function ensureAeldInstalled() {
                    if (aeldInstalled) return;
                    aeldInstalled = true;
                    const fnToStr = Function.prototype.toString;
                    function wrapAddEventListener(targetObj) {
                        if (!targetObj || typeof targetObj.addEventListener !== 'function') return;
                        const orig = targetObj.addEventListener;
                        targetObj.addEventListener = function(type, listener) {
                            try {
                                const typeStr = String(type || '');
                                let listenerStr = null;
                                for (let i = 0; i < aeldFilters.length; i++) {
                                    const f = aeldFilters[i];
                                    if (!f.typeMatch(typeStr)) continue;
                                    if (listenerStr === null) {
                                        listenerStr = typeof listener === 'function'
                                            ? fnToStr.call(listener)
                                            : (listener && typeof listener.handleEvent === 'function' ? fnToStr.call(listener.handleEvent) : '');
                                    }
                                    if (f.fnMatch(listenerStr)) return undefined;
                                }
                            } catch (_) {}
                            return orig.apply(this, arguments);
                        };
                    }
                    if (root.EventTarget && root.EventTarget.prototype) wrapAddEventListener(root.EventTarget.prototype);
                    else { wrapAddEventListener(root); if (root.document) wrapAddEventListener(root.document); }
                }
            """# + "\n"
            switchCases += #"""
                            case 'addEventListener-defuser': {
                                const typeArg = args.length > 0 ? args[0] : '', fnArg = args.length > 1 ? args[1] : '';
                                if (typeArg === '' && fnArg === '') break;
                                aeldFilters.push({ typeMatch: compilePolarizedMatcher(typeArg), fnMatch: compilePolarizedMatcher(fnArg) });
                                ensureAeldInstalled();
                                break;
                            }
            """# + "\n"
        }

        if usedPrimitives.contains("no-setTimeout-if") {
            helpers += #"""
                const nostifFilters = [];
                let nostifInstalled = false;
                function ensureNostifInstalled() {
                    if (nostifInstalled || typeof root.setTimeout !== 'function') return;
                    nostifInstalled = true;
                    const orig = root.setTimeout, fnToStr = Function.prototype.toString;
                    root.setTimeout = function(cb, delay) {
                        try {
                            const numDelay = delay === undefined ? 0 : Number(delay);
                            let cbStr = null;
                            for (let i = 0; i < nostifFilters.length; i++) {
                                const f = nostifFilters[i];
                                if (!f.delayMatch(numDelay)) continue;
                                if (cbStr === null) cbStr = typeof cb === 'function' ? fnToStr.call(cb) : String(cb || '');
                                if (f.cbMatch(cbStr)) return ++syntheticTimerID;
                            }
                        } catch (_) {}
                        return orig.apply(this, arguments);
                    };
                }
            """# + "\n"
            switchCases += #"""
                            case 'no-setTimeout-if': {
                                const cbArg = args.length > 0 ? args[0] : '', delayArg = args.length > 1 ? args[1] : '';
                                if (cbArg === '' && delayArg === '') break;
                                nostifFilters.push({ cbMatch: compilePolarizedMatcher(cbArg), delayMatch: compileDelayMatcher(delayArg) });
                                ensureNostifInstalled();
                                break;
                            }
            """# + "\n"
        }

        if usedPrimitives.contains("no-setInterval-if") {
            helpers += #"""
                const nosiifFilters = [];
                let nosiifInstalled = false;
                function ensureNosiifInstalled() {
                    if (nosiifInstalled || typeof root.setInterval !== 'function') return;
                    nosiifInstalled = true;
                    const orig = root.setInterval, fnToStr = Function.prototype.toString;
                    root.setInterval = function(cb, delay) {
                        try {
                            const numDelay = delay === undefined ? 0 : Number(delay);
                            let cbStr = null;
                            for (let i = 0; i < nosiifFilters.length; i++) {
                                const f = nosiifFilters[i];
                                if (!f.delayMatch(numDelay)) continue;
                                if (cbStr === null) cbStr = typeof cb === 'function' ? fnToStr.call(cb) : String(cb || '');
                                if (f.cbMatch(cbStr)) return ++syntheticTimerID;
                            }
                        } catch (_) {}
                        return orig.apply(this, arguments);
                    };
                }
            """# + "\n"
            switchCases += #"""
                            case 'no-setInterval-if': {
                                const cbArg = args.length > 0 ? args[0] : '', delayArg = args.length > 1 ? args[1] : '';
                                if (cbArg === '' && delayArg === '') break;
                                nosiifFilters.push({ cbMatch: compilePolarizedMatcher(cbArg), delayMatch: compileDelayMatcher(delayArg) });
                                ensureNosiifInstalled();
                                break;
                            }
            """# + "\n"
        }

        if usedPrimitives.contains("adjust-setTimeout") {
            helpers += #"""
                const boostStFilters = [];
                let boostStInstalled = false;
                function ensureBoostStInstalled() {
                    if (boostStInstalled || typeof root.setTimeout !== 'function') return;
                    boostStInstalled = true;
                    const orig = root.setTimeout, fnToStr = Function.prototype.toString;
                    root.setTimeout = function(cb, delay) {
                        try {
                            const numDelay = delay === undefined ? 0 : Number(delay);
                            if (isFinite(numDelay) && numDelay >= 20) {
                                let cbStr = null;
                                for (let i = 0; i < boostStFilters.length; i++) {
                                    const f = boostStFilters[i];
                                    if (!f.delayMatch(numDelay)) continue;
                                    if (cbStr === null) cbStr = typeof cb === 'function' ? fnToStr.call(cb) : String(cb || '');
                                    if (f.cbMatch(cbStr)) {
                                        const argsCopy = Array.prototype.slice.call(arguments);
                                        argsCopy[1] = Math.max(1, Math.floor(numDelay * f.boost));
                                        return orig.apply(this, argsCopy);
                                    }
                                }
                            }
                        } catch (_) {}
                        return orig.apply(this, arguments);
                    };
                }
            """# + "\n"
            switchCases += #"""
                            case 'adjust-setTimeout': {
                                const cbArg = args.length > 0 ? args[0] : '';
                                const delayArg = args.length > 1 ? args[1] : (cbArg === '' ? '1000' : '*');
                                const rawBoost = args.length > 2 ? parseFloat(args[2]) : 0.05;
                                const boost = isFinite(rawBoost) ? Math.min(50, Math.max(0.001, rawBoost)) : 0.05;
                                boostStFilters.push({ cbMatch: compilePolarizedMatcher(cbArg), delayMatch: compileDelayMatcher(delayArg), boost: boost });
                                ensureBoostStInstalled();
                                break;
                            }
            """# + "\n"
        }

        if usedPrimitives.contains("adjust-setInterval") {
            helpers += #"""
                const boostSiFilters = [];
                let boostSiInstalled = false;
                function ensureBoostSiInstalled() {
                    if (boostSiInstalled || typeof root.setInterval !== 'function') return;
                    boostSiInstalled = true;
                    const orig = root.setInterval, fnToStr = Function.prototype.toString;
                    root.setInterval = function(cb, delay) {
                        try {
                            const numDelay = delay === undefined ? 0 : Number(delay);
                            if (isFinite(numDelay) && numDelay >= 20) {
                                let cbStr = null;
                                for (let i = 0; i < boostSiFilters.length; i++) {
                                    const f = boostSiFilters[i];
                                    if (!f.delayMatch(numDelay)) continue;
                                    if (cbStr === null) cbStr = typeof cb === 'function' ? fnToStr.call(cb) : String(cb || '');
                                    if (f.cbMatch(cbStr)) {
                                        const argsCopy = Array.prototype.slice.call(arguments);
                                        argsCopy[1] = Math.max(10, Math.floor(numDelay * f.boost));
                                        return orig.apply(this, argsCopy);
                                    }
                                }
                            }
                        } catch (_) {}
                        return orig.apply(this, arguments);
                    };
                }
            """# + "\n"
            switchCases += #"""
                            case 'adjust-setInterval': {
                                const cbArg = args.length > 0 ? args[0] : '';
                                const delayArg = args.length > 1 ? args[1] : (cbArg === '' ? '1000' : '*');
                                const rawBoost = args.length > 2 ? parseFloat(args[2]) : 0.05;
                                const boost = isFinite(rawBoost) ? Math.min(50, Math.max(0.001, rawBoost)) : 0.05;
                                boostSiFilters.push({ cbMatch: compilePolarizedMatcher(cbArg), delayMatch: compileDelayMatcher(delayArg), boost: boost });
                                ensureBoostSiInstalled();
                                break;
                            }
            """# + "\n"
        }

        if usedPrimitives.contains("no-window-open-if") {
            helpers += #"""
                const nowoifFilters = [];
                let nowoifInstalled = false;
                function makeDecoyWindow(closeAfterSec) {
                    const decoy = {
                        closed: false, opener: null, innerWidth: 1024, innerHeight: 768,
                        focus: noopFn, blur: noopFn, postMessage: noopFn,
                        addEventListener: noopFn, removeEventListener: noopFn, dispatchEvent: function() { return true; },
                        close: function() { decoy.closed = true; },
                        document: { open: noopFn, write: noopFn, writeln: noopFn, close: noopFn, body: {} },
                        location: { href: 'about:blank', assign: noopFn, replace: noopFn }
                    };
                    if (closeAfterSec > 0 && typeof root.setTimeout === 'function') {
                        root.setTimeout(function() { decoy.closed = true; }, Math.min(30000, closeAfterSec * 1000));
                    }
                    return decoy;
                }
                function ensureNowoifInstalled() {
                    if (nowoifInstalled || typeof root.open !== 'function') return;
                    nowoifInstalled = true;
                    const origOpen = root.open;
                    root.open = function(url, target, features) {
                        try {
                            const urlStr = String(url || '');
                            const combined = urlStr + ' ' + String(target || '') + ' ' + String(features || '');
                            for (let i = 0; i < nowoifFilters.length; i++) {
                                const f = nowoifFilters[i];
                                if (f.match(urlStr) || (target && f.match(combined))) {
                                    return f.returnDecoy ? makeDecoyWindow(f.closeSec) : null;
                                }
                            }
                        } catch (_) {}
                        return origOpen.apply(this, arguments);
                    };
                }
            """# + "\n"
            switchCases += #"""
                            case 'no-window-open-if': {
                                let pat = args.length > 0 ? String(args[0] || '') : '';
                                let delayRaw = args.length > 1 ? String(args[1] || '') : '';
                                const thirdRaw = args.length > 2 ? String(args[2] || '') : '';
                                if ((pat === '0' || pat === '1') && args.length > 1) {
                                    const legacyPat = String(args[1] || '');
                                    pat = pat === '0' && legacyPat && legacyPat.charAt(0) !== '!' ? ('!' + legacyPat) : legacyPat;
                                    delayRaw = thirdRaw;
                                }
                                const closeSec = parseFloat(delayRaw);
                                const hasDelay = isFinite(closeSec) && closeSec > 0;
                                const wantObj = hasDelay || delayRaw === 'true' || delayRaw.indexOf('obj') !== -1 || thirdRaw.indexOf('obj') !== -1;
                                nowoifFilters.push({ match: compilePolarizedMatcher(pat), returnDecoy: wantObj, closeSec: hasDelay ? closeSec : 0 });
                                ensureNowoifInstalled();
                                break;
                            }
            """# + "\n"
        }

        if usedPrimitives.contains("no-fetch-if") {
            helpers += #"""
                const noFetchFilters = [];
                let noFetchInstalled = false;
                function ensureNoFetchInstalled() {
                    if (noFetchInstalled || typeof root.fetch !== 'function') return;
                    noFetchInstalled = true;
                    const origFetch = root.fetch;
                    root.fetch = function(input, init) {
                        try {
                            const url = typeof input === 'string' ? input : (input && typeof input.url === 'string' ? input.url : String(input || ''));
                            const method = String((init && init.method) || (input && input.method) || 'GET').toUpperCase();
                            const body = init && typeof init.body === 'string' ? init.body : '';
                            const credentials = String((init && init.credentials) || (input && input.credentials) || '');
                            const mode = String((init && init.mode) || (input && init.mode) || '');
                            const reqInfo = { url: url, method: method, body: body, credentials: credentials, mode: mode };
                            for (let i = 0; i < noFetchFilters.length; i++) {
                                if (noFetchFilters[i](reqInfo)) {
                                    const fakeRes = typeof Response === 'function'
                                        ? new Response('', { status: 200, statusText: 'OK' })
                                        : { ok: true, status: 200, statusText: 'OK', text: function() { return Promise.resolve(''); }, json: function() { return Promise.resolve({}); }, clone: function() { return this; } };
                                    return Promise.resolve(fakeRes);
                                }
                            }
                        } catch (_) {}
                        return origFetch.apply(this, arguments);
                    };
                }
            """# + "\n"
            switchCases += #"""
                            case 'no-fetch-if': {
                                noFetchFilters.push(compileRequestMatcher(args.length > 0 ? args[0] : ''));
                                ensureNoFetchInstalled();
                                break;
                            }
            """# + "\n"
        }

        if usedPrimitives.contains("no-xhr-if") {
            helpers += #"""
                const noXhrFilters = [];
                let noXhrInstalled = false;
                function ensureNoXhrInstalled() {
                    if (noXhrInstalled || !root.XMLHttpRequest || !root.XMLHttpRequest.prototype) return;
                    noXhrInstalled = true;
                    const proto = root.XMLHttpRequest.prototype;
                    const origOpen = proto.open, origSend = proto.send, origSetHeader = proto.setRequestHeader;
                    proto.open = function(method, url) {
                        this.__dysBlockedXHR = false;
                        try {
                            const urlStr = String(url || ''), methodStr = String(method || 'GET').toUpperCase();
                            const reqInfo = { url: urlStr, method: methodStr, body: '', credentials: '', mode: '' };
                            for (let i = 0; i < noXhrFilters.length; i++) {
                                if (noXhrFilters[i](reqInfo)) {
                                    this.__dysBlockedXHR = true;
                                    this.__dysXHRUrl = urlStr;
                                    break;
                                }
                            }
                        } catch (_) {}
                        try { return origOpen.apply(this, arguments); } catch (_) { return undefined; }
                    };
                    if (typeof origSetHeader === 'function') {
                        proto.setRequestHeader = function() {
                            if (this.__dysBlockedXHR) return undefined;
                            return origSetHeader.apply(this, arguments);
                        };
                    }
                    proto.send = function() {
                        if (this.__dysBlockedXHR) {
                            const self = this;
                            try {
                                const resVal = self.responseType === 'json' ? null : (self.responseType === 'arraybuffer' && typeof ArrayBuffer === 'function' ? new ArrayBuffer(0) : '');
                                Object.defineProperty(self, 'readyState', { configurable: true, get: function() { return 4; } });
                                Object.defineProperty(self, 'status', { configurable: true, get: function() { return 200; } });
                                Object.defineProperty(self, 'statusText', { configurable: true, get: function() { return 'OK'; } });
                                Object.defineProperty(self, 'responseText', { configurable: true, get: function() { return ''; } });
                                Object.defineProperty(self, 'response', { configurable: true, get: function() { return resVal; } });
                                Object.defineProperty(self, 'responseURL', { configurable: true, get: function() { return self.__dysXHRUrl || ''; } });
                            } catch (_) {}
                            const notifyDone = function() {
                                try {
                                    if (typeof Event === 'function' && typeof self.dispatchEvent === 'function') {
                                        self.dispatchEvent(new Event('readystatechange'));
                                        self.dispatchEvent(new Event('load'));
                                        self.dispatchEvent(new Event('loadend'));
                                    } else {
                                        if (typeof self.onreadystatechange === 'function') self.onreadystatechange();
                                        if (typeof self.onload === 'function') self.onload();
                                        if (typeof self.onloadend === 'function') self.onloadend();
                                    }
                                } catch (_) {}
                            };
                            if (typeof Promise === 'function') Promise.resolve().then(notifyDone);
                            else if (typeof root.setTimeout === 'function') root.setTimeout(notifyDone, 0);
                            return undefined;
                        }
                        return origSend.apply(this, arguments);
                    };
                }
            """# + "\n"
            switchCases += #"""
                            case 'no-xhr-if': {
                                noXhrFilters.push(compileRequestMatcher(args.length > 0 ? args[0] : ''));
                                ensureNoXhrInstalled();
                                break;
                            }
            """# + "\n"
        }

        if needsJsonPrune {
            helpers += #"""
                function hasNestedPath(node, segs, idx) {
                    if (node === null || node === undefined || typeof node !== 'object') return false;
                    const seg = segs[idx], isLast = idx === segs.length - 1;
                    if (seg === '*' || seg === '[]') {
                        if (seg === '[]' && !Array.isArray(node)) return false;
                        if (Array.isArray(node)) {
                            if (!node.length) return false;
                            if (isLast) return true;
                            for (let i = 0; i < node.length; i++) { if (hasNestedPath(node[i], segs, idx + 1)) return true; }
                            return false;
                        }
                        const keys = Object.keys(node);
                        if (!keys.length) return false;
                        if (isLast) return true;
                        for (let i = 0; i < keys.length; i++) { if (hasNestedPath(node[keys[i]], segs, idx + 1)) return true; }
                        return false;
                    }
                    if (!(seg in node)) return false;
                    return isLast ? true : hasNestedPath(node[seg], segs, idx + 1);
                }
                function pruneNestedPath(node, segs, idx) {
                    if (node === null || node === undefined || typeof node !== 'object') return;
                    const seg = segs[idx], isLast = idx === segs.length - 1;
                    if (seg === '*' || seg === '[]') {
                        if (seg === '[]' && !Array.isArray(node)) return;
                        if (isLast) {
                            if (Array.isArray(node)) node.length = 0;
                            else { const keys = Object.keys(node); for (let i = 0; i < keys.length; i++) delete node[keys[i]]; }
                            return;
                        }
                        if (Array.isArray(node)) { for (let i = 0; i < node.length; i++) pruneNestedPath(node[i], segs, idx + 1); return; }
                        const keys = Object.keys(node);
                        for (let i = 0; i < keys.length; i++) pruneNestedPath(node[keys[i]], segs, idx + 1);
                        return;
                    }
                    if (!(seg in node)) return;
                    if (isLast) delete node[seg];
                    else pruneNestedPath(node[seg], segs, idx + 1);
                }
                function applyPruneRuleList(val, list, reqContext) {
                    if (!val || typeof val !== 'object') return { val: val, mutated: false };
                    let mutated = false;
                    try {
                        for (let i = 0; i < list.length; i++) {
                            const rule = list[i];
                            if (rule.urlMatch && reqContext && !rule.urlMatch(reqContext)) continue;
                            let ok = true;
                            for (let r = 0; r < rule.required.length; r++) {
                                if (!hasNestedPath(val, rule.required[r], 0)) { ok = false; break; }
                            }
                            if (!ok) continue;
                            for (let p = 0; p < rule.paths.length; p++) {
                                if (hasNestedPath(val, rule.paths[p], 0)) {
                                    pruneNestedPath(val, rule.paths[p], 0);
                                    mutated = true;
                                }
                            }
                        }
                    } catch (_) {}
                    return { val: val, mutated: mutated };
                }
                function parsePrunePaths(raw) {
                    const s = String(raw || '').trim();
                    if (!s || s.indexOf('$..') !== -1 || s.indexOf('[-') !== -1) return [];
                    return s.split(/\s+/).filter(Boolean).map(function(p) { return p.split('.'); });
                }
            """# + "\n"
        }

        if usedPrimitives.contains("json-prune") {
            helpers += #"""
                const jsonPruneRules = [];
                let jsonPruneInstalled = false;
                function ensureJsonPruneInstalled() {
                    if (jsonPruneInstalled) return;
                    jsonPruneInstalled = true;
                    if (root.JSON && typeof root.JSON.parse === 'function') {
                        const origParse = root.JSON.parse;
                        root.JSON.parse = function() {
                            const parsed = origParse.apply(this, arguments);
                            return applyPruneRuleList(parsed, jsonPruneRules, null).val;
                        };
                    }
                    if (root.Response && root.Response.prototype && typeof root.Response.prototype.json === 'function') {
                        const origResJson = root.Response.prototype.json;
                        root.Response.prototype.json = function() {
                            return origResJson.apply(this, arguments).then(function(v) { return applyPruneRuleList(v, jsonPruneRules, null).val; });
                        };
                    }
                }
            """# + "\n"
            switchCases += #"""
                            case 'json-prune': {
                                const paths = parsePrunePaths(args[0]);
                                if (!paths.length) break;
                                const required = parsePrunePaths(args.length > 1 ? args[1] : '');
                                jsonPruneRules.push({ paths: paths, required: required, urlMatch: null });
                                ensureJsonPruneInstalled();
                                break;
                            }
            """# + "\n"
        }

        if usedPrimitives.contains("json-prune-fetch-response") {
            helpers += #"""
                const jsonPruneFetchRules = [];
                let jsonPruneFetchInstalled = false;
                function extractUrlFilterFromArgs(args) {
                    if (args.length <= 2) return '';
                    if (args[2] === 'propsToMatch') return args.length > 3 ? String(args[3] || '') : '';
                    return String(args[2] || '');
                }
                function ensureJsonPruneFetchInstalled() {
                    if (jsonPruneFetchInstalled || typeof root.fetch !== 'function') return;
                    jsonPruneFetchInstalled = true;
                    const origFetch = root.fetch;
                    root.fetch = function(input, init) {
                        const url = typeof input === 'string' ? input : (input && typeof input.url === 'string' ? input.url : String(input || ''));
                        const method = String((init && init.method) || (input && input.method) || 'GET').toUpperCase();
                        const reqInfo = { url: url, method: method, body: '', credentials: '', mode: '' };
                        return origFetch.apply(this, arguments).then(function(res) {
                            try {
                                let anyHit = false;
                                for (let i = 0; i < jsonPruneFetchRules.length; i++) {
                                    const r = jsonPruneFetchRules[i];
                                    if (!r.urlMatch || r.urlMatch(reqInfo)) { anyHit = true; break; }
                                }
                                if (!anyHit || !res || typeof res.clone !== 'function') return res;
                                return res.clone().text().then(function(txt) {
                                    const parsed = JSON.parse(txt);
                                    const out = applyPruneRuleList(parsed, jsonPruneFetchRules, reqInfo);
                                    if (!out.mutated) return res;
                                    return new Response(JSON.stringify(out.val), { status: res.status, statusText: res.statusText, headers: res.headers });
                                }).catch(function() { return res; });
                            } catch (_) { return res; }
                        });
                    };
                }
            """# + "\n"
            switchCases += #"""
                            case 'json-prune-fetch-response': {
                                const paths = parsePrunePaths(args[0]);
                                if (!paths.length) break;
                                const required = parsePrunePaths(args.length > 1 ? args[1] : '');
                                const urlSpec = extractUrlFilterFromArgs(args);
                                jsonPruneFetchRules.push({ paths: paths, required: required, urlMatch: urlSpec ? compileRequestMatcher(urlSpec) : null });
                                ensureJsonPruneFetchInstalled();
                                break;
                            }
            """# + "\n"
        }

        if usedPrimitives.contains("json-prune-xhr-response") {
            helpers += #"""
                const jsonPruneXhrRules = [];
                let jsonPruneXhrInstalled = false;
                function ensureJsonPruneXhrInstalled() {
                    if (jsonPruneXhrInstalled || !root.XMLHttpRequest || !root.XMLHttpRequest.prototype) return;
                    jsonPruneXhrInstalled = true;
                    const proto = root.XMLHttpRequest.prototype;
                    const origOpen = proto.open;
                    const rtDesc = Object.getOwnPropertyDescriptor(proto, 'responseText');
                    const rDesc = Object.getOwnPropertyDescriptor(proto, 'response');
                    proto.open = function(method, url) {
                        this.__dysPruneReq = { url: String(url || ''), method: String(method || 'GET').toUpperCase(), body: '', credentials: '', mode: '' };
                        return origOpen.apply(this, arguments);
                    };
                    if (rtDesc && typeof rtDesc.get === 'function') {
                        Object.defineProperty(proto, 'responseText', {
                            configurable: true, enumerable: rtDesc.enumerable,
                            get: function() {
                                const raw = rtDesc.get.call(this);
                                if (!this.__dysPruneReq || !raw || typeof raw !== 'string') return raw;
                                try {
                                    const out = applyPruneRuleList(JSON.parse(raw), jsonPruneXhrRules, this.__dysPruneReq);
                                    return out.mutated ? JSON.stringify(out.val) : raw;
                                } catch (_) { return raw; }
                            }
                        });
                    }
                    if (rDesc && typeof rDesc.get === 'function') {
                        Object.defineProperty(proto, 'response', {
                            configurable: true, enumerable: rDesc.enumerable,
                            get: function() {
                                const raw = rDesc.get.call(this);
                                if (!this.__dysPruneReq || !raw) return raw;
                                try {
                                    if (typeof raw === 'string') {
                                        const out = applyPruneRuleList(JSON.parse(raw), jsonPruneXhrRules, this.__dysPruneReq);
                                        return out.mutated ? JSON.stringify(out.val) : raw;
                                    }
                                    if (typeof raw === 'object') {
                                        return applyPruneRuleList(raw, jsonPruneXhrRules, this.__dysPruneReq).val;
                                    }
                                } catch (_) {}
                                return raw;
                            }
                        });
                    }
                }
            """# + "\n"
            switchCases += #"""
                            case 'json-prune-xhr-response': {
                                const paths = parsePrunePaths(args[0]);
                                if (!paths.length) break;
                                const required = parsePrunePaths(args.length > 1 ? args[1] : '');
                                const urlSpec = (args.length > 2 ? (args[2] === 'propsToMatch' ? (args[3] || '') : args[2]) : '');
                                jsonPruneXhrRules.push({ paths: paths, required: required, urlMatch: urlSpec ? compileRequestMatcher(String(urlSpec)) : null });
                                ensureJsonPruneXhrInstalled();
                                break;
                            }
            """# + "\n"
        }

        if needsStorage {
            helpers += #"""
                const SAFE_STORAGE_LITERALS = new Set([
                    'true','false','yes','no','on','off','accept','accepted','reject','rejected',
                    'denied','granted','allow','allowed','disallow','done','hide','hidden','close','closed',
                    'dismiss','dismissed','ok','none','null','undefined','{}','[]',''
                ]);
                function applyStorageItem(storeObj, key, rawVal, trusted) {
                    if (!storeObj || !key) return;
                    const strVal = rawVal === undefined || rawVal === null ? '' : String(rawVal);
                    if (strVal === '$remove$') { try { storeObj.removeItem(key); } catch (_) {} return; }
                    let mapped = strVal;
                    if (strVal === 'emptyObj') mapped = '{}';
                    else if (strVal === 'emptyArr') mapped = '[]';
                    else if (strVal === 'emptyStr') mapped = '';
                    if (!trusted) {
                        const lower = mapped.toLowerCase();
                        const isSmallInt = /^-?\d{1,5}$/.test(mapped);
                        if (!isSmallInt && !SAFE_STORAGE_LITERALS.has(lower) && !SAFE_STORAGE_LITERALS.has(mapped)) return;
                    }
                    try { storeObj.setItem(key, mapped); } catch (_) {}
                }
            """# + "\n"
            if usedPrimitives.contains("set-local-storage-item") {
                switchCases += #"""
                            case 'set-local-storage-item': {
                                try { applyStorageItem(root.localStorage, String(args[0] || ''), args[1], false); } catch (_) {}
                                break;
                            }
                """# + "\n"
            }
            if usedPrimitives.contains("trusted-set-local-storage-item") {
                switchCases += #"""
                            case 'trusted-set-local-storage-item': {
                                try { applyStorageItem(root.localStorage, String(args[0] || ''), args[1], true); } catch (_) {}
                                break;
                            }
                """# + "\n"
            }
            if usedPrimitives.contains("set-session-storage-item") {
                switchCases += #"""
                            case 'set-session-storage-item': {
                                try { applyStorageItem(root.sessionStorage, String(args[0] || ''), args[1], false); } catch (_) {}
                                break;
                            }
                """# + "\n"
            }
            if usedPrimitives.contains("trusted-set-session-storage-item") {
                switchCases += #"""
                            case 'trusted-set-session-storage-item': {
                                try { applyStorageItem(root.sessionStorage, String(args[0] || ''), args[1], true); } catch (_) {}
                                break;
                            }
                """# + "\n"
            }
        }

        if needsCookies {
            helpers += #"""
                const SAFE_COOKIE_LITERALS = new Set([
                    'true','false','yes','no','on','off','accept','accepted','reject','rejected',
                    'denied','granted','allow','allowed','disallow','done','hide','hidden','close','closed',
                    'dismiss','dismissed','ok','none','all'
                ]);
                function writeCookieRule(name, rawVal, rawPath, trusted, reloadAfter) {
                    if (!root.document || !name || /[;\r\n=]/.test(name)) return;
                    const strVal = rawVal === undefined || rawVal === null ? '' : String(rawVal);
                    if (/[;\r\n]/.test(strVal)) return;
                    if (!trusted) {
                        const lower = strVal.toLowerCase();
                        if (!/^-?\d{1,5}$/.test(strVal) && !SAFE_COOKIE_LITERALS.has(lower)) return;
                    }
                    const cookiePath = (rawPath && rawPath !== 'none') ? String(rawPath) : '/';
                    if (/[;\r\n]/.test(cookiePath)) return;
                    const currentCookies = String(root.document.cookie || '');
                    const needle = name + '=' + strVal;
                    if (currentCookies.indexOf(needle) !== -1) return;
                    try {
                        root.document.cookie = name + '=' + strVal + '; path=' + cookiePath + '; max-age=31536000; SameSite=Lax';
                        if (reloadAfter && root.sessionStorage) {
                            const guardKey = '__dys_ck_rl_' + name;
                            if (!root.sessionStorage.getItem(guardKey)) {
                                root.sessionStorage.setItem(guardKey, '1');
                                if (root.location && typeof root.location.reload === 'function') root.location.reload();
                            }
                        }
                    } catch (_) {}
                }
                function expireMatchingCookies(pattern) {
                    if (!root.document) return;
                    const m = compilePolarizedMatcher(pattern);
                    const pairs = String(root.document.cookie || '').split(';');
                    for (let i = 0; i < pairs.length; i++) {
                        const eq = pairs[i].indexOf('=');
                        const cName = (eq === -1 ? pairs[i] : pairs[i].slice(0, eq)).trim();
                        if (cName && m(cName)) {
                            try {
                                root.document.cookie = cName + '=; expires=Thu, 01 Jan 1970 00:00:00 GMT; max-age=0; path=/';
                            } catch (_) {}
                        }
                    }
                }
            """# + "\n"
            if usedPrimitives.contains("set-cookie") {
                switchCases += #"""
                            case 'set-cookie': {
                                writeCookieRule(String(args[0] || ''), args[1], args[2], false, false);
                                break;
                            }
                """# + "\n"
            }
            if usedPrimitives.contains("set-cookie-reload") {
                switchCases += #"""
                            case 'set-cookie-reload': {
                                writeCookieRule(String(args[0] || ''), args[1], args[2], false, true);
                                break;
                            }
                """# + "\n"
            }
            if usedPrimitives.contains("trusted-set-cookie") {
                switchCases += #"""
                            case 'trusted-set-cookie': {
                                writeCookieRule(String(args[0] || ''), args[1], args[3] || '/', true, false);
                                break;
                            }
                """# + "\n"
            }
            if usedPrimitives.contains("remove-cookie") {
                switchCases += #"""
                            case 'remove-cookie': {
                                const pat = String(args[0] || '');
                                expireMatchingCookies(pat);
                                if (root.document && root.document.readyState === 'loading') {
                                    root.addEventListener('DOMContentLoaded', function() { expireMatchingCookies(pat); }, { once: true });
                                }
                                break;
                            }
                """# + "\n"
            }
        }

        if needsDomAttrClass {
            helpers += #"""
                const domScrubTasks = [];
                let domScrubScheduled = false;
                let domScrubObserverStarted = false;
                function runDomScrub() {
                    domScrubScheduled = false;
                    const doc = root.document;
                    if (!doc) return;
                    for (let i = 0; i < domScrubTasks.length; i++) {
                        const t = domScrubTasks[i];
                        try {
                            const nodes = doc.querySelectorAll(t.selector);
                            for (let n = 0; n < nodes.length; n++) {
                                const el = nodes[n];
                                if (t.isClass) {
                                    for (let k = 0; k < t.tokens.length; k++) {
                                        if (el.classList.contains(t.tokens[k])) el.classList.remove(t.tokens[k]);
                                    }
                                } else {
                                    for (let k = 0; k < t.tokens.length; k++) {
                                        if (el.hasAttribute(t.tokens[k])) el.removeAttribute(t.tokens[k]);
                                    }
                                }
                            }
                        } catch (_) {}
                    }
                }
                function scheduleDomScrub() {
                    if (domScrubScheduled) return;
                    domScrubScheduled = true;
                    if (typeof Promise === 'function') Promise.resolve().then(runDomScrub);
                    else if (typeof root.setTimeout === 'function') root.setTimeout(runDomScrub, 0);
                }
                function startDomScrubObserver() {
                    if (domScrubObserverStarted || !domScrubTasks.length) return;
                    domScrubObserverStarted = true;
                    runDomScrub();
                    const doc = root.document;
                    if (!doc || typeof MutationObserver !== 'function') return;
                    const attrSet = new Set();
                    for (let i = 0; i < domScrubTasks.length; i++) {
                        const t = domScrubTasks[i];
                        if (t.isClass) attrSet.add('class');
                        else for (let k = 0; k < t.tokens.length; k++) attrSet.add(t.tokens[k]);
                    }
                    const obs = new MutationObserver(scheduleDomScrub);
                    obs.observe(doc, { childList: true, subtree: true, attributes: true, attributeFilter: Array.from(attrSet) });
                    if (doc.readyState === 'loading') {
                        root.addEventListener('DOMContentLoaded', runDomScrub, { once: true });
                    }
                }
            """# + "\n"
            if usedPrimitives.contains("remove-attr") {
                switchCases += #"""
                            case 'remove-attr': {
                                const tokens = String(args[0] || '').split('|').map(function(s) { return s.trim(); }).filter(Boolean);
                                if (!tokens.length) break;
                                const esc = (typeof CSS !== 'undefined' && typeof CSS.escape === 'function') ? function(x) { return CSS.escape(x); } : function(x) { return x; };
                                const fallbackSel = tokens.map(function(a) { return '[' + esc(a) + ']'; }).join(',');
                                const sel = (args.length > 1 && String(args[1] || '').trim()) ? String(args[1]).trim() : fallbackSel;
                                domScrubTasks.push({ isClass: false, tokens: tokens, selector: sel });
                                break;
                            }
                """# + "\n"
            }
            if usedPrimitives.contains("remove-class") {
                switchCases += #"""
                            case 'remove-class': {
                                const tokens = String(args[0] || '').split('|').map(function(s) { return s.trim(); }).filter(Boolean);
                                if (!tokens.length) break;
                                const esc = (typeof CSS !== 'undefined' && typeof CSS.escape === 'function') ? function(x) { return CSS.escape(x); } : function(x) { return x; };
                                const fallbackSel = tokens.map(function(c) { return '.' + esc(c); }).join(',');
                                const sel = (args.length > 1 && String(args[1] || '').trim()) ? String(args[1]).trim() : fallbackSel;
                                domScrubTasks.push({ isClass: true, tokens: tokens, selector: sel });
                                break;
                            }
                """# + "\n"
            }
        }

        if usedPrimitives.contains("remove-node-text") {
            helpers += #"""
                const rmntRules = [];
                let rmntInstalled = false;
                function scrubNodeTree(node) {
                    if (!node) return;
                    for (let i = 0; i < rmntRules.length; i++) {
                        const r = rmntRules[i];
                        if (r.nodeMatch(node.nodeName || '') && r.textMatch(node.textContent || '')) {
                            try { node.textContent = ''; } catch (_) {}
                        }
                    }
                    if (node.childNodes && node.childNodes.length) {
                        for (let c = 0; c < node.childNodes.length; c++) scrubNodeTree(node.childNodes[c]);
                    }
                }
                function ensureRmntInstalled() {
                    if (rmntInstalled) return;
                    rmntInstalled = true;
                    const doc = root.document;
                    if (!doc) return;
                    if (doc.documentElement) scrubNodeTree(doc.documentElement);
                    if (typeof MutationObserver === 'function') {
                        const obs = new MutationObserver(function(muts) {
                            for (let m = 0; m < muts.length; m++) {
                                const added = muts[m].addedNodes;
                                for (let a = 0; a < added.length; a++) scrubNodeTree(added[a]);
                            }
                        });
                        obs.observe(doc, { childList: true, subtree: true });
                    }
                }
            """# + "\n"
            switchCases += #"""
                            case 'remove-node-text': {
                                const nodePat = String(args[0] || '');
                                const textPat = args.length > 1 ? String(args[1] || '') : '';
                                if (!nodePat && !textPat) break;
                                const nm = nodePat.charAt(0) === '/' ? compilePolarizedMatcher(nodePat) : function(n) { return String(n || '').toLowerCase() === nodePat.toLowerCase(); };
                                rmntRules.push({ nodeMatch: nm, textMatch: compilePolarizedMatcher(textPat) });
                                ensureRmntInstalled();
                                break;
                            }
            """# + "\n"
        }

        if usedPrimitives.contains("href-sanitizer") {
            helpers += #"""
                const hrefRules = [];
                let hrefSanitizerInstalled = false;
                function sanitizeAnchor(el, rule) {
                    try {
                        const rawHref = el.getAttribute('href') || '';
                        if (!rawHref) return;
                        let extracted = '';
                        const srcSpec = rule.source;
                        if (!srcSpec || srcSpec.charAt(0) === '?') {
                            const paramName = srcSpec ? srcSpec.slice(1) : '';
                            const u = new URL(rawHref, root.location.href);
                            if (paramName) {
                                extracted = u.searchParams.get(paramName) || '';
                            } else {
                                const qIdx = rawHref.indexOf('?http');
                                if (qIdx !== -1) extracted = rawHref.slice(qIdx + 1);
                            }
                        } else if (srcSpec.charAt(0) === '[' && srcSpec.charAt(srcSpec.length - 1) === ']') {
                            extracted = el.getAttribute(srcSpec.slice(1, -1)) || '';
                        } else if (srcSpec === 'text') {
                            extracted = (el.textContent || '').trim();
                        }
                        if (!extracted) return;
                        if (rule.transform.indexOf('base64') !== -1 && typeof root.atob === 'function') {
                            try { extracted = root.atob(extracted); } catch (_) {}
                        }
                        if (rule.transform.indexOf('urldecode') !== -1) {
                            try { extracted = decodeURIComponent(extracted); } catch (_) {}
                        }
                        if (/^https?:\/\//i.test(extracted)) {
                            el.setAttribute('href', extracted);
                        }
                    } catch (_) {}
                }
                function runHrefSanitizerPass() {
                    const doc = root.document;
                    if (!doc) return;
                    for (let i = 0; i < hrefRules.length; i++) {
                        try {
                            const list = doc.querySelectorAll(hrefRules[i].selector);
                            for (let k = 0; k < list.length; k++) sanitizeAnchor(list[k], hrefRules[i]);
                        } catch (_) {}
                    }
                }
                function ensureHrefSanitizerInstalled() {
                    if (hrefSanitizerInstalled) return;
                    hrefSanitizerInstalled = true;
                    root.addEventListener('click', function(ev) {
                        const target = ev && ev.target && typeof ev.target.closest === 'function' ? ev.target.closest('a[href]') : null;
                        if (!target) return;
                        for (let i = 0; i < hrefRules.length; i++) {
                            try { if (target.matches(hrefRules[i].selector)) sanitizeAnchor(target, hrefRules[i]); } catch (_) {}
                        }
                    }, true);
                    if (root.document && root.document.readyState !== 'loading') runHrefSanitizerPass();
                    else root.addEventListener('DOMContentLoaded', runHrefSanitizerPass, { once: true });
                }
            """# + "\n"
            switchCases += #"""
                            case 'href-sanitizer': {
                                const sel = String(args[0] || '').trim();
                                if (!sel) break;
                                hrefRules.push({ selector: sel, source: String(args[1] || '').trim(), transform: String(args[2] || '').toLowerCase() });
                                ensureHrefSanitizerInstalled();
                                break;
                            }
            """# + "\n"
        }

        if usedPrimitives.contains("prevent-element-src-loading") {
            helpers += #"""
                const preventSrcRules = [];
                let preventSrcInstalled = false;
                function shouldBlockElementSrc(tagName, val) {
                    const t = String(tagName || '').toLowerCase(), s = String(val || '');
                    if (!s) return false;
                    for (let i = 0; i < preventSrcRules.length; i++) {
                        const r = preventSrcRules[i];
                        if ((r.tag === '*' || r.tag === t) && r.match(s)) return true;
                    }
                    return false;
                }
                function ensurePreventSrcInstalled() {
                    if (preventSrcInstalled) return;
                    preventSrcInstalled = true;
                    if (root.Element && root.Element.prototype && typeof root.Element.prototype.setAttribute === 'function') {
                        const origSetAttr = root.Element.prototype.setAttribute;
                        root.Element.prototype.setAttribute = function(name, val) {
                            if (String(name || '').toLowerCase() === 'src' && shouldBlockElementSrc(this.tagName, val)) {
                                const el = this;
                                if (typeof root.setTimeout === 'function') root.setTimeout(function() { try { el.dispatchEvent(new Event('load')); } catch (_) {} }, 1);
                                return;
                            }
                            return origSetAttr.apply(this, arguments);
                        };
                    }
                    const protos = [root.HTMLScriptElement, root.HTMLIFrameElement, root.HTMLImageElement, root.HTMLEmbedElement];
                    for (let p = 0; p < protos.length; p++) {
                        const Ctor = protos[p];
                        if (!Ctor || !Ctor.prototype) continue;
                        const d = Object.getOwnPropertyDescriptor(Ctor.prototype, 'src');
                        if (!d || typeof d.set !== 'function' || d.configurable === false) continue;
                        Object.defineProperty(Ctor.prototype, 'src', {
                            configurable: true, enumerable: d.enumerable,
                            get: d.get,
                            set: function(val) {
                                if (shouldBlockElementSrc(this.tagName, val)) {
                                    const el = this;
                                    if (typeof root.setTimeout === 'function') root.setTimeout(function() { try { el.dispatchEvent(new Event('load')); } catch (_) {} }, 1);
                                    return;
                                }
                                d.set.call(this, val);
                            }
                        });
                    }
                }
            """# + "\n"
            switchCases += #"""
                            case 'prevent-element-src-loading': {
                                const rawTag = String(args[0] || '').trim().toLowerCase() || '*';
                                const matchSpec = String(args[1] || '');
                                if (!matchSpec) break;
                                preventSrcRules.push({ tag: rawTag, match: compilePolarizedMatcher(matchSpec) });
                                ensurePreventSrcInstalled();
                                break;
                            }
            """# + "\n"
        }

        if usedPrimitives.contains("noeval-if") {
            helpers += #"""
                const noEvalFilters = [];
                let noEvalInstalled = false;
                function ensureNoEvalInstalled() {
                    if (noEvalInstalled || typeof root.eval !== 'function') return;
                    noEvalInstalled = true;
                    const origEval = root.eval;
                    root.eval = function(code) {
                        const str = String(code || '');
                        for (let i = 0; i < noEvalFilters.length; i++) {
                            if (noEvalFilters[i](str)) return undefined;
                        }
                        return origEval.call(this, code);
                    };
                }
            """# + "\n"
            switchCases += #"""
                            case 'noeval-if': {
                                noEvalFilters.push(compilePolarizedMatcher(args.length > 0 ? args[0] : ''));
                                ensureNoEvalInstalled();
                                break;
                            }
            """# + "\n"
        }

        let rawScript = #"""
        (function() {
            try {
                const root = typeof window !== 'undefined' ? window : globalThis;
                if (!root) return;

                const rawHost = String((root.location && root.location.hostname) || '')
                    .toLowerCase()
                    .replace(/^\.+|\.+$/g, '');
                if (!rawHost) return;

                const RAW_PACK = \#(jsStringLiteral);
                let anySuffixHit = false;
                let probe = rawHost;
                while (probe) {
                    if (RAW_PACK.indexOf('"' + probe + '":[') !== -1) {
                        anySuffixHit = true;
                        break;
                    }
                    const pDot = probe.indexOf('.');
                    if (pDot === -1) break;
                    probe = probe.slice(pDot + 1);
                }
                if (!anySuffixHit) return;

                const PACK = JSON.parse(RAW_PACK);
                const DEFS = PACK.d;
                const RULES = PACK.h;
                const hasOwn = Object.prototype.hasOwnProperty;

                function isHostExcluded(host, excl) {
                    if (!excl || !excl.length) return false;
                    for (let i = 0; i < excl.length; i++) {
                        const ex = excl[i];
                        if (host === ex || host.endsWith('.' + ex)) return true;
                    }
                    return false;
                }

                const matched = [];
                const seenDefs = new Set();
                let suffix = rawHost;
                while (suffix) {
                    if (hasOwn.call(RULES, suffix)) {
                        const bucket = RULES[suffix];
                        for (let i = 0; i < bucket.length; i++) {
                            const defIdx = bucket[i];
                            if (seenDefs.has(defIdx)) continue;
                            const entry = DEFS[defIdx];
                            if (!entry || isHostExcluded(rawHost, entry[2])) continue;
                            seenDefs.add(defIdx);
                            matched.push(entry);
                        }
                    }
                    const dotIdx = suffix.indexOf('.');
                    if (dotIdx === -1) break;
                    suffix = suffix.slice(dotIdx + 1);
                }
                if (!matched.length) return;

                let appliedKeys = root.__dysprosiumAppliedScriptletKeys;
                if (!appliedKeys || typeof appliedKeys !== 'object') {
                    appliedKeys = Object.create(null);
                    try {
                        Object.defineProperty(root, '__dysprosiumAppliedScriptletKeys', {
                            value: appliedKeys,
                            configurable: true,
                            enumerable: false,
                            writable: true
                        });
                    } catch (_) {
                        root.__dysprosiumAppliedScriptletKeys = appliedKeys;
                    }
                }

                const pending = [];
                for (let i = 0; i < matched.length; i++) {
                    const entry = matched[i];
                    const ruleKey = entry[0] + '\u0000' + (entry[1] ? entry[1].join('\u0001') : '');
                    if (appliedKeys[ruleKey]) continue;
                    appliedKeys[ruleKey] = true;
                    pending.push(entry);
                }
                if (!pending.length) return;

                try {
                    Object.defineProperty(root, '__dysprosiumScriptletsApplied', {
                        value: true,
                        configurable: true,
                        enumerable: false,
                        writable: true
                    });
                } catch (_) {
                    root.__dysprosiumScriptletsApplied = true;
                }

                const noopFn = function() {};
        \#(helpers)
                for (let i = 0; i < pending.length; i++) {
                    try {
                        const prim = pending[i][0];
                        const args = pending[i][1] || [];
                        switch (prim) {
        \#(switchCases)
                            default:
                                break;
                        }
                    } catch (_) {}
                }
        \#(needsDomAttrClass ? "startDomScrubObserver();" : "")
            } catch (_) {}
        })();
        """#
        return rawScript
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.drop(while: { $0 == " " || $0 == "\t" }) }
            .joined(separator: "\n")
    }
}
