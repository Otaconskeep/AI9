/**
 * Local image selection helpers for the AI9 popup.
 * Pure functions are exported for regression tests (Node can import this module).
 */

export const ACCEPTED_IMAGE_TYPES = Object.freeze([
  'image/png',
  'image/jpeg',
  'image/jpg',
  'image/webp',
  'image/bmp',
  'image/gif',
]);

/** Value for <input type="file" accept="..."> */
export const FILE_INPUT_ACCEPT =
  'image/png,image/jpeg,image/jpg,image/webp,image/bmp,image/gif,.png,.jpg,.jpeg,.webp,.bmp,.gif';

const EXT_MIME = Object.freeze({
  png: 'image/png',
  jpg: 'image/jpeg',
  jpeg: 'image/jpeg',
  webp: 'image/webp',
  bmp: 'image/bmp',
  gif: 'image/gif',
});

export function extensionMime(filename) {
  const name = String(filename || '');
  const dot = name.lastIndexOf('.');
  if (dot < 0) return '';
  return EXT_MIME[name.slice(dot + 1).toLowerCase()] || '';
}

/**
 * Returns null if supported; otherwise a short user-facing reason.
 */
export function unsupportedFileReason(file) {
  if (!file) return 'No file selected.';
  const type = (file.type || '').toLowerCase();
  if (type && ACCEPTED_IMAGE_TYPES.includes(type)) return null;
  const byExt = extensionMime(file.name);
  if (byExt && ACCEPTED_IMAGE_TYPES.includes(byExt)) return null;
  return `Unsupported file type${file.name ? ` (${file.name})` : ''}. Use PNG, JPG, WEBP, BMP, or GIF.`;
}

export function isSupportedImageFile(file) {
  return unsupportedFileReason(file) === null;
}

export function readFileAsDataURL(file) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result || ''));
    reader.onerror = () => reject(reader.error || new Error('Failed to read image file'));
    reader.readAsDataURL(file);
  });
}

export function probeImageDimensions(dataUrl) {
  return new Promise((resolve) => {
    const img = new Image();
    img.onload = () => resolve({ width: img.naturalWidth || img.width || -1, height: img.naturalHeight || img.height || -1 });
    img.onerror = () => resolve({ width: -1, height: -1 });
    img.src = dataUrl;
  });
}

export function buildColorizePostData({
  imgName,
  imgData,
  imgWidth,
  imgHeight,
  cache,
  denoise,
  colorize,
  upscale,
  denoiseSigma,
  upscaleFactor,
  adjustments,
}) {
  return {
    imgName: imgName || 'local-image',
    imgData,
    imgWidth: imgWidth ?? -1,
    imgHeight: imgHeight ?? -1,
    cache: Boolean(cache),
    denoise: Boolean(denoise),
    colorize: colorize !== false,
    upscale: Boolean(upscale),
    denoiseSigma: Number(denoiseSigma) || 25,
    upscaleFactor: Number(upscaleFactor) || 4,
    mangaTitle: 'local',
    mangaChapter: 'upload',
    adjustments: adjustments || null,
  };
}

/**
 * Convert a data URL to a blob: URL suitable for browser.tabs.create
 * (Firefox often blocks data: URLs in new tabs).
 */
export function dataUrlToObjectUrl(dataUrl) {
  const comma = dataUrl.indexOf(',');
  if (comma < 0) throw new Error('Invalid image data URL');
  const meta = dataUrl.slice(0, comma);
  const b64 = dataUrl.slice(comma + 1);
  const mimeMatch = /data:([^;]+)/i.exec(meta);
  const mime = (mimeMatch && mimeMatch[1]) || 'application/octet-stream';
  const binary = atob(b64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return URL.createObjectURL(new Blob([bytes], { type: mime }));
}

/**
 * Wire a button to a hidden file input so a user click opens the OS picker.
 * Must call input.click() synchronously inside the click handler (user gesture).
 *
 * @returns {{ openPicker: function, destroy: function }}
 */
export function attachLocalImageSelect({
  button,
  fileInput,
  statusEl,
  getSettings,
  colorizeFn,
  openResultFn,
  onError,
}) {
  if (!button || !fileInput) {
    throw new Error('attachLocalImageSelect requires button and fileInput');
  }

  fileInput.accept = FILE_INPUT_ACCEPT;
  fileInput.multiple = false;
  // Hidden but not display:none — some browsers refuse programmatic click on display:none inputs.
  fileInput.style.position = 'fixed';
  fileInput.style.left = '-10000px';
  fileInput.style.top = '0';
  fileInput.style.width = '1px';
  fileInput.style.height = '1px';
  fileInput.style.opacity = '0';
  fileInput.tabIndex = -1;

  const setStatus = (msg) => {
    if (statusEl) statusEl.textContent = msg || '';
  };

  const openPicker = () => {
    // Reset value so selecting the same file twice still fires change.
    fileInput.value = '';
    fileInput.click();
  };

  const onButtonClick = (event) => {
    event.preventDefault();
    event.stopPropagation();
    setStatus('');
    openPicker();
  };

  const onFileChange = async () => {
    const file = fileInput.files && fileInput.files[0];
    if (!file) {
      // User cancelled the picker — not an error.
      setStatus('');
      return;
    }

    const reason = unsupportedFileReason(file);
    if (reason) {
      setStatus(reason);
      if (onError) onError(reason);
      fileInput.value = '';
      return;
    }

    button.disabled = true;
    setStatus(`Loading ${file.name}…`);

    try {
      const settings = (typeof getSettings === 'function' ? getSettings() : {}) || {};
      const imgData = await readFileAsDataURL(file);
      if (!imgData || !imgData.startsWith('data:')) {
        throw new Error('Could not read the selected image.');
      }
      const dims = await probeImageDimensions(imgData);
      setStatus(`Colorizing ${file.name}…`);
      const postData = buildColorizePostData({
        imgName: file.name,
        imgData,
        imgWidth: dims.width,
        imgHeight: dims.height,
        ...settings,
      });
      const result = await colorizeFn(postData);
      const colorImgData = result && (result.colorImgData || (result.json && result.json.colorImgData));
      if (!colorImgData) {
        const msg = (result && result.msg) || 'Colorizer returned no image.';
        throw new Error(msg);
      }
      setStatus(`Done: ${file.name}`);
      if (typeof openResultFn === 'function') {
        await openResultFn(colorImgData, file.name);
      }
    } catch (err) {
      const message = err && err.message ? err.message : String(err);
      setStatus(`Error: ${message}`);
      if (onError) onError(message);
    } finally {
      button.disabled = false;
      // Allow re-selecting the same path next time.
      fileInput.value = '';
    }
  };

  button.addEventListener('click', onButtonClick);
  fileInput.addEventListener('change', onFileChange);

  return {
    openPicker,
    destroy() {
      button.removeEventListener('click', onButtonClick);
      fileInput.removeEventListener('change', onFileChange);
    },
  };
}
