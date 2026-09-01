import { FrameRect, LensSimulation } from '../model/LensSpec';

export class FovCalculator {
  static simulateLens(
    content: FrameRect,
    targetHorizontalFovDeg: number,
    targetVerticalFovDeg: number,
    phoneHorizontalFovDeg: number,
    phoneVerticalFovDeg: number
  ): LensSimulation {
    const widthRatio = FovCalculator.fovRatio(targetHorizontalFovDeg, phoneHorizontalFovDeg);
    const heightRatio = FovCalculator.fovRatio(targetVerticalFovDeg, phoneVerticalFovDeg);
    const isFullyVisible = widthRatio <= 1 && heightRatio <= 1;
    const width = content.width * Math.min(widthRatio, 1);
    const height = content.height * Math.min(heightRatio, 1);
    return {
      frame: {
        left: content.left + (content.width - width) / 2,
        top: content.top + (content.height - height) / 2,
        width,
        height
      },
      isFullyVisible,
      widthRatio,
      heightRatio
    };
  }

  static fitAspect(content: FrameRect, aspectWidth: number, aspectHeight: number): FrameRect {
    const aspect = aspectWidth / aspectHeight;
    const contentAspect = content.width / content.height;
    if (contentAspect > aspect) {
      const width = content.height * aspect;
      return {
        left: content.left + (content.width - width) / 2,
        top: content.top,
        width,
        height: content.height
      };
    }
    const height = content.width / aspect;
    return {
      left: content.left,
      top: content.top + (content.height - height) / 2,
      width: content.width,
      height
    };
  }

  static fovForEquivalentFocalLength(baseFovDeg: number, baseFocalLengthMm: number,
    focalLengthMm: number): number {
    const baseHalfFov = baseFovDeg * Math.PI / 360;
    const focalHalfFov = Math.atan(Math.tan(baseHalfFov) * baseFocalLengthMm / focalLengthMm);
    return focalHalfFov * 360 / Math.PI;
  }

  private static fovRatio(targetFovDeg: number, referenceFovDeg: number): number {
    const target = targetFovDeg * Math.PI / 360;
    const reference = referenceFovDeg * Math.PI / 360;
    return Math.tan(target) / Math.tan(reference);
  }
}
