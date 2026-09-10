'use strict';
if (window.injectedMC !== 1) {
    window.injectedMC = 1;
    console.log('[MC] Starting context script');

    // Dynamic private variables
    var activeFetches = 0;
    var isSelecting = false;

    // Configuration variables
    var apiURL = ''
    var maxActiveFetches = 1;  // Number of images to request and process parallely
    var colorTolerance = 30;  // MSE Cutoff check for an already-colored image
    var colorStride = 4;  // Skip every this many rows and columns pixels for MSE calculation

    var cache = false  // Saves and gets images to and from server if site config set in siteConfig.json
    var denoise = true  // Denoises (remove unnecessary details) the image before processing
    var colorize = true  // Colorizes the image
    var upscale = true  // Upscale the image using super-resolution
    var upscaleFactor = 4  // Image upscale factor x2 or x4
    var denoiseSigma = 25  // Expected noise in image, basically blur strength

    var showOriginal = false  // Shows original image, if processed (colorized)
    var showColorized = true  // Shows processed image, if processed (colorized)

    var adjustments = null  // Color adjustment values (saturation/contrast/warmth/etc, see popup.js); null = server defaults (no-op)

    var siteConfigFile = 'siteConfig.json'  // Manga detail selector queries for organized caching
    let siteConfigurations = null;  // siteConfig.json is loaded in this variable

    // ---- Canvas-reader support ----
    // Some readers (confirmed possible on Crunchyroll Manga; not verifiable
    // without a live authenticated session) draw pages onto a persistent
    // <canvas> element instead of using <img src=...>. A canvas redraw is
    // invisible to MutationObserver -- ctx.drawImage()/putImageData() leave
    // no DOM trace. There is no clean event-driven signal for "this canvas's
    // pixels changed", so as a deliberate, narrow exception we fall back to
    // a low-frequency content-fingerprint poll, scoped ONLY to pages that
    // actually contain qualifying canvases (never runs on <img>-based sites).
    var canvasPollIntervalMs = 1500;
    var canvasPollTimer = null;

    // ---- Initialization functions ----
    function fetchSiteConfigurations() {
        return fetch(browser.runtime.getURL(siteConfigFile))
            .then(response => response.json());
    }
    fetchSiteConfigurations().then(config => {
        siteConfigurations = config
        console.log('[MC] Sites configuration loaded')
    });

    function injectCSS() {
        const css = `
            .isHidden {
                display: none !important;
            }
            .highlight {
                border: 2px solid red !important;
                cursor: crosshair !important;
            }
        `;
        const style = document.createElement('style');
        style.type = 'text/css';
        style.textContent = css;
        document.head.appendChild(style);
    }
    injectCSS();


    // ---- Utility functions ----
    String.prototype.rsplit = function(sep, maxSplit) {
        const split = this.split(sep);
        return maxSplit ? [ split.slice(0, -maxSplit).join(sep) ].concat(split.slice(-maxSplit)) : split;
    }

    function parseQuery(queryString, doc = document) {
        queryString = queryString.trim();

        const querySelectorRegex = /^document\.querySelector(All)?\(['"](.+?)['"]\)/;
        const indexRegex = /\[(\d+)\]/;
        const propertyRegex = /\.(innerText|innerHTML|textContent)$/;

        let queryResult = null;

        try {
            const selectorMatch = queryString.match(querySelectorRegex);
            if (!selectorMatch) throw new Error('Invalid selector format');
            const isAll = Boolean(selectorMatch[1]);
            const selector = selectorMatch[2];

            queryResult = isAll ? doc.querySelectorAll(selector) : doc.querySelector(selector);

            if (isAll) {
                const indexMatch = queryString.match(indexRegex);
                const index = indexMatch[1] !== undefined ? parseInt(indexMatch[1], 10) : 0;
                queryResult = queryResult[index];
            }

            if (!queryResult) return '';

            const propertyMatch = queryString.match(propertyRegex);
            if (propertyMatch && propertyMatch[1]) {
                return queryResult[propertyMatch[1]] || '';
            } else {
                return '';
            }
        } catch (error) {
            console.error(`[MC] Error parsing query: ${queryString}`, error);
            return '';
        }
    }

    const maxDistFromGray = (index, ctx) => {
        const bpp = 4 // Bytes per pixel = number of channels (RGBA)
        const rows = ctx.canvas.height - colorStride * 2;
        const cols = ctx.canvas.width - colorStride * 2;
        // Skip first and last colorStride rows and columns when getting data
        const imageData = ctx.getImageData(colorStride, colorStride, cols, rows);
        const rowStride = colorStride + 1;
        const rowBytes = cols * bpp;
        const pxStride = bpp * (colorStride + 1);
        var maxDist = 0;
        for (let row = 0; row < rows; row += rowStride) {
            const rowStart = row * rowBytes;
            const rowEnd = rowStart + rowBytes;
            for (let i = rowStart; i < rowEnd; i += pxStride) {
                const red = imageData.data[i];
                const green = imageData.data[i + 1];
                const blue = imageData.data[i + 2];
                maxDist = Math.max(Math.abs(red-blue), Math.abs(red-green), Math.abs(blue-green), maxDist)
            }
        }
        console.log(`[MC] [${index}] Max distance from gray: ${maxDist}`);
        return maxDist;
    }

    const canvasContextFromImg = (img) => {
        const imgCanvas = document.createElement("canvas");
        imgCanvas.width = img.width;
        imgCanvas.height = img.height;

        const imgContext = imgCanvas.getContext("2d", { willReadFrequently: true });
        imgContext.drawImage(img, 0, 0, imgCanvas.width, imgCanvas.height);
        return imgContext
    }

    // ColorStride may be added in this, if needed
    const grayscaleMSE = (index, ctx, adjustColorBias = true) => {
        const thumbFactor = 4
        const thumbWidth = Math.floor(ctx.canvas.width / thumbFactor)
        const thumbHeight = Math.floor(ctx.canvas.height / thumbFactor)
        const thumbCanvas = document.createElement('canvas');
        const thumbCtx = thumbCanvas.getContext('2d');
        thumbCanvas.width = thumbWidth;
        thumbCanvas.height = thumbHeight;

        let imageData;
        try {
            thumbCtx.drawImage(ctx.canvas, 0, 0, thumbWidth, thumbHeight);
            imageData = thumbCtx.getImageData(0, 0, thumbWidth, thumbHeight);
        } catch (insecureError) {
            console.log(`[MC] [${index}] isGrayscale check error: ${insecureError}, falling back to isColoredContext`);
            return maxDistFromGray(index, ctx) < colorTolerance
        }
        const data = imageData.data;
        let bias = [0, 0, 0];
        if (adjustColorBias) {
            let sumR = 0, sumG = 0, sumB = 0;
            for (let i = 0; i < data.length; i += 4) {
                sumR += data[i];
                sumG += data[i + 1];
                sumB += data[i + 2];
            }
            const meanR = sumR / (data.length / 4);
            const meanG = sumG / (data.length / 4);
            const meanB = sumB / (data.length / 4);
            const overallMean = (meanR + meanG + meanB) / 3;
            bias = [meanR - overallMean, meanG - overallMean, meanB - overallMean];
        }

        let SSE = 0;   // Sum of Squared Errors (SSE)
        const width = thumbCanvas.width;
        const height = thumbCanvas.height;
        for (let y = 0; y < height; y += 1) {
            for (let x = 0; x < width; x += 1) {
                const index = (y * width + x) * 4;
                const pixel = [data[index], data[index + 1], data[index + 2]];
                const mu = (pixel[0] + pixel[1] + pixel[2]) / 3;
                for (let j = 0; j < 3; j++) {
                    const delta = pixel[j] - mu - bias[j];
                    SSE += delta * delta;
                }
            }
        }

        // Mean Squared Error (MSE)
        const totalPixels = (thumbWidth * thumbHeight);
        const MSE = SSE / totalPixels;

        console.log(`[MC] [${index}] MSE for grayscale check: ${MSE.toFixed(3)}`);
        return MSE;
    };


    // ---- API functions and helpers ----
    async function fetchColorizedImg(index, url, options, img, imgName) {
    console.log(`[MC] [${index}] Fetching: ${imgName}`);
    const savedSrc = img.src
    return fetch(url, options)
        .then(response => {
            if (!response.ok)
                return response.text().then(text => { throw text })
            else
                return response.json()
        })
        .then(json => {
            if (json.msg)
                console.log(`[MC] [${index}] Message: ${json.msg}`);
            if (json.colorImgData) {
                if(img.src != savedSrc){
                    console.log(`[MC] [${index}] Image src changed while request was in progress, invalidating...`)
                    img.removeAttribute('data-is-processed')
                    return;
                }
                const imgClone = img.cloneNode(true);
                img.dataset.isColored = true;
                img.dataset.isProcessed = true;
                imgClone.dataset.isCloned = true;

                img.src = json.colorImgData;
                if (img.dataset?.src) img.dataset.src = '';
                if (img.srcset) img.srcset = '';

                img.parentNode.insertBefore(imgClone, img.nextSibling);

                img.dataset.inView = img.style.display !== 'none'
                imgClone.dataset.inView = imgClone.style.display !== 'none'

                observeImageChanges(img, imgClone);

                console.log(`[MC] [${index}] Processed: ${imgName}`);
                toggleImageVisibility(showOriginal, showColorized)
            }
        })
        .catch(error => {
            console.log(`[MC] [${index}] Fetch error: ${error}`);
        });
    }

    const setColoredOrFetch = (index, img, imgName, apiURL, force, imgContext, mangaProps) => {
        var canSendData = true;
        try {
            const grayMse = grayscaleMSE(index, imgContext);
            const grayDist = maxDistFromGray(index, imgContext);

            const ct = colorTolerance;
            if (!force && (grayMse >= ct*10 || (grayMse >= ct && grayDist!=0))) {
                img.dataset.isColored = true;
                img.dataset.isProcessed = true;
                console.log(`[MC] [${index}] Already colored: ${imgName}`);
                return 1;
            }
        } catch(eIsColor) {
            canSendData = false
            // DOMException.name is standardized as "SecurityError" for a
            // tainted cross-origin canvas on both Chromium and Firefox --
            // .message text is NOT: Chrome says "Failed to execute
            // 'getImageData'...", Firefox says "The operation is insecure."
            // Matching on the Chrome-specific message (the original bug
            // here) silently broke the imgURL fallback below on every
            // Firefox user hitting a cross-origin, non-CORS image source.
            if (eIsColor.name !== 'SecurityError') {
                console.log(`[MC] [${index}] Colorized context error: ${eIsColor}`);
                return 0;
            }
            console.log(`[MC] [${index}] Canvas tainted (cross-origin image, no CORS) -- sending imgURL for server-side fetch instead: ${imgName}`);
        }

        const isAnimated = img.src.includes('animation')
        if (force || activeFetches < maxActiveFetches) {
            activeFetches += 1;
            img.dataset.isProcessed = true;
            const postData = {
                imgName: imgName,
                imgURL: img.src,
                imgWidth: img.width,
				imgHeight: img.height,
				cache: cache && !isAnimated,
				denoise: denoise,
				colorize: colorize,
				upscale: upscale && !isAnimated,
				denoiseSigma: Number(denoiseSigma),
				upscaleFactor: Number(upscaleFactor),

				mangaTitle: mangaProps.title,
				mangaChapter: mangaProps.chapter,
				adjustments: adjustments,
            }

            console.log(`[MC] [${index}] Sending: `, postData);

            if (canSendData)
                postData.imgData = imgContext.canvas.toDataURL("image/png");

            const options = {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json'
                },
                body: JSON.stringify(postData)
            };

            fetchColorizedImg(index, new URL('colorize-image-data', apiURL).toString(), options, img, imgName)
                .finally(() => {
                    activeFetches -= 1;
                    if(!force) colorizeMangaEventHandler();
                });
            return 3
        } else {
            return 2;
        }
    }

    const colorizeImg = (index, img, apiURL, force, mangaProps) => {
        if (apiURL) try {
            const imageName = mangaProps.altText ? img.alt : ''
            const imgName = imageName || (img.src || img.dataset?.src || '').rsplit('/', 1)[1];
            if (imgName) {
                let imgContext = canvasContextFromImg(img);
                return setColoredOrFetch(index, img, imgName, apiURL, force, imgContext, mangaProps);
            }
            return 0;
        } catch(e) {
            console.log(`[MC] [${index}] Colorize image error: ${e}`)
            return 0;
        }
    }

    // ---- Canvas-reader functions (mirror the <img> path above) ----
    // Unlike <img>, a canvas has no "src" to swap and no natural way to keep
    // an untouched original alongside the colorized version without a second
    // hidden canvas -- colorization happens in place. showOriginal/showColorized
    // toggling therefore does not apply to canvas-rendered pages.
    //
    // canvasOriginalSnapshots preserves the pre-colorization pixels (captured
    // right before the first colorize request) so that changing a color
    // preset/slider later can re-derive from the true original instead of
    // re-processing an already-colorized canvas -- see reapplyToCanvas().
    const canvasOriginalSnapshots = new WeakMap();
    let canvasNameCounter = 0;

    async function fetchColorizedCanvas(index, url, options, canvas, canvasName) {
        console.log(`[MC] [${index}] Fetching (canvas): ${canvasName}`);
        return fetch(url, options)
            .then(response => {
                if (!response.ok)
                    return response.text().then(text => { throw text })
                else
                    return response.json()
            })
            .then(json => {
                if (json.msg)
                    console.log(`[MC] [${index}] Message: ${json.msg}`);
                if (json.colorImgData) {
                    const resultImg = new Image();
                    resultImg.onload = () => {
                        const ctx = canvas.getContext('2d');
                        ctx.clearRect(0, 0, canvas.width, canvas.height);
                        ctx.drawImage(resultImg, 0, 0, canvas.width, canvas.height);
                        canvas.dataset.isColored = true;
                        canvas.dataset.isProcessed = true;
                        // Baseline the fingerprint to our own redraw so the
                        // fallback poll doesn't mistake it for a new page.
                        canvas.dataset.mcFingerprint = canvasFingerprint(canvas) || '';
                        console.log(`[MC] [${index}] Processed (canvas): ${canvasName}`);
                    };
                    resultImg.onerror = () => {
                        console.log(`[MC] [${index}] Failed to draw colorized result onto canvas: ${canvasName}`);
                    };
                    resultImg.src = json.colorImgData;
                }
            })
            .catch(error => {
                console.log(`[MC] [${index}] Fetch error (canvas): ${error}`);
            });
    }

    const setCanvasColoredOrFetch = (index, canvas, canvasName, apiURL, force, ctx, mangaProps) => {
        var canSendData = true;
        try {
            const grayMse = grayscaleMSE(index, ctx);
            const grayDist = maxDistFromGray(index, ctx);

            const ct = colorTolerance;
            if (!force && (grayMse >= ct*10 || (grayMse >= ct && grayDist!=0))) {
                canvas.dataset.isColored = true;
                canvas.dataset.isProcessed = true;
                console.log(`[MC] [${index}] Already colored (canvas): ${canvasName}`);
                return 1;
            }
        } catch(eIsColor) {
            canSendData = false
            // See the matching comment in setColoredOrFetch: .name (not
            // .message) is the cross-browser-correct check for this.
            if (eIsColor.name !== 'SecurityError') {
                console.log(`[MC] [${index}] Colorized context error (canvas): ${eIsColor}`);
                return 0;
            }
        }

        if (!canSendData) {
            console.log(`[MC] [${index}] Canvas is tainted (cross-origin content without CORS) -- cannot read pixels: ${canvasName}`);
            return 0;
        }

        if (force || activeFetches < maxActiveFetches) {
            activeFetches += 1;
            canvas.dataset.isProcessed = true;

            let imgData;
            try {
                imgData = canvas.toDataURL("image/png");
            } catch (e) {
                console.log(`[MC] [${index}] toDataURL failed (tainted canvas): ${canvasName}: ${e}`);
                activeFetches -= 1;
                canvas.removeAttribute('data-is-processed');
                return 0;
            }
            if (!canvasOriginalSnapshots.has(canvas)) {
                canvasOriginalSnapshots.set(canvas, imgData);  // pre-colorization pixels, for later re-adjustment
            }

            const postData = {
                imgName: canvasName,
                imgData: imgData,
                imgWidth: canvas.width,
                imgHeight: canvas.height,
                cache: cache,
                denoise: denoise,
                colorize: colorize,
                upscale: upscale,
                denoiseSigma: Number(denoiseSigma),
                upscaleFactor: Number(upscaleFactor),

                mangaTitle: mangaProps.title,
                mangaChapter: mangaProps.chapter,
                adjustments: adjustments,
            }

            console.log(`[MC] [${index}] Sending (canvas): `, postData);

            const options = {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(postData)
            };

            fetchColorizedCanvas(index, new URL('colorize-image-data', apiURL).toString(), options, canvas, canvasName)
                .finally(() => {
                    activeFetches -= 1;
                    if(!force) colorizeMangaEventHandler();
                });
            return 3
        } else {
            return 2;
        }
    }

    const colorizeCanvas = (index, canvas, apiURL, force, mangaProps) => {
        if (!apiURL) return 0;
        try {
            const ctx = canvas.getContext('2d');
            if (!ctx) {
                // Likely a WebGL/bitmaprenderer canvas -- unsupported (cheap to
                // recheck later in case the reader swaps context types).
                return 0;
            }
            if (!canvas.dataset.mcName) {
                canvas.dataset.mcName = `canvas-${canvasNameCounter++}`;
            }
            const canvasName = canvas.dataset.mcName;
            return setCanvasColoredOrFetch(index, canvas, canvasName, apiURL, force, ctx, mangaProps);
        } catch(e) {
            console.log(`[MC] [${index}] Colorize canvas error: ${e}`)
            return 0;
        }
    }

    // Cheap content fingerprint: sample a small fixed grid of pixels rather
    // than reading the whole canvas, so polling stays lightweight.
    function canvasFingerprint(canvas) {
        try {
            const ctx = canvas.getContext('2d');
            if (!ctx || canvas.width === 0 || canvas.height === 0) return null;
            const sampleW = Math.min(16, canvas.width);
            const sampleH = Math.min(16, canvas.height);
            const data = ctx.getImageData(0, 0, sampleW, sampleH).data;
            let hash = 0;
            for (let i = 0; i < data.length; i += 8) {  // every other pixel
                hash = (hash * 31 + data[i]) | 0;
            }
            return `${canvas.width}x${canvas.height}:${hash}`;
        } catch (e) {
            return null;  // tainted canvas -- polling can't help here either
        }
    }

    function qualifyingCanvases() {
        const minImgHeight = Math.min(200, window.innerHeight/2);
        const minImgWidth = Math.min(400, window.innerWidth/2);
        return Array.from(document.querySelectorAll('canvas')).filter(c =>
            c.width >= minImgWidth && c.height >= minImgHeight);
    }

    function pollCanvases() {
        const canvases = qualifyingCanvases();
        let changed = false;
        canvases.forEach(canvas => {
            if (!canvas.dataset.isProcessed) return;  // not our concern yet, normal scan handles it
            const fp = canvasFingerprint(canvas);
            if (fp === null) return;
            if (canvas.dataset.mcFingerprint && canvas.dataset.mcFingerprint !== fp) {
                console.log(`[MC] Canvas content changed without a DOM mutation (site redrew in place): ${canvas.dataset.mcName}`);
                canvas.removeAttribute('data-is-processed');
                canvas.removeAttribute('data-is-colored');
                changed = true;
            }
            canvas.dataset.mcFingerprint = fp;
        });
        if (changed) colorizeMangaEventHandler();
    }

    function startCanvasPollingIfNeeded() {
        const hasCanvases = qualifyingCanvases().length > 0;
        if (hasCanvases && !canvasPollTimer) {
            console.log('[MC] Qualifying <canvas> reader detected, starting fallback content-change poll (no DOM event exists for in-place canvas redraws)');
            canvasPollTimer = setInterval(pollCanvases, canvasPollIntervalMs);
        } else if (!hasCanvases && canvasPollTimer) {
            clearInterval(canvasPollTimer);
            canvasPollTimer = null;
        }
    }

    // ---- Select mode functions ----
    function enterSelectMode() {
        isSelecting = true;

        document.addEventListener('mouseover', highlightImage);
        document.addEventListener('mouseout', removeHighlight);
        document.addEventListener('click', selectImage);
    }

    function isValidImageElement(element) {
        return element.tagName.toLowerCase() === 'img' && !element.dataset.isCloned
    }

    function highlightImage(event) {
        if (!isSelecting) return;

        const element = event.target;
        if (isValidImageElement(element)) {
            element.classList.add('highlight');
        }
    }

    function removeHighlight(event) {
        if (!isSelecting) return;

        const element = event.target;
        if (isValidImageElement(element)) {
            element.classList.remove('highlight');
        }
    }

    function selectImage(event) {
        if (!isSelecting) return;

        event.preventDefault();
        event.stopPropagation();
        const element = event.target;

        if (isValidImageElement(element)) {
            colorizeSingleImage(element);
            exitSelectMode();
        } else {
            exitSelectMode();
        }
    }

    function exitSelectMode() {
        isSelecting = false;
        removeAllHighlights();
        document.removeEventListener('mouseover', highlightImage);
        document.removeEventListener('mouseout', removeHighlight);
        document.removeEventListener('click', selectImage);

        browser.runtime.sendMessage({ action: "exitSelectMode" });
        console.log('[MC] Exited select mode')
    }

    function removeAllHighlights() {
        const highlightedElements = document.getElementsByClassName('highlight');
        while (highlightedElements.length > 0) {
            highlightedElements[0].classList.remove('highlight');
        }
    }

    function colorizeSingleImage(img) {
        console.log('[MC] Force colorize: ', img.src)

        const imgSrc = img.src;
        const imgs = document.querySelectorAll(`img[src="${imgSrc}"]`);
        imgs.forEach((imgElement) => {
            if(imgElement.dataset.isCloned){
                imgElement.remove();
            }
            if(imgElement.dataset.isProcessed){
                imgElement.removeAttribute('data-is-colored');
            }
            if(imgElement.dataset.isProcessed){
                console.log('[MC] A colorized image is being re-colorized')
                imgElement.removeAttribute('data-is-processed');
            }
        });

        const site = Object.keys(siteConfigurations).find(site => window.location.hostname.includes(site));
        const config = siteConfigurations[site];
        const title = site ? parseQuery(config.titleQuery) : '';
        const chapter = site ? parseQuery(config.chapterQuery) : '';
        const pageNameFromAltText = site ? config.useAltTextAsImageName : false

        const mangaProps = {title: title, chapter: chapter, altText: pageNameFromAltText}
        let status = colorizeImg(0, img, apiURL, true, mangaProps);
        console.log('[MC] Force colorization status: ', status)
    }

    // ---- Extension interface functions ----
    const colorizeMangaEventHandler = (event=null) => {
        try {
            browser.storage.local.get(["apiURL", "maxActiveFetches", "showOriginal", "showColorized", "cache", "denoise", "colorize", "upscale", "denoiseSigma", "upscaleFactor",
                "colorTolerance", "colorStride", "minImgHeight", "minImgHeight", "adjustments"], (result) => {
                apiURL = result.apiURL;
                if (apiURL && siteConfigurations) {
                    maxActiveFetches = Number(result.maxActiveFetches || "1")
                    showOriginal = result.showOriginal
                    showColorized = result.showColorized
                    adjustments = result.adjustments || null

                    cache = result.cache
                    denoise = result.denoise
                    colorize = result.colorize
                    upscale = result.upscale
                    denoiseSigma = result.denoiseSigma || "25"
                    upscaleFactor = result.upscaleFactor || "4"

                    const storedColorTolerance = result.colorTolerance;
                    const storedColorStride = result.colorStride;
                    const minImgHeight = Math.min(result.minImgHeight || 200, window.innerHeight/2);
                    const minImgWidth = Math.min(result.minImgWidth || 400, window.innerWidth/2);

                    if (storedColorTolerance > -1) colorTolerance = storedColorTolerance;
                    if (storedColorStride > -1) colorStride = storedColorStride;

                    const site = Object.keys(siteConfigurations).find(site => window.location.hostname.includes(site));
                    const config = siteConfigurations[site];
                    const title = site ? parseQuery(config.titleQuery) : '';
                    const chapter = site ? parseQuery(config.chapterQuery) : '';
                    const pageNameFromAltText = site ? config.useAltTextAsImageName : false

                    console.log(`[MC] Website: ${site}, Title: ${title}, Chapter: ${chapter}`)
                    console.log('[MC] Scanning images...')
                    toggleImageVisibility(showOriginal, showColorized)

                    let total = 0;
                    let skipped = 0;
                    let colored = 0;
                    let failed = 0;
                    let awaited = 0;
                    let processing = 0;

                    const images = document.querySelectorAll('img');
                    total= images.length;

                    images.forEach((img, index) => {
                        if (img.dataset.isCloned) {
                            return  // continue
                        } else if (img.dataset.isProcessed && img.dataset.isColored) {
                            colored++
                        } else if(img.dataset.isProcessed && !img.dataset.isColored){
                            failed++
                        } else if (img.dataset.isProcessed){
                            processing++
                        } else if (!img.complete || !img.src) {
                            img.addEventListener('load', colorizeMangaEventHandler, { passive: true });
                            total--
                        } else if (img.width > 0 && img.width < minImgWidth || img.height > 0 && img.height < minImgHeight) {
                            skipped++
                        } else if (activeFetches >= maxActiveFetches){
                            awaited++
                        } else {
                            const mangaProps = {title: title, chapter: chapter, altText: pageNameFromAltText}
                            let status = colorizeImg(index, img, apiURL, false, mangaProps);
                            switch(status){
                                case 0: failed++; break;
                                case 1: colored++; break;
                                case 2: awaited++; break;
                                case 3: processing++; break;
                            }
                        }
                    });

                    // Same pass, but for <canvas>-rendered readers (Crunchyroll's
                    // reader implementation was not verifiable ahead of time --
                    // this path is a no-op with zero overhead on sites that don't
                    // use canvas rendering).
                    const canvases = document.querySelectorAll('canvas');
                    canvases.forEach((canvas, index) => {
                        if (canvas.width < minImgWidth || canvas.height < minImgHeight) return;
                        total++
                        if (canvas.dataset.isProcessed && canvas.dataset.isColored) {
                            colored++
                        } else if (canvas.dataset.isProcessed && !canvas.dataset.isColored) {
                            failed++
                        } else if (canvas.dataset.isProcessed) {
                            processing++
                        } else if (activeFetches >= maxActiveFetches) {
                            awaited++
                        } else {
                            const mangaProps = {title: title, chapter: chapter, altText: false}
                            let status = colorizeCanvas(index, canvas, apiURL, false, mangaProps);
                            switch(status){
                                case 0: failed++; break;
                                case 1: colored++; break;
                                case 2: awaited++; break;
                                case 3: processing++; break;
                            }
                        }
                    });
                    startCanvasPollingIfNeeded();

                    console.log(`[MC] Report: Processing=${processing} Success=${colored} Skipped=${skipped} Failed=${failed} Awaited=${awaited} Total=${total}`)
                }
            });
        } catch (err) {
            if (err.toString().includes('Extension context invalidated')) {
                console.log('[MC] Extension reloaded, stopping old version');
                window.injectedMC = undefined;
                observer?.disconnect();
                if (canvasPollTimer) clearInterval(canvasPollTimer);
            } else {
                console.error('[MC] Error: ', err);
            }
        }
    }

    // ---- Re-apply color adjustments to already-colorized pages ----
    // Changing a preset/slider previously did nothing on a page that was
    // already colorized: colorizeMangaEventHandler skips anything with
    // data-is-processed=true, by design (it's a "find new work" scan, not a
    // "redo existing work" one). This is the dedicated "redo existing work"
    // path, triggered by popup.js on every adjustment change. It re-derives
    // from the preserved ORIGINAL pixels (the hidden clone for <img>, the
    // WeakMap snapshot for <canvas>) rather than the currently-displayed
    // colorized image, and reuses the same mangaTitle/mangaChapter so the
    // request lands on the server's raw-GPU-output cache tier and skips the
    // model entirely -- only the cheap adjustment step re-runs.
    function getMangaProps() {
        const site = siteConfigurations && Object.keys(siteConfigurations).find(s => window.location.hostname.includes(s));
        const config = site ? siteConfigurations[site] : null;
        return {
            title: site ? parseQuery(config.titleQuery) : '',
            chapter: site ? parseQuery(config.chapterQuery) : '',
            altText: site ? config.useAltTextAsImageName : false,
        };
    }

    function reapplyToImg(liveImg, cloneImg) {
        let imgContext;
        try {
            imgContext = canvasContextFromImg(cloneImg);
        } catch (e) {
            console.log('[MC] Reapply (img): cannot read original pixels:', e);
            return Promise.resolve();
        }
        const mangaProps = getMangaProps();
        const isAnimated = liveImg.src.includes('animation');
        const postData = {
            imgName: liveImg.alt || 'reapply',
            imgWidth: cloneImg.width || liveImg.width,
            imgHeight: cloneImg.height || liveImg.height,
            cache: cache && !isAnimated,
            denoise: denoise,
            colorize: colorize,
            upscale: upscale && !isAnimated,
            denoiseSigma: Number(denoiseSigma),
            upscaleFactor: Number(upscaleFactor),
            mangaTitle: mangaProps.title,
            mangaChapter: mangaProps.chapter,
            adjustments: adjustments,
            imgData: imgContext.canvas.toDataURL("image/png"),
        };
        const options = { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(postData) };
        return fetch(new URL('colorize-image-data', apiURL).toString(), options)
            .then(response => response.ok ? response.json() : response.text().then(t => { throw t }))
            .then(json => {
                if (json.colorImgData) {
                    liveImg.src = json.colorImgData;
                    console.log('[MC] Reapplied adjustments to image');
                } else if (json.msg) {
                    console.log('[MC] Reapply (img) message:', json.msg);
                }
            })
            .catch(err => console.log('[MC] Reapply (img) error:', err));
    }

    function reapplyToCanvas(canvas, originalDataUrl) {
        const mangaProps = getMangaProps();
        const postData = {
            imgName: canvas.dataset.mcName || 'reapply-canvas',
            imgData: originalDataUrl,
            imgWidth: canvas.width,
            imgHeight: canvas.height,
            cache: cache,
            denoise: denoise,
            colorize: colorize,
            upscale: upscale,
            denoiseSigma: Number(denoiseSigma),
            upscaleFactor: Number(upscaleFactor),
            mangaTitle: mangaProps.title,
            mangaChapter: mangaProps.chapter,
            adjustments: adjustments,
        };
        const options = { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(postData) };
        return fetch(new URL('colorize-image-data', apiURL).toString(), options)
            .then(response => response.ok ? response.json() : response.text().then(t => { throw t }))
            .then(json => {
                if (json.colorImgData) {
                    const resultImg = new Image();
                    resultImg.onload = () => {
                        const ctx = canvas.getContext('2d');
                        ctx.clearRect(0, 0, canvas.width, canvas.height);
                        ctx.drawImage(resultImg, 0, 0, canvas.width, canvas.height);
                        canvas.dataset.mcFingerprint = canvasFingerprint(canvas) || '';
                    };
                    resultImg.src = json.colorImgData;
                    console.log('[MC] Reapplied adjustments to canvas');
                } else if (json.msg) {
                    console.log('[MC] Reapply (canvas) message:', json.msg);
                }
            })
            .catch(err => console.log('[MC] Reapply (canvas) error:', err));
    }

    let reapplyQueue = [];

    function processReapplyQueue() {
        while (reapplyQueue.length > 0 && activeFetches < maxActiveFetches) {
            const item = reapplyQueue.shift();
            activeFetches += 1;
            const done = () => { activeFetches -= 1; processReapplyQueue(); };
            (item.type === 'img' ? reapplyToImg(item.live, item.source) : reapplyToCanvas(item.live, item.source)).finally(done);
        }
    }

    function reapplyAdjustments() {
        if (!apiURL) return;
        reapplyQueue = [];
        document.querySelectorAll('img[data-is-colored="true"]:not([data-is-cloned])').forEach((liveImg) => {
            const cloneImg = liveImg.nextElementSibling;
            if (cloneImg && cloneImg.dataset.isCloned) reapplyQueue.push({ type: 'img', live: liveImg, source: cloneImg });
        });
        document.querySelectorAll('canvas[data-is-colored="true"]').forEach((canvas) => {
            const original = canvasOriginalSnapshots.get(canvas);
            if (original) reapplyQueue.push({ type: 'canvas', live: canvas, source: original });
        });
        console.log(`[MC] Re-applying adjustments to ${reapplyQueue.length} already-colorized element(s)`);
        processReapplyQueue();
    }

    function toggleImageVisibility(showOriginal, showColorized) {
        const coloredImages = document.querySelectorAll('img[data-is-colored="true"][data-in-view="true"]');
        const clonedImages = document.querySelectorAll('img[data-is-cloned="true"][data-in-view="true"]');

        coloredImages.forEach(img => {
            showColorized ? img.classList.remove('isHidden') : img.classList.add('isHidden')
        });

        clonedImages.forEach(img => {
            showOriginal ? img.classList.remove('isHidden') : img.classList.add('isHidden')
        });
    }

    browser.runtime.onMessage.addListener((request, sender, sendResponse) => {
        if (request.action === 'toggleVisibility') {
            console.log('[MC] Image visibility toggled')
            toggleImageVisibility(request.showOriginal, request.showColorized);
        }
        if (request.action === 'runColorizer'){
            console.log('[MC] Running colorizer')
            colorizeMangaEventHandler();
        }
        if(request.action === 'startSelectMode') {
            console.log('[MC] Entered select mode')
            enterSelectMode();
        }
        if (request.action === 'reapplyAdjustments') {
            // Refresh from storage rather than trusting module-level vars --
            // popup.js just wrote new values and this can fire before any
            // full colorizeMangaEventHandler scan has refreshed them.
            browser.storage.local.get(["apiURL", "cache", "denoise", "colorize", "upscale",
                "denoiseSigma", "upscaleFactor", "adjustments"], (result) => {
                apiURL = result.apiURL;
                cache = result.cache;
                denoise = result.denoise;
                colorize = result.colorize;
                upscale = result.upscale;
                denoiseSigma = result.denoiseSigma || "25";
                upscaleFactor = result.upscaleFactor || "4";
                adjustments = result.adjustments || null;
                reapplyAdjustments();
            });
        }
        sendResponse({status: 'done'});
    });


    // ---- Observer functions ----
    function observeImageChanges(originalImg, clonedImg) {
        const handleMutation = (mutationsList) => {
            mutationsList.forEach((mutation) => {
                if (mutation.type === 'attributes' && mutation.attributeName === 'style') {
                    clonedImg.style.cssText = originalImg.style.cssText;

                    if (originalImg.style.display !== 'none'){
                        originalImg.dataset.inView = true
                        clonedImg.dataset.inView = true
                    } else if(originalImg.style.display === 'none'){
                        originalImg.dataset.inView = false
                        clonedImg.dataset.inView = false
                    }
                }

                if (mutation.type === 'attributes' && mutation.attributeName === 'src') {
                    clonedImg.remove();
                    originalImg.removeAttribute('data-is-processed')
                    originalImg.removeAttribute('data-is-colored')

                    colorizeMangaEventHandler()
                }

                if (mutation.type === 'childList') {
                    mutation.removedNodes.forEach((node) => {
                        if (node === originalImg) {
                            clonedImg.remove();
                            observer.disconnect();
                        }
                    });
                }
            });
        };

        const observer = new MutationObserver(handleMutation);
        observer.observe(originalImg, { attributes: true, attributeFilter: ['style', 'src'] });
        observer.observe(originalImg.parentNode, { childList: true });
        originalImg._observer = observer;
    }

    colorizeMangaEventHandler();

    const observer = new MutationObserver(colorizeMangaEventHandler);
    observer.observe(document.querySelector("body"), { subtree: true, childList: true });

    // SPA route changes (History API) don't always coincide with an
    // immediately-observable DOM mutation in the same tick on every
    // framework. Re-scanning on navigation is cheap (a no-op if nothing
    // changed) and closes that gap without resorting to polling.
    for (const fn of ['pushState', 'replaceState']) {
        const original = history[fn];
        history[fn] = function (...args) {
            const result = original.apply(this, args);
            window.dispatchEvent(new Event('mc-locationchange'));
            return result;
        };
    }
    window.addEventListener('popstate', () => window.dispatchEvent(new Event('mc-locationchange')));
    window.addEventListener('mc-locationchange', () => {
        console.log('[MC] Navigation detected, re-scanning');
        colorizeMangaEventHandler();
    });
};
