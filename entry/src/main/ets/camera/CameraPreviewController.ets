import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { camera } from '@kit.CameraKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { CaptureLocation } from '../model/CaptureContext';

export interface CameraPreviewInfo {
  cameraCount: number;
  selectedIndex: number;
  label: string;
}

export type PhotoSavedCallback = (photoAsset: photoAccessHelper.PhotoAsset) => void;

export class CameraPreviewController {
  private cameraManager?: camera.CameraManager;
  private cameraInput?: camera.CameraInput;
  private previewOutput?: camera.PreviewOutput;
  private photoOutput?: camera.PhotoOutput;
  private session?: camera.Session;
  private photoSavedCallback?: PhotoSavedCallback;

  setPhotoSavedCallback(callback: PhotoSavedCallback): void {
    this.photoSavedCallback = callback;
  }

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

      const photoProfile = capability.photoProfiles[0];
      if (!photoProfile) {
        throw new Error('当前摄像头没有可用的拍照 Profile。');
      }
      this.photoOutput = this.cameraManager.createPhotoOutput(photoProfile);
      this.photoOutput.on('photoAssetAvailable', this.onPhotoAssetAvailable);

      this.session = this.cameraManager.createSession(camera.SceneMode.NORMAL_PHOTO);
      this.session.beginConfig();
      this.session.addInput(this.cameraInput);
      this.session.addOutput(this.previewOutput);
      this.session.addOutput(this.photoOutput);
      await this.session.commitConfig();
      try {
        const previewRotation = this.previewOutput.getPreviewRotation();
        this.previewOutput.setPreviewRotation(previewRotation, false);
      } catch (error) {
        console.warn(`Camera preview rotation before start failed: ${JSON.stringify(error)}`);
      }
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
      this.photoOutput?.off('photoAssetAvailable', this.onPhotoAssetAvailable);
      await this.photoOutput?.release();
    } catch (error) {
      console.warn(`Camera photo output release failed: ${JSON.stringify(error)}`);
    }
    try {
      await this.cameraInput?.close();
    } catch (error) {
      console.warn(`Camera input close failed: ${JSON.stringify(error)}`);
    }
    this.session = undefined;
    this.previewOutput = undefined;
    this.photoOutput = undefined;
    this.cameraInput = undefined;
    this.cameraManager = undefined;
  }

  async capture(location?: CaptureLocation): Promise<void> {
    if (!this.photoOutput || !this.session) {
      throw new Error('相机尚未准备好，暂时不能拍照。');
    }
    try {
      const setting: camera.PhotoCaptureSetting = {
        quality: camera.QualityLevel.QUALITY_LEVEL_HIGH,
        rotation: camera.ImageRotation.ROTATION_0,
        mirror: false
      };
      if (location) {
        setting.location = location;
      }
      await this.photoOutput.capture(setting);
    } catch (error) {
      const businessError = error as BusinessError;
      const detail = businessError.message ?? businessError.code ?? '未知错误';
      throw new Error(`拍照请求失败：${detail}`);
    }
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

  refreshPreviewRotation(): void {
    if (!this.previewOutput) {
      return;
    }
    try {
      const previewRotation = this.previewOutput.getPreviewRotation();
      this.previewOutput.setPreviewRotation(previewRotation, false);
    } catch (error) {
      console.warn(`Camera preview rotation refresh failed: ${JSON.stringify(error)}`);
    }
  }

  private readonly onPhotoAssetAvailable = (error: BusinessError, photoAsset: photoAccessHelper.PhotoAsset): void => {
    if (error && error.code !== 0) {
      console.error(`Photo asset callback failed: ${error.code}`);
      return;
    }
    if (photoAsset && this.photoSavedCallback) {
      this.photoSavedCallback(photoAsset);
    }
  };

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
