export interface LensSpec {
  id: string;
  name: string;
  focalLengthLabel: string;
  focalLengthMm: number;
  equivalentFocalLengthLabel: string;
  horizontalFovDeg: number;
  verticalFovDeg: number;
}

export interface FrameRect {
  left: number;
  top: number;
  width: number;
  height: number;
}

export interface AspectRatio {
  width: number;
  height: number;
}

export interface LensSimulation {
  frame: FrameRect;
  isFullyVisible: boolean;
  widthRatio: number;
  heightRatio: number;
}

export interface ZoomOption {
  ratio: number;
  label: string;
  equivalentFocalLengthMm: number;
}

export interface CaptureOrientation {
  id: string;
  label: string;
  widthMm: number;
  heightMm: number;
}
