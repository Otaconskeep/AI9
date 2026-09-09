// Manga Colorizer - Crunchyroll reader DOM probe
//
// WHY: The extension's page-detection logic (img src changes, canvas
// detection, DOM mutations) was built defensively without ever seeing a
// real, authenticated Crunchyroll Manga reader session -- Crunchyroll
// Manga requires a paid subscription and I have no way to log into your
// account. This script reports the ACTUAL rendering method so the
// extension's detection logic can be tuned with ground truth instead of
// guesses.
//
// HOW TO RUN:
//   1. Open a Crunchyroll manga chapter so a page is fully on screen.
//   2. Open DevTools (F12), go to the Console tab.
//   3. Paste this entire script and press Enter.
//   4. Copy the JSON output that gets printed and send it back.
//   5. Flip to the next page and run `mcProbe()` again (it's left as a
//      global function) to see whether the SAME elements got reused/mutated
//      or whether NEW elements appeared -- that distinction matters for
//      picking the right detection strategy.

function mcProbe() {
    const report = {
        url: location.href,
        title: document.title,
        images: [],
        canvases: [],
        backgroundImageEls: [],
        largeSvgs: [],
    };

    const minW = 300, minH = 400; // rough "this is probably a manga page" filter

    document.querySelectorAll('img').forEach((img, i) => {
        const r = img.getBoundingClientRect();
        if (r.width < minW || r.height < minH) return;
        report.images.push({
            index: i,
            src: (img.src || '').slice(0, 200),
            isBlobUrl: (img.src || '').startsWith('blob:'),
            isDataUrl: (img.src || '').startsWith('data:'),
            srcset: (img.srcset || '').slice(0, 200),
            width: r.width, height: r.height,
            naturalWidth: img.naturalWidth, naturalHeight: img.naturalHeight,
            className: img.className,
            id: img.id,
            crossOrigin: img.crossOrigin,
            parentTag: img.parentElement ? img.parentElement.tagName : null,
            parentClass: img.parentElement ? img.parentElement.className : null,
        });
    });

    document.querySelectorAll('canvas').forEach((c, i) => {
        const r = c.getBoundingClientRect();
        if (r.width < minW || r.height < minH) return;
        let ctxType = 'unknown';
        let taintedCheck = 'not-tested';
        try {
            if (c.getContext('2d')) {
                ctxType = '2d';
                try {
                    c.getContext('2d').getImageData(0, 0, 1, 1);
                    taintedCheck = 'readable (not tainted)';
                } catch (e) {
                    taintedCheck = 'TAINTED: ' + e.message;
                }
            }
        } catch (e) { /* already has a webgl context, getContext('2d') throws */ }
        report.canvases.push({
            index: i,
            width: c.width, height: c.height,
            cssWidth: r.width, cssHeight: r.height,
            className: c.className,
            id: c.id,
            contextType: ctxType,
            readable: taintedCheck,
            parentTag: c.parentElement ? c.parentElement.tagName : null,
            parentClass: c.parentElement ? c.parentElement.className : null,
        });
    });

    document.querySelectorAll('*').forEach((el) => {
        const cs = getComputedStyle(el);
        if (cs.backgroundImage && cs.backgroundImage !== 'none') {
            const r = el.getBoundingClientRect();
            if (r.width < minW || r.height < minH) return;
            report.backgroundImageEls.push({
                tag: el.tagName,
                className: el.className,
                id: el.id,
                backgroundImage: cs.backgroundImage.slice(0, 200),
                width: r.width, height: r.height,
            });
        }
    });

    document.querySelectorAll('svg image, svg foreignObject').forEach((el, i) => {
        const r = el.getBoundingClientRect();
        if (r.width < minW || r.height < minH) return;
        report.largeSvgs.push({ index: i, tag: el.tagName, width: r.width, height: r.height });
    });

    console.log('%c[MC PROBE] Copy everything below this line:', 'color: lime; font-weight: bold; font-size: 14px');
    console.log(JSON.stringify(report, null, 2));
    return report;
}

mcProbe();
