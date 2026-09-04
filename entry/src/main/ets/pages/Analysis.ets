import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { display, router } from '@kit.ArkUI';
import { geoLocationManager } from '@kit.LocationKit';
import { CameraPreviewController } from '../camera/CameraPreviewController';
import { CaptureContext, CaptureLocation } from '../model/CaptureContext';

class AnalysisXComponentController extends XComponentController {
  onCreated: (surfaceId: string) => void = (_surfaceId: string): void => {};
  onChanged: (surfaceId: string, rect: SurfaceRect) => void = (_surfaceId: string, _rect: SurfaceRect): void => {};
  onDestroyed: (surfaceId: string) => void = (_surfaceId: string): void => {};

  onSurfaceCreated(surfaceId: string): void {
    this.onCreated(surfaceId);
  }

  onSurfaceChanged(surfaceId: string, rect: SurfaceRect): void {
    this.onChanged(surfaceId, rect);
  }

  onSurfaceDestroyed(surfaceId: string): void {
    this.onDestroyed(surfaceId);
  }
}

@Entry
@Component
struct Analysis {
  @State private lastPhotoUri: string = '';
  @State private cameraOpen: boolean = false;
  @State private cameraReady: boolean = false;
  @State private captureInProgress: boolean = false;
  @State private statusText: string = '';
  @State private menuExpanded: boolean = false;
  @State private showSun: boolean = true;
  @State private showMoon: boolean = false;
  @State private showMilkyWay: boolean = false;
  @State private analysisText: string = '等待拍摄照片';

  private readonly previewController: CameraPreviewController = new CameraPreviewController();
  private readonly xComponentController: AnalysisXComponentController = new AnalysisXComponentController();
  private surfaceId: string = '';
  private surfaceWidth: number = 0;
  private surfaceHeight: number = 0;
  private settings?: preferences.Preferences;
  private cameraStarting: boolean = false;
  private messageTimer: number = -1;
  private captureTimer: number = -1;
  private readonly displayChangeCallback = (_displayId: number): void => {
    this.previewController.refreshPreviewRotation();
  };

  aboutToAppear(): void {
    display.on('change', this.displayChangeCallback);
    this.previewController.setPhotoSavedCallback((photoAsset) => {
      this.lastPhotoUri = photoAsset.uri;
      this.captureInProgress = false;
      this.clearCaptureTimer();
      this.analysisText = '照片已保存，等待计算色温和天体位置';
      this.showMessage(`已保存照片：${photoAsset.displayName}`);
      this.saveLastPhotoUri(photoAsset.uri);
      this.saveAnalysisText();
    });
    this.xComponentController.onCreated = (surfaceId: string): void => {
      this.surfaceId = surfaceId;
      this.startCamera();
    };
    this.xComponentController.onChanged = (surfaceId: string, rect: SurfaceRect): void => {
      this.surfaceId = surfaceId;
      this.surfaceWidth = rect.surfaceWidth;
      this.surfaceHeight = rect.surfaceHeight;
    };
    this.xComponentController.onDestroyed = (_surfaceId: string): void => {
      this.surfaceId = '';
      this.surfaceWidth = 0;
      this.surfaceHeight = 0;
      this.cameraReady = false;
      this.cameraStarting = false;
      this.releaseCamera();
    };
    this.loadLastPhotoUri();
  }

  aboutToDisappear(): void {
    display.off('change', this.displayChangeCallback);
    this.clearMessageTimer();
    this.clearCaptureTimer();
    this.releaseCamera();
  }

