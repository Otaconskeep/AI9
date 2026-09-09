const urlInput = document.getElementById("url-input-field");
const maxActiveFetches = document.getElementById("maxactivefetches-input-field");
const showOriginalCheckbox = document.getElementById("showoriginal-checkbox");
const showColorizedCheckbox = document.getElementById("showcolorized-checkbox");
const cacheCheckbox = document.getElementById("cache-checkbox");
const denoiseCheckbox = document.getElementById("denoiser-checkbox");
const colorizeCheckbox = document.getElementById("colorizer-checkbox");
const upscaleCheckbox = document.getElementById("upscaler-checkbox");
const upscaleFactorSelector = document.querySelectorAll("input[name='upscale-factor']");
const upscaleFactorSelector2 = document.getElementById("upscale-factor-2");
const upscaleFactorSelector4 = document.getElementById("upscale-factor-4");
const denoiseSigmaInput = document.getElementById("denoisesigma-input-field");
const colorToleranceInput = document.getElementById("colortolerance-input-field");
const colorStrideInput = document.getElementById("colorstride-input-field");
const websitesInput = document.getElementById("websites-input-field");
const addSiteButton = document.getElementById("addsite");
const runButton = document.getElementById("run");
const testApiButton = document.getElementById("test-api");
const forceRunButton = document.getElementById("force-run");

browser.storage.local.get(["apiURL", "maxActiveFetches", "showOriginal", "showColorized", "cache", "denoise",
                "colorize", "upscale", "denoiseSigma", "upscaleFactor",
                "colorTolerance", "colorStride", "websites"], (result) => {
    urlInput.value = result.apiURL || "https://127.0.0.1:5000/";
    maxActiveFetches.value = result.maxActiveFetches || "1";
    showOriginalCheckbox.checked = result.showOriginal !== undefined ? result.showOriginal : false;
    showColorizedCheckbox.checked = result.showColorized !== undefined ? result.showColorized : true;
    cacheCheckbox.checked = result.cache !== undefined ? result.cache : true;
    denoiseCheckbox.checked = result.denoise !== undefined ? result.denoise : true;
    colorizeCheckbox.checked = result.colorize !== undefined ? result.colorize : true;
    upscaleCheckbox.checked = result.upscale !== undefined ? result.upscale : false;
    if (result.upscaleFactor === '2') {
        upscaleFactorSelector2.checked = true;
    } else if (result.upscaleFactor === '4') {
        upscaleFactorSelector4.checked = true;
    } else {
        upscaleFactorSelector4.checked = true;
    }
    denoiseSigmaInput.value = result.denoiseSigma || "25";
    colorToleranceInput.value = result.colorTolerance || "30";
    colorStrideInput.value = result.colorStride || "4";
    websitesInput.value = result.websites || "www.crunchyroll.com\nmangadex.org/chapter\nchapmanganelo.com\nfanfox.net" +
                            "\nmangakakalot.com\nsenkuro.com\nreadmanga.io\nmanhuatop.org";
    const sitesArray = websitesInput.value.split("\n");
    websitesInput.rows = sitesArray.length + 1
    websitesInput.cols = sitesArray.reduce((len, str) => { return Math.max(len, str.length) }, 25);
    addSiteButton.style.display = "none"
    browser.tabs.query({currentWindow: true, active: true}, (tabs) => {
        if (tabs[0]?.url?.startsWith("http")) {
            const hostname = new URL(tabs[0].url).hostname;
            if (hostname && !websitesInput.value.includes(hostname)) {
                addSiteButton.innerText = "Add " + hostname;
                addSiteButton.removeAttribute("style");
                addSiteButton.addEventListener("click",() => {
                    addSiteButton.style.display = "none"
                    if (websitesInput.value.length > 0 && !websitesInput.value.endsWith("\n"))
                        websitesInput.value += "\n";
                    websitesInput.value += hostname;
                    browser.storage.local.set({websites: websitesInput.value.trim()});
                });
            }
        }
    });
});

function updateVisibility() {
    const showOriginal = showOriginalCheckbox.checked;
    const showColorized = showColorizedCheckbox.checked;

    browser.storage.local.set({
        showOriginal: showOriginalCheckbox.checked,
        showColorized: showColorizedCheckbox.checked,
    });

    browser.tabs.query({active: true, currentWindow: true}, (tabs) => {
        browser.tabs.sendMessage(tabs[0].id, {
            action: 'toggleVisibility',
            showOriginal: showOriginal,
            showColorized: showColorized
        });
    });
}

testApiButton.addEventListener("click",() => {
    browser.tabs.create({url: urlInput.value, active: true});
    browser.storage.local.set({
        apiURL: urlInput.value.trim()
    });
})

runButton.addEventListener("click",() => {
    let selectedUpscaleFactor;
    upscaleFactorSelector.forEach((radio) => {
        if (radio.checked) {
            selectedUpscaleFactor = radio.value;
        }
    });

    browser.storage.local.set({
        apiURL: urlInput.value.trim(),
        maxActiveFetches: maxActiveFetches.value.trim(),
        showOriginal: showOriginalCheckbox.checked,
        showColorized: showColorizedCheckbox.checked,
        cache: cacheCheckbox.checked,
        denoise: denoiseCheckbox.checked,
        colorize: colorizeCheckbox.checked,
        upscale: upscaleCheckbox.checked,
        upscaleFactor: selectedUpscaleFactor,
        denoiseSigma: denoiseSigmaInput.value.trim(),
        colorTolerance: colorToleranceInput.value.trim(),
        colorStride: colorStrideInput.value.trim(),
        websites: websitesInput.value.trim(),
        currentTab: true,
    }); 
    
    browser.tabs.query({active: true, currentWindow: true}, (tabs) => {
        browser.tabs.sendMessage(tabs[0].id, {
            action: 'runColorizer',
        });
    });
})

