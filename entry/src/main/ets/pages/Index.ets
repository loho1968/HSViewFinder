import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { display } from '@kit.ArkUI';
import { CameraPreviewController } from '../camera/CameraPreviewController';
import { HASSELBLAD_LENSES } from '../data/HasselbladLenses';
import { FovCalculator } from '../geometry/FovCalculator';
import { AspectRatio, FrameRect, LensSpec, ZoomOption } from '../model/LensSpec';

const PHONE_BASE_FOCAL_LENGTH_MM = 24;
const PHONE_BASE_HFOV = 73;
const PHONE_BASE_VFOV = 56;
const X2D_SENSOR_WIDTH_MM = 43.8;
const X2D_SENSOR_HEIGHT_MM = 32.9;
const LENS_FRAME_COLOR = '#FFFFFF';
const PHONE_ZOOM_OPTIONS: ZoomOption[] = [
  { ratio: 0.5, label: '0.5x  ·  13mm', equivalentFocalLengthMm: 13 },
  { ratio: 1, label: '1x  ·  24mm', equivalentFocalLengthMm: 24 },
  { ratio: 4, label: '4x  ·  90.5mm', equivalentFocalLengthMm: 90.5 },
  { ratio: 6.2, label: '6.2x  ·  140mm', equivalentFocalLengthMm: 140 }
];

class ViewfinderXComponentController extends XComponentController {
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
struct Index {
  @State private statusText: string = '准备请求相机权限';
  @State private selectedLensIds: string[] = ['xcd-25v'];
  @State private selectedZoomRatio: number = 1;
  @State private lensListExpanded: boolean = false;
  @State private zoomListExpanded: boolean = false;
  @State private cameraReady: boolean = false;
  @State private cameraPermissionGranted: boolean = false;

  private readonly previewController: CameraPreviewController = new CameraPreviewController();
  private readonly xComponentController: ViewfinderXComponentController = new ViewfinderXComponentController();
  private readonly canvasSettings: RenderingContextSettings = new RenderingContextSettings(true);
  private readonly canvasContext: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.canvasSettings);
  private surfaceId: string = '';
  private surfaceWidth: number = 0;
  private surfaceHeight: number = 0;
  private previewTask: Promise<void> = Promise.resolve();
  private previewStartPending: boolean = false;
  private previewRunning: boolean = false;
  private pageVisible: boolean = true;
  private rotationRefreshTimer: number = -1;
  private recoveryTimer: number = -1;
  private settings?: preferences.Preferences;
  private preferencesReady: Promise<void> = Promise.resolve();
  private readonly displayChangeCallback = (_displayId: number): void => {
    this.scheduleRotationRestart();
  };

  aboutToAppear(): void {
    display.on('change', this.displayChangeCallback);
    this.preferencesReady = this.loadPreferences();
    this.xComponentController.onCreated = (surfaceId: string): void => {
      this.surfaceId = surfaceId;
      this.preferencesReady.then(() => this.requestCameraAndStart());
    };
    this.xComponentController.onChanged = (surfaceId: string, rect: SurfaceRect): void => {
      this.surfaceId = surfaceId;
      this.surfaceWidth = rect.surfaceWidth;
      this.surfaceHeight = rect.surfaceHeight;
      this.drawOverlay();
    };
    this.xComponentController.onDestroyed = (_surfaceId: string): void => {
      this.surfaceId = '';
      this.surfaceWidth = 0;
      this.surfaceHeight = 0;
      this.previewRunning = false;
      this.clearRotationRefreshTimer();
      this.clearRecoveryTimer();
      this.queuePreviewRelease();
    };
  }

  aboutToDisappear(): void {
    this.previewRunning = false;
    this.pageVisible = false;
    display.off('change', this.displayChangeCallback);
    this.clearRotationRefreshTimer();
    this.clearRecoveryTimer();
    this.queuePreviewRelease();
  }

  onPageShow(): void {
    this.pageVisible = true;
    if (this.surfaceId.length > 0 && !this.previewRunning) {
      this.queuePreviewStart();
    }
  }

  onPageHide(): void {
    this.pageVisible = false;
    this.previewRunning = false;
    this.clearRotationRefreshTimer();
    this.clearRecoveryTimer();
    this.queuePreviewRelease();
  }

  private scheduleRotationRestart(): void {
    if (!this.pageVisible || !this.previewRunning) {
      return;
    }
    this.clearRotationRefreshTimer();
    this.rotationRefreshTimer = setTimeout(() => {
      this.rotationRefreshTimer = -1;
      if (this.pageVisible && this.previewRunning) {
        this.previewController.refreshPreviewRotation();
      }
    }, 350);
  }

