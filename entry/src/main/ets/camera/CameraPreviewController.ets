import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { camera } from '@kit.CameraKit';

export interface CameraPreviewInfo {
  cameraCount: number;
  selectedIndex: number;
  label: string;
}

export class CameraPreviewController {
  private cameraManager?: camera.CameraManager;
  private cameraInput?: camera.CameraInput;
  private previewOutput?: camera.PreviewOutput;
  private session?: camera.Session;

  async start(context: common.BaseContext, surfaceId: string, preferredAspectRatio: number = 3 / 2,
    requestedZoomRatio: number = 1): Promise<CameraPreviewInfo> {
    await this.release();
    try {
      if (!canIUse('SystemCapability.Multimedia.Camera.Core')) {
        throw new Error('当前设备不支持 Camera Kit。');
      }

      this.cameraManager = camera.getCameraManager(context);
      const devices = this.cameraManager.getSupportedCameras();
      if (devices.length === 0) {
        throw new Error('未发现可用手机摄像头。');
      }

      const selectedIndex = this.findBackCameraIndex(devices);
      if (selectedIndex < 0) {
        throw new Error('当前设备没有可用的后置摄像头。');
      }
      const device = devices[selectedIndex];
      this.cameraInput = this.cameraManager.createCameraInput(device);
      await this.cameraInput.open();

      const capability = this.cameraManager.getSupportedOutputCapability(device, camera.SceneMode.NORMAL_PHOTO);
      const previewProfiles = capability.previewProfiles;
      const firstProfile = previewProfiles[0];
      if (!firstProfile) {
        throw new Error('当前摄像头没有可用的预览 Profile。');
      }
      let previewProfile = firstProfile;
      let bestScore = this.aspectScore(firstProfile.size.width, firstProfile.size.height, preferredAspectRatio);
      for (let index = 1; index < previewProfiles.length; index++) {
        const profile = previewProfiles[index];
        const score = this.aspectScore(profile.size.width, profile.size.height, preferredAspectRatio);
        if (score < bestScore) {
          previewProfile = profile;
          bestScore = score;
        }
      }

      this.previewOutput = this.cameraManager.createPreviewOutput(previewProfile, surfaceId);
      this.previewOutput.on('frameStart', (error: BusinessError) => {
        if (error && error.code !== 0) {
          console.error(`Camera preview frameStart failed: ${error.code}`);
        }
      });

      this.session = this.cameraManager.createSession(camera.SceneMode.NORMAL_PHOTO);
      this.session.beginConfig();
      this.session.addInput(this.cameraInput);
      this.session.addOutput(this.previewOutput);
      await this.session.commitConfig();
      await this.session.start();
      const photoSession = this.session as camera.PhotoSession;
      photoSession.setZoomRatio(requestedZoomRatio);

      return {
        cameraCount: devices.length,
        selectedIndex,
        label: this.getCameraLabel(device, selectedIndex)
      };
    } catch (error) {
      await this.release();
      const businessError = error as BusinessError;
      const detail = businessError.message ?? businessError.code ?? '未知错误';
      throw new Error(`Camera Kit 启动失败：${detail}`);
    }
  }

  async release(): Promise<void> {
    try {
      await this.session?.stop();
    } catch (error) {
      console.warn(`Camera session stop failed: ${JSON.stringify(error)}`);
    }
    try {
      await this.session?.release();
    } catch (error) {
      console.warn(`Camera session release failed: ${JSON.stringify(error)}`);
    }
    try {
      await this.previewOutput?.release();
    } catch (error) {
      console.warn(`Camera preview output release failed: ${JSON.stringify(error)}`);
    }
    try {
      await this.cameraInput?.close();
    } catch (error) {
      console.warn(`Camera input close failed: ${JSON.stringify(error)}`);
    }
    this.session = undefined;
    this.previewOutput = undefined;
    this.cameraInput = undefined;
    this.cameraManager = undefined;
  }

  setZoomRatio(zoomRatio: number): boolean {
    try {
      if (!this.session) {
        return false;
      }
      const photoSession = this.session as camera.PhotoSession;
      photoSession.setZoomRatio(zoomRatio);
      return true;
    } catch (error) {
      console.warn(`Camera zoom failed: ${JSON.stringify(error)}`);
      return false;
    }
  }

  private findBackCameraIndex(devices: camera.CameraDevice[]): number {
    for (let index = 0; index < devices.length; index++) {
      if (devices[index].cameraPosition === camera.CameraPosition.CAMERA_POSITION_BACK) {
        return index;
      }
    }
    return -1;
  }

  private getCameraLabel(device: camera.CameraDevice, index: number): string {
    const position = device.cameraPosition === camera.CameraPosition.CAMERA_POSITION_BACK ? '后置' : '前置';
    return `${position}相机 ${index + 1}`;
  }

  private aspectScore(width: number, height: number, preferredAspectRatio: number): number {
    const profileAspectRatio = Math.max(width, height) / Math.min(width, height);
    const targetAspectRatio = Math.max(preferredAspectRatio, 1 / preferredAspectRatio);
    return Math.abs(profileAspectRatio - targetAspectRatio);
  }
}
