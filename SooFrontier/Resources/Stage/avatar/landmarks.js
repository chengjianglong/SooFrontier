// Finds face landmarks in an uploaded image, on-device, with MediaPipe Face Landmarker.
// Runs once per upload; the landmarks are saved with the avatar on the hub so other
// devices (your iPhone) don't need to repeat it.

// The iOS app bundles the model for offline use and sets SOOTALKY_FACE_MODEL.
const MODEL_URL = globalThis.SOOTALKY_FACE_MODEL || 'https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/1/face_landmarker.task';
let landmarkerPromise = null;

async function getLandmarker() {
  if (!landmarkerPromise) {
    landmarkerPromise = (async () => {
      const { FaceLandmarker, FilesetResolver } = await import('/vendor/tasks-vision/vision_bundle.mjs');
      const fileset = await FilesetResolver.forVisionTasks('/vendor/tasks-vision/wasm');
      const make = (delegate) =>
        FaceLandmarker.createFromOptions(fileset, {
          baseOptions: { modelAssetPath: MODEL_URL, delegate },
          runningMode: 'IMAGE',
          numFaces: 1,
          minFaceDetectionConfidence: 0.3,
        });
      try {
        return await make('GPU');
      } catch {
        return await make('CPU');
      }
    })();
    landmarkerPromise.catch(() => (landmarkerPromise = null));
  }
  return landmarkerPromise;
}

// Downscales the file to at most 1024px and returns { dataUrl, width, height, landmarks }.
export async function prepareAvatarImage(file) {
  const bitmap = await loadImage(file);
  const scale = Math.min(1, 1024 / Math.max(bitmap.width, bitmap.height));
  const width = Math.round(bitmap.width * scale);
  const height = Math.round(bitmap.height * scale);
  const canvas = document.createElement('canvas');
  canvas.width = width;
  canvas.height = height;
  canvas.getContext('2d').drawImage(bitmap, 0, 0, width, height);

  const landmarker = await getLandmarker();
  const result = landmarker.detect(canvas);
  const face = result.faceLandmarks?.[0];
  if (!face) throw new Error("Couldn't find a face in that image. Try a clear, front-facing portrait with the whole face visible.");
  const landmarks = face.map((p) => [round(p.x), round(p.y)]);
  return { dataUrl: canvas.toDataURL('image/jpeg', 0.9), width, height, landmarks };
}

function round(v) {
  return Math.round(v * 10000) / 10000;
}

function loadImage(file) {
  return new Promise((resolve, reject) => {
    const img = new Image();
    img.onload = () => resolve(img);
    img.onerror = () => reject(new Error('That file could not be opened as an image.'));
    img.src = URL.createObjectURL(file);
  });
}
