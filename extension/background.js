var websites = [];

const setWebsitesFromString = ((str) => {
    if (str) websites = str.split(/[\n,\s+]/)
});

function arrayBufferToBase64(buffer) {
    const bytes = new Uint8Array(buffer);
    const chunk = 0x8000;
    let binary = '';
    for (let i = 0; i < bytes.length; i += chunk) {
        binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunk));
    }
    return btoa(binary);
}

function isLocalhostApi(urlStr) {
    try {
        const u = new URL(urlStr);
        const host = u.hostname.toLowerCase();
        return (host === '127.0.0.1' || host === 'localhost' || host === '[::1]')
            && (u.protocol === 'https:' || u.protocol === 'http:');
    } catch {
        return false;
    }
}

// Content-script fetch() is page-CORS-bound. Cross-origin manga CDNs and the
// localhost colorizer API both fail from a page context without CORS headers.
// Privileged fetches from this background page honor host_permissions and
// bypass page CORS (still localhost-only for the GPU API — no SSRF).
browser.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
    if (msg?.action === 'fetchImageAsDataURL') {
        (async () => {
            const url = String(msg.url || '');
            let parsed;
            try {
                parsed = new URL(url);
            } catch {
                sendResponse({ ok: false, error: 'invalid_url' });
                return;
            }
            if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
                sendResponse({ ok: false, error: 'invalid_scheme' });
                return;
            }
            const originPattern = `${parsed.origin}/*`;
            const hasOrigin = await browser.permissions.contains({ origins: [originPattern] });
            const hasAll = hasOrigin
                ? true
                : await browser.permissions.contains({ origins: ['*://*/*'] });
            if (!hasOrigin && !hasAll) {
                sendResponse({
                    ok: false,
                    error: 'missing_host_permission',
                    origin: parsed.origin,
                    hint: 'Click Colorize! in the AI9 popup once and allow access when Firefox asks.',
                });
                return;
            }
            const resp = await fetch(url, { credentials: 'omit', redirect: 'follow' });
            if (!resp.ok) {
                sendResponse({ ok: false, error: `http_${resp.status}` });
                return;
            }
            const buf = await resp.arrayBuffer();
            if (!buf || buf.byteLength < 8) {
                sendResponse({ ok: false, error: 'empty_body' });
                return;
            }
            const mime = (resp.headers.get('content-type') || 'image/jpeg').split(';')[0].trim() || 'image/jpeg';
            sendResponse({
                ok: true,
                dataUrl: `data:${mime};base64,${arrayBufferToBase64(buf)}`,
            });
        })().catch((err) => {
            sendResponse({ ok: false, error: String(err && err.message ? err.message : err) });
        });
        return true;
    }

    if (msg?.action === 'colorizeImageData') {
        (async () => {
            const apiURL = String(msg.apiURL || '').trim();
            if (!isLocalhostApi(apiURL)) {
                sendResponse({ ok: false, error: 'api_must_be_localhost' });
                return;
            }
            const endpoint = new URL('colorize-image-data', apiURL.endsWith('/') ? apiURL : `${apiURL}/`).toString();
            const resp = await fetch(endpoint, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(msg.postData || {}),
            });
            if (!resp.ok) {
                sendResponse({ ok: false, error: await resp.text(), status: resp.status });
                return;
            }
            sendResponse({ ok: true, json: await resp.json() });
        })().catch((err) => {
            sendResponse({ ok: false, error: String(err && err.message ? err.message : err) });
        });
        return true;
    }

    return undefined;
});

browser.runtime.onInstalled.addListener(({reason}) => {
    if (reason === 'install') {
    browser.tabs.create({
        url: "popup.html"
    });
}
});

const injectContent = ((tab) => {
    if (tab?.url?.startsWith("http") || tab?.url?.startsWith("file")) try {
        console.log("Injecting in", tab.url);
        browser.scripting.executeScript({
            target: {tabId: tab.id, allFrames: false},
            files: ["contentScript.js"]
        })
    } catch {
        console.log("Unable to inject in", tab.url);
    }
});

const injectIfMatches = ((tab) => {
    if (tab?.url?.startsWith("http")
            && websites.some(host => tab.url.includes(host)))
                injectContent(tab);
});

const injectInWebsites = (() => {
    if (websites?.length > 0)
        browser.tabs.query({url: websites.map(host => '*://' + host + '/*')}, (tabs) => {
            tabs.forEach(tab => { injectIfMatches(tab) });
        });
});

const injectInCurrentTab = (() => {
    browser.tabs.query({currentWindow: true, active: true}, (tabs) => {
        injectContent(tabs[0]);
    })
})
async function storageChangeListener(changes, area) {
    if (area === 'local') {
        if (changes?.websites?.newValue) {
            setWebsitesFromString(changes?.websites?.newValue);
            injectInWebsites();
        }
        if (changes?.currentTab?.newValue) {
            injectInCurrentTab();
            browser.storage.local.set({ currentTab: false }); 
        }
    }
};

browser.storage.onChanged.addListener(storageChangeListener);

browser.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
    console.log("tabs.onUpdated", tab.url, JSON.stringify(changeInfo));
    if (changeInfo.url) injectIfMatches(tab);
});
browser.tabs.onCreated.addListener((tab) => {
    console.log("tabs.onCreated", tab.url);
    injectIfMatches(tab);
});

async function initWebsitesAndTabs() {
    return browser.storage.local.get("websites", (result) => {
        console.log('initState', JSON.stringify(result));
        setWebsitesFromString(result.websites);
        console.log('websites', websites);
        injectInWebsites();
    });
};

initWebsitesAndTabs();