forceRunButton.addEventListener('click', () => {
    forceRunButton.textContent = "Select an Image";
    forceRunButton.disabled = true
    browser.tabs.query({ active: true, currentWindow: true }, function (tabs) {
        chrome.tabs.sendMessage(tabs[0].id, { action: "startSelectMode" });
    });
});

browser.runtime.onMessage.addListener((request, sender, sendResponse) => {
    if (request.action === "exitSelectMode") {
        forceRunButton.textContent = "Force Colorize!";
        forceRunButton.disabled = false
    }
});

showOriginalCheckbox.addEventListener('change', updateVisibility);
showColorizedCheckbox.addEventListener('change', updateVisibility);

// ---- Color adjustment presets/sliders ----
// Keys and defaults mirror backend/color_adjust.py's DEFAULT_ADJUSTMENTS --
// keep both in sync if either changes.
const ADJUSTMENT_KEYS = ["saturation", "contrast", "brightness", "gamma", "warmth",
    "hueShift", "shadowTintStrength", "magentaReduction", "skinToneWarmth",
    "blackLevel", "highlightSoftness"];
const DEFAULT_ADJUSTMENTS = {
    saturation: 1.0, contrast: 1.0, brightness: 0.0, gamma: 1.0, warmth: 0.0,
    hueShift: 0, shadowTintStrength: 0.0, magentaReduction: 0.0,
    skinToneWarmth: 0.0, blackLevel: 0.0, highlightSoftness: 0.0,
};

const presetSelect = document.getElementById("preset-select");
const activePresetLabel = document.getElementById("active-preset-label");
const resetAdjustmentsButton = document.getElementById("reset-adjustments");
const adjustmentSliders = {};
ADJUSTMENT_KEYS.forEach((key) => {
    adjustmentSliders[key] = {
        input: document.getElementById(`adj-${key}`),
        display: document.getElementById(`adj-${key}-value`),
    };
});

let presetsData = { "Default": DEFAULT_ADJUSTMENTS };
let suppressAdjustmentSave = false;  // avoid feedback loop while programmatically setting sliders

function formatAdjustmentValue(key, value) {
    return key === "hueShift" ? String(Math.round(value)) : Number(value).toFixed(2);
}

function setSlidersFromValues(values) {
    suppressAdjustmentSave = true;
    ADJUSTMENT_KEYS.forEach((key) => {
        const value = values[key] !== undefined ? values[key] : DEFAULT_ADJUSTMENTS[key];
        adjustmentSliders[key].input.value = value;
        adjustmentSliders[key].display.textContent = formatAdjustmentValue(key, value);
    });
    suppressAdjustmentSave = false;
}

function currentSliderValues() {
    const values = {};
    ADJUSTMENT_KEYS.forEach((key) => {
        values[key] = Number(adjustmentSliders[key].input.value);
    });
    return values;
}

function findMatchingPresetName(values) {
    for (const [name, presetValues] of Object.entries(presetsData)) {
        const matches = ADJUSTMENT_KEYS.every((key) =>
            Math.abs((presetValues[key] ?? DEFAULT_ADJUSTMENTS[key]) - values[key]) < 0.001);
        if (matches) return name;
    }
    return "Custom";
}

function saveAdjustments(values, presetName) {
    activePresetLabel.textContent = `Active: ${presetName}`;
    presetSelect.value = presetName in presetsData ? presetName : "";
    browser.storage.local.set({ adjustments: values, activePreset: presetName });
}

fetch(browser.runtime.getURL('presets.json'))
    .then((response) => response.json())
    .then((loadedPresets) => {
        presetsData = loadedPresets;
        return browser.storage.local.get(["adjustments", "activePreset"]);
    })
    .then((result) => {
        const values = result.adjustments || presetsData["Default"] || DEFAULT_ADJUSTMENTS;
        const presetName = result.activePreset || findMatchingPresetName(values);
        setSlidersFromValues(values);
        activePresetLabel.textContent = `Active: ${presetName}`;
        if (presetName in presetsData) presetSelect.value = presetName;
    })
    .catch((err) => console.error('[MC] Failed to load color presets:', err));

presetSelect.addEventListener('change', () => {
    const preset = presetsData[presetSelect.value];
    if (!preset) return;
    setSlidersFromValues(preset);
    saveAdjustments(currentSliderValues(), presetSelect.value);
});

ADJUSTMENT_KEYS.forEach((key) => {
    adjustmentSliders[key].input.addEventListener('input', () => {
        if (suppressAdjustmentSave) return;
        adjustmentSliders[key].display.textContent = formatAdjustmentValue(key, adjustmentSliders[key].input.value);
        const values = currentSliderValues();
        saveAdjustments(values, findMatchingPresetName(values));
    });
});

resetAdjustmentsButton.addEventListener('click', () => {
    const defaults = presetsData["Default"] || DEFAULT_ADJUSTMENTS;
    setSlidersFromValues(defaults);
    saveAdjustments(currentSliderValues(), "Default");
});