  private async loadLastPhotoUri(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.settings = await preferences.getPreferences(context.getApplicationContext(), {
        name: 'hs_viewfinder_settings'
      });
      this.lastPhotoUri = await this.settings.get('lastPhotoUri', '') as string;
      this.analysisText = await this.settings.get('analysisText', '等待拍摄照片') as string;
      this.showSun = await this.settings.get('showSun', true) as boolean;
      this.showMoon = await this.settings.get('showMoon', false) as boolean;
      this.showMilkyWay = await this.settings.get('showMilkyWay', false) as boolean;
    } catch (error) {
      this.showMessage(`读取最近照片失败：${JSON.stringify(error)}`);
    }
  }

  private async saveLastPhotoUri(uri: string): Promise<void> {
    if (!this.settings) {
      return;
    }
    try {
      await this.settings.put('lastPhotoUri', uri);
      await this.settings.flush();
    } catch (error) {
      this.showMessage(`记录最近照片失败：${JSON.stringify(error)}`);
    }
  }

  private async saveAnalysisText(): Promise<void> {
    if (!this.settings) {
      return;
    }
    try {
      await this.settings.put('analysisText', this.analysisText);
      await this.settings.flush();
    } catch (error) {
      this.showMessage(`保存分析状态失败：${JSON.stringify(error)}`);
    }
  }

  private async saveAstronomySelection(): Promise<void> {
    if (!this.settings) {
      return;
    }
    try {
      await this.settings.put('showSun', this.showSun);
      await this.settings.put('showMoon', this.showMoon);
      await this.settings.put('showMilkyWay', this.showMilkyWay);
      await this.settings.flush();
    } catch (error) {
      this.showMessage(`保存天体选择失败：${JSON.stringify(error)}`);
    }
  }

  private toggleAstronomy(target: string): void {
    if (target === 'sun') {
      this.showSun = !this.showSun;
    } else if (target === 'moon') {
      this.showMoon = !this.showMoon;
    } else {
      this.showMilkyWay = !this.showMilkyWay;
    }
    if (!this.showSun && !this.showMoon && !this.showMilkyWay) {
      this.showSun = true;
    }
    this.saveAstronomySelection();
  }

  private showMessage(message: string): void {
    this.statusText = message;
    this.clearMessageTimer();
    this.messageTimer = setTimeout(() => {
      this.messageTimer = -1;
      this.statusText = '';
    }, 2400);
  }

  private clearMessageTimer(): void {
    if (this.messageTimer >= 0) {
      clearTimeout(this.messageTimer);
      this.messageTimer = -1;
    }
  }

  private clearCaptureTimer(): void {
    if (this.captureTimer >= 0) {
      clearTimeout(this.captureTimer);
      this.captureTimer = -1;
    }
  }

  private async openCamera(): Promise<void> {
    const granted = await this.requestCameraPermission();
    if (!granted) {
      this.showMessage('未获得相机权限');
      return;
    }
    this.cameraOpen = true;
    this.showMessage('正在打开相机');
  }

  private async requestCameraPermission(): Promise<boolean> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const result = await abilityAccessCtrl.createAtManager().requestPermissionsFromUser(
        context, ['ohos.permission.CAMERA'] as Permissions[]);
      return result.authResults.length > 0 && result.authResults[0] === 0;
    } catch (error) {
      this.showMessage(`相机权限请求失败：${JSON.stringify(error)}`);
      return false;
    }
  }

  private async getCaptureLocation(): Promise<CaptureLocation | undefined> {
    try {
      if (!canIUse('SystemCapability.Location.Location.Core')) {
        this.showMessage('当前设备不支持定位，将不记录 GPS');
        return undefined;
      }
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const result = await abilityAccessCtrl.createAtManager().requestPermissionsFromUser(
        context, ['ohos.permission.APPROXIMATELY_LOCATION', 'ohos.permission.LOCATION'] as Permissions[]);
      if (result.authResults.length < 2 || result.authResults[0] !== 0 || result.authResults[1] !== 0) {
        this.showMessage('未授权定位，将不记录 GPS');
        return undefined;
      }
      const location = await geoLocationManager.getCurrentLocation({
        priority: geoLocationManager.LocationRequestPriority.FIRST_FIX,
        scenario: geoLocationManager.LocationRequestScenario.UNSET,
        timeoutMs: 5000
      });
      return {
        latitude: location.latitude,
        longitude: location.longitude,
        altitude: location.altitude ?? 0,
        accuracy: location.accuracy
      };
    } catch (error) {
      this.showMessage('定位失败，将不记录 GPS');
      return undefined;
    }
  }

  private async startCamera(): Promise<void> {
    if (!this.cameraOpen || this.surfaceId.length === 0 || this.cameraStarting || this.cameraReady) {
      return;
    }
    this.cameraStarting = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const aspectRatio = this.surfaceWidth > 0 && this.surfaceHeight > 0
        ? this.surfaceWidth / this.surfaceHeight
        : 3 / 2;
      await this.previewController.start(context, this.surfaceId, aspectRatio, 1);
      this.cameraReady = true;
      this.showMessage('相机已打开，可以拍照');
    } catch (error) {
      this.cameraReady = false;
      this.showMessage(`相机打开失败：${JSON.stringify(error)}`);
    } finally {
      this.cameraStarting = false;
    }
  }

  private async capturePhoto(): Promise<void> {
    if (!this.cameraReady || this.captureInProgress) {
      return;
    }
    this.captureInProgress = true;
    this.showMessage('正在拍照');
    this.clearCaptureTimer();
    this.captureTimer = setTimeout(() => {
      this.captureTimer = -1;
      if (this.captureInProgress) {
        this.captureInProgress = false;
        this.showMessage('拍照请求已发送，图库保存可能需要几秒');
      }
    }, 6000);
    try {
      const location = await this.getCaptureLocation();
      await this.saveCaptureContext(location);
      await this.previewController.capture(location);
      this.showMessage('拍照完成，正在保存到图库');
    } catch (error) {
      this.captureInProgress = false;
      this.clearCaptureTimer();
      this.showMessage(`拍照失败：${JSON.stringify(error)}`);
    }
  }

  private closeCamera(): void {
    this.cameraOpen = false;
    this.cameraReady = false;
    this.captureInProgress = false;
    this.clearCaptureTimer();
    this.releaseCamera();
  }

  private releaseCamera(): void {
    this.previewController.release().catch(() => undefined);
  }

  private async saveCaptureContext(location?: CaptureLocation): Promise<void> {
    if (!this.settings) {
      return;
    }
    try {
      const lensValue = await this.settings.get('selectedLensIds', 'xcd-25v') as string;
      const zoomRatio = await this.settings.get('selectedZoomRatio', 1) as number;
      const context: CaptureContext = {
        captureTimeMs: Date.now(),
        location,
        screenWidth: this.surfaceWidth,
        screenHeight: this.surfaceHeight,
        phoneZoomRatio: zoomRatio,
        phoneEquivalentFocalLengthMm: this.getEquivalentFocalLength(zoomRatio),
        selectedLensIds: lensValue.split(',').filter((id: string) => id.length > 0)
      };
      await this.settings.put('lastCaptureContext', JSON.stringify(context));
      await this.settings.flush();
    } catch (error) {
      this.showMessage(`保存拍摄信息失败：${JSON.stringify(error)}`);
    }
  }

  private getEquivalentFocalLength(zoomRatio: number): number {
    if (zoomRatio === 0.5) {
      return 13;
    }
    if (zoomRatio === 4) {
      return 90.5;
    }
    if (zoomRatio === 6.2) {
      return 140;
    }
    return 24;
  }

  build() {
    Column() {
      Stack({ alignContent: Alignment.Center }) {
        if (this.cameraOpen) {
          XComponent({ type: XComponentType.SURFACE, controller: this.xComponentController })
            .width('100%')
            .height('100%')
            .backgroundColor('#101714')
            .onLoad(() => {
              this.surfaceId = this.xComponentController.getXComponentSurfaceId();
              this.xComponentController.setXComponentSurfaceRotation({ lock: false });
              this.startCamera();
            });

          if (this.statusText.length > 0) {
            Text(this.statusText)
              .fontSize(12)
              .fontColor('#FFFFFF')
              .backgroundColor('rgba(16, 23, 20, 0.78)')
              .padding({ left: 14, right: 14, top: 8, bottom: 8 })
              .align(Alignment.Top)
              .margin({ top: 18 });
          }
        } else if (this.lastPhotoUri.length > 0) {
          Image(this.lastPhotoUri)
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Contain);
          Text(this.analysisText)
            .fontSize(13)
            .fontColor('#B8C3BD')
            .backgroundColor('rgba(16, 23, 20, 0.78)')
            .padding({ left: 14, right: 14, top: 8, bottom: 8 })
            .align(Alignment.Bottom)
            .margin({ bottom: 18 });
        } else {
          Text('还没有拍摄照片')
            .fontSize(18)
            .fontColor('#B8C3BD');
        }

        if (!this.cameraOpen) {
          Row() {
            Text('色温和日月')
              .fontSize(18)
              .fontWeight(FontWeight.Medium)
              .fontColor('#FFFFFF');
            Blank();
            Button('菜单')
              .fontSize(13)
              .backgroundColor('rgba(17, 25, 22, 0.82)')
              .fontColor('#F9D66B')
              .onClick(() => this.menuExpanded = !this.menuExpanded);
          }
          .width('100%')
          .align(Alignment.Top)
          .padding({ left: 20, right: 20, top: 18 });

          if (this.menuExpanded) {
            Column({ space: 8 }) {
              Text('拍照后叠加显示')
                .fontSize(13)
                .fontColor('#B8C3BD');
              Row({ space: 8 }) {
                Button(this.showSun ? '太阳 已选' : '太阳')
                  .fontSize(12)
                  .backgroundColor(this.showSun ? '#F9D66B' : '#25302A')
                  .fontColor(this.showSun ? '#18201B' : '#FFFFFF')
                  .onClick(() => this.toggleAstronomy('sun'));
                Button(this.showMoon ? '月亮 已选' : '月亮')
                  .fontSize(12)
                  .backgroundColor(this.showMoon ? '#F9D66B' : '#25302A')
                  .fontColor(this.showMoon ? '#18201B' : '#FFFFFF')
                  .onClick(() => this.toggleAstronomy('moon'));
                Button(this.showMilkyWay ? '银河中心 已选' : '银河中心')
                  .fontSize(12)
                  .backgroundColor(this.showMilkyWay ? '#F9D66B' : '#25302A')
                  .fontColor(this.showMilkyWay ? '#18201B' : '#FFFFFF')
                  .onClick(() => this.toggleAstronomy('milky'));
              }
            }
            .backgroundColor('rgba(16, 23, 20, 0.9)')
            .padding({ left: 16, right: 16, top: 12, bottom: 12 })
            .align(Alignment.Top)
            .margin({ top: 70, left: 20, right: 20 });
          }
        }
      }
      .layoutWeight(1)
      .width('100%');

      Row({ space: 12 }) {
        Button('返回')
          .fontSize(13)
          .backgroundColor('#25302A')
          .fontColor('#FFFFFF')
          .onClick(() => router.back());

        if (this.cameraOpen) {
          Button(this.captureInProgress ? '保存中' : '拍照')
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .backgroundColor(this.captureInProgress ? '#59635E' : '#F9D66B')
            .fontColor('#18201B')
            .enabled(this.cameraReady && !this.captureInProgress)
            .onClick(() => this.capturePhoto());
          Button('关闭相机')
            .fontSize(13)
            .backgroundColor('#25302A')
            .fontColor('#FFFFFF')
            .onClick(() => this.closeCamera());
        } else {
          Button('打开相机')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .backgroundColor('#F9D66B')
            .fontColor('#18201B')
            .onClick(() => this.openCamera());
        }
      }
      .justifyContent(FlexAlign.Center)
      .width('100%')
      .padding({ left: 20, right: 20, bottom: 22, top: 12 });
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#101714');
  }
}
