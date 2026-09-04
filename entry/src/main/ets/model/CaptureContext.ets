export interface CaptureLocation {
  latitude: number;
  longitude: number;
  altitude: number;
  accuracy?: number;
}

export interface CaptureContext {
  captureTimeMs: number;
  location?: CaptureLocation;
  screenWidth: number;
  screenHeight: number;
  phoneZoomRatio: number;
  phoneEquivalentFocalLengthMm: number;
  selectedLensIds: string[];
}