  private clearRotationRefreshTimer(): void {
    if (this.rotationRefreshTimer >= 0) {
      clearTimeout(this.rotationRefreshTimer);
      this.rotationRefreshTimer = -1;
    }
  }

  private clearRecoveryTimer(): void {
    if (this.recoveryTimer >= 0) {
      clearTimeout(this.recoveryTimer);
      this.recoveryTimer = -1;
    }
  }

  private queuePreviewRelease(): void {
    this.previewTask = this.previewTask
      .then(() => this.previewController.release())
      .catch(() => undefined);
  }

  private schedulePreviewRecovery(): void {
    if (!this.pageVisible || !this.cameraPermissionGranted || this.surfaceId.length === 0) {
      return;
    }
    this.clearRecoveryTimer();
    this.recoveryTimer = setTimeout(() => {
      this.recoveryTimer = -1;
      if (this.pageVisible && !this.previewRunning) {
        this.queuePreviewStart();
      }
    }, 1000);
  }

  private async loadPreferences(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.settings = await preferences.getPreferences(context.getApplicationContext(), {
        name: 'hs_viewfinder_settings'
      });
      const lensValue: string = await this.settings.get('selectedLensIds', 'xcd-25v') as string;
      const restoredLensIds = lensValue.split(',').filter((id: string) =>
        HASSELBLAD_LENSES.some((lens: LensSpec) => lens.id === id));
      if (restoredLensIds.length > 0) {
        this.selectedLensIds = restoredLensIds;
      }
      const zoomValue: number = await this.settings.get('selectedZoomRatio', 1) as number;
      if (PHONE_ZOOM_OPTIONS.some((option: ZoomOption) => option.ratio === zoomValue)) {
        this.selectedZoomRatio = zoomValue;
      }
    } catch (error) {
      this.statusText = `读取上次设置失败：${JSON.stringify(error)}`;
    }
  }

  private async savePreferences(): Promise<void> {
    if (!this.settings) {
      return;
    }
    try {
      await this.settings.put('selectedLensIds', this.selectedLensIds.join(','));
      await this.settings.put('selectedZoomRatio', this.selectedZoomRatio);
      await this.settings.flush();
    } catch (error) {
      this.statusText = `保存设置失败：${JSON.stringify(error)}`;
    }
  }

  private async requestCameraAndStart(): Promise<void> {
    const granted = await this.requestCameraPermission();
    if (!granted) {
      this.statusText = '未获得相机权限，点击“授权相机”后重试';
      return;
    }
    this.statusText = '等待预览 Surface 创建';
    if (this.surfaceId.length > 0) {
      await this.queuePreviewStart();
    }
  }

  private async requestCameraPermission(): Promise<boolean> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const permissions: Permissions[] = ['ohos.permission.CAMERA'];
      const result = await abilityAccessCtrl.createAtManager().requestPermissionsFromUser(context, permissions);
      const granted = result.authResults.length > 0 && result.authResults[0] === 0;
      this.cameraPermissionGranted = granted;
      return granted;
    } catch (error) {
      this.statusText = `相机权限请求失败：${JSON.stringify(error)}`;
      return false;
    }
  }

  private queuePreviewStart(): Promise<void> {
    if (this.previewStartPending) {
      return this.previewTask;
    }
    this.previewStartPending = true;
    const task = this.previewTask.then(() => this.startPreview());
    this.previewTask = task
      .catch(() => undefined)
      .finally(() => {
        this.previewStartPending = false;
      });
    return task;
  }

  private async startPreview(): Promise<void> {
    try {
      this.statusText = '正在启动手机预览';
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const aspectRatio = this.surfaceWidth > 0 && this.surfaceHeight > 0
        ? this.surfaceWidth / this.surfaceHeight
        : 3 / 2;
      await this.previewController.start(context, this.surfaceId, aspectRatio, this.selectedZoomRatio);
      this.cameraReady = true;
      this.previewRunning = true;
      this.statusText = '预览已启动，使用参考 FOV 模拟哈苏镜头';
      this.drawOverlay();
    } catch (error) {
      this.cameraReady = false;
      this.previewRunning = false;
      this.statusText = `预览不可用：${JSON.stringify(error)}`;
      this.schedulePreviewRecovery();
    }
  }

  private selectLens(lens: LensSpec): void {
    if (this.selectedLensIds.includes(lens.id)) {
      if (this.selectedLensIds.length <= 1) {
        return;
      }
      this.selectedLensIds = this.selectedLensIds.filter((id: string) => id !== lens.id);
    } else {
      this.selectedLensIds = [...this.selectedLensIds, lens.id];
    }
    this.savePreferences();
    this.drawOverlay();
  }

  private selectZoom(option: ZoomOption): void {
    this.selectedZoomRatio = option.ratio;
    if (!this.previewController.setZoomRatio(option.ratio)) {
      return;
    }
    this.savePreferences();
    this.zoomListExpanded = false;
    this.drawOverlay();
  }

  private toggleLensList(): void {
    this.lensListExpanded = !this.lensListExpanded;
    this.zoomListExpanded = false;
  }

  private drawOverlay(): void {
    const width = this.canvasContext.width;
    const height = this.canvasContext.height;
    if (width <= 0 || height <= 0) {
      return;
    }
    this.canvasContext.clearRect(0, 0, width, height);
    const content: FrameRect = { left: 0, top: 0, width, height };
    const aspect = this.getCurrentSensorAspect();
    const aspectFrame = FovCalculator.fitAspect(content, aspect.width, aspect.height);
    this.drawAspectFrame(aspectFrame);
    this.drawGrid(aspectFrame);

    const zoom = this.getSelectedZoom();
    const phoneIsPortrait = this.surfaceHeight > this.surfaceWidth;
    const phoneHorizontalFov = FovCalculator.fovForEquivalentFocalLength(
      phoneIsPortrait ? PHONE_BASE_VFOV : PHONE_BASE_HFOV,
      PHONE_BASE_FOCAL_LENGTH_MM,
      zoom.equivalentFocalLengthMm);
    const phoneVerticalFov = FovCalculator.fovForEquivalentFocalLength(
      phoneIsPortrait ? PHONE_BASE_HFOV : PHONE_BASE_VFOV,
      PHONE_BASE_FOCAL_LENGTH_MM,
      zoom.equivalentFocalLengthMm);
    const selectedLenses = HASSELBLAD_LENSES.filter((lens: LensSpec) => this.selectedLensIds.includes(lens.id));
    const maxWidthRatio = Math.max(...selectedLenses.map((lens: LensSpec) =>
      FovCalculator.fovRatio(
        FovCalculator.fovFromSensor(aspect.width, lens.focalLengthMm), phoneHorizontalFov)));
    const maxHeightRatio = Math.max(...selectedLenses.map((lens: LensSpec) =>
      FovCalculator.fovRatio(
        FovCalculator.fovFromSensor(aspect.height, lens.focalLengthMm), phoneVerticalFov)));
    const normalizationScale = Math.min(1, 1 / maxWidthRatio, 1 / maxHeightRatio);
    selectedLenses.forEach((lens: LensSpec) => {
      const simulation = FovCalculator.simulateLens(
        content,
        FovCalculator.fovFromSensor(aspect.width, lens.focalLengthMm),
        FovCalculator.fovFromSensor(aspect.height, lens.focalLengthMm),
        phoneHorizontalFov,
        phoneVerticalFov,
        normalizationScale
      );
      this.canvasContext.strokeStyle = LENS_FRAME_COLOR;
      this.canvasContext.lineWidth = 3;
      this.canvasContext.strokeRect(
        simulation.frame.left,
        simulation.frame.top,
        simulation.frame.width,
        simulation.frame.height
      );
      this.drawLensLabel(lens, simulation.frame);
    });
  }

  private drawLensLabel(lens: LensSpec, frame: FrameRect): void {
    this.canvasContext.fillStyle = LENS_FRAME_COLOR;
    this.canvasContext.font = 'bold 64px sans-serif';
    this.canvasContext.textBaseline = 'top';
    this.canvasContext.fillText(lens.focalLengthLabel.replace('mm', ''), frame.left + 2, frame.top + 1);
  }

  private drawAspectFrame(frame: FrameRect): void {
    this.canvasContext.strokeStyle = 'rgba(255, 255, 255, 0.82)';
    this.canvasContext.lineWidth = 2;
    this.canvasContext.strokeRect(frame.left, frame.top, frame.width, frame.height);
  }

  private drawGrid(frame: FrameRect): void {
    this.canvasContext.strokeStyle = 'rgba(255, 255, 255, 0.35)';
    this.canvasContext.lineWidth = 1;
    for (let index = 1; index < 3; index++) {
      const x = frame.left + frame.width * index / 3;
      const y = frame.top + frame.height * index / 3;
      this.canvasContext.beginPath();
      this.canvasContext.moveTo(x, frame.top);
      this.canvasContext.lineTo(x, frame.top + frame.height);
      this.canvasContext.stroke();
      this.canvasContext.beginPath();
      this.canvasContext.moveTo(frame.left, y);
      this.canvasContext.lineTo(frame.left + frame.width, y);
      this.canvasContext.stroke();
    }
  }

  private getSelectedLenses(): LensSpec[] {
    return HASSELBLAD_LENSES.filter((lens: LensSpec) => this.selectedLensIds.includes(lens.id));
  }

  private getPrimaryLens(): LensSpec {
    return this.getSelectedLenses()[0] ?? HASSELBLAD_LENSES[0];
  }

  private getSelectedZoom(): ZoomOption {
    return PHONE_ZOOM_OPTIONS.find((option: ZoomOption) => option.ratio === this.selectedZoomRatio)
      ?? PHONE_ZOOM_OPTIONS[1];
  }

  private getCurrentSensorAspect(): AspectRatio {
    if (this.surfaceHeight > this.surfaceWidth) {
      return { width: X2D_SENSOR_HEIGHT_MM, height: X2D_SENSOR_WIDTH_MM };
    }
    return { width: X2D_SENSOR_WIDTH_MM, height: X2D_SENSOR_HEIGHT_MM };
  }

  build() {
    Column() {
      Stack({ alignContent: Alignment.Center }) {
        XComponent({ type: XComponentType.SURFACE, controller: this.xComponentController })
          .width('100%')
          .height('100%')
          .backgroundColor('#101714')
          .onLoad(() => {
            this.surfaceId = this.xComponentController.getXComponentSurfaceId();
            this.xComponentController.setXComponentSurfaceRotation({ lock: false });
          });

        Canvas(this.canvasContext)
          .width('100%')
          .height('100%')
          .hitTestBehavior(HitTestMode.Transparent)
          .onReady(() => this.drawOverlay())
          .onAreaChange(() => this.drawOverlay());

        Row() {
          Column() {
            Text('HS VIEWFINDER')
              .fontSize(13)
              .fontWeight(FontWeight.Bold)
              .fontColor('#F9D66B')
              .letterSpacing(1.4);
          }
          Blank();
          if (!this.cameraPermissionGranted) {
            Button('授权相机')
              .fontSize(12)
              .backgroundColor('rgba(17, 25, 22, 0.82)')
              .fontColor('#F9D66B')
              .onClick(() => this.requestCameraAndStart());
          }
        }
        .width('100%')
        .align(Alignment.Top)
        .padding({ left: 20, right: 20, top: 18 });
      }
      .layoutWeight(1)
      .width('100%');

      Column({ space: 10 }) {
        Row({ space: 14 }) {
          Row() {
            Text(this.getPrimaryLens().focalLengthLabel)
              .fontSize(18)
              .fontWeight(FontWeight.Medium)
              .fontColor('#FFFFFF');
            SymbolGlyph(this.lensListExpanded ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_right'))
              .fontSize(18)
              .fontColor(['#F9D66B'])
              .margin({ left: 6 });
          }
          .onClick(() => this.toggleLensList());

          Row() {
            Text(this.getSelectedZoom().label)
              .fontSize(13)
              .fontColor('#FFFFFF');
            SymbolGlyph(this.zoomListExpanded ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_right'))
              .fontSize(16)
              .fontColor(['#F9D66B'])
              .margin({ left: 6 });
          }
          .onClick(() => {
            this.zoomListExpanded = !this.zoomListExpanded;
            this.lensListExpanded = false;
          });
        }
        .justifyContent(FlexAlign.Center)
        .width('100%');

        if (this.lensListExpanded) {
          Scroll() {
            Row({ space: 8 }) {
              ForEach(HASSELBLAD_LENSES, (lens: LensSpec) => {
                Button(lens.focalLengthLabel)
                  .fontSize(12)
                  .backgroundColor(this.selectedLensIds.includes(lens.id) ? '#F9D66B' : '#25302A')
                  .fontColor(this.selectedLensIds.includes(lens.id) ? '#18201B' : '#FFFFFF')
                  .onClick(() => this.selectLens(lens));
              }, (lens: LensSpec) => lens.id);
            }
            .padding({ left: 20, right: 20 });
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .width('100%');
        }

        if (this.zoomListExpanded) {
          Row({ space: 8 }) {
            ForEach(PHONE_ZOOM_OPTIONS, (option: ZoomOption) => {
              Button(option.label)
                .fontSize(11)
                .backgroundColor(this.selectedZoomRatio === option.ratio ? '#F9D66B' : '#25302A')
                .fontColor(this.selectedZoomRatio === option.ratio ? '#18201B' : '#FFFFFF')
                .onClick(() => this.selectZoom(option));
            }, (option: ZoomOption) => option.label);
          }
          .justifyContent(FlexAlign.Center);
        }

      }
      .width('100%')
      .padding({ left: 20, right: 20, bottom: 22 });
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#101714');
  }
}
