import { camera } from '@kit.CameraKit';
import { common } from '@kit.AbilityKit';
import { abilityAccessCtrl, Permissions } from '@kit.AbilityKit';
import { SuppressWarnings, SuppressWarningsType } from '@kit.BasicServicesKit';
import { window } from '@kit.ArkUI';

@SuppressWarnings({ rules: [SuppressWarningsType.PERMISSION] })
@Entry
@Component
struct Index {
  @State message: string = 'Hello World';
  @State isBlackScreen: boolean = false
  private gradientAnimation: number = 0
  @State colors: Array<[ResourceColor, number]> = []
  // 相机相关变量
  private cameraManager: camera.CameraManager | null = null
  private cameraInput: camera.CameraInput | null = null
  private previewOutput: camera.PreviewOutput | null = null
  private photoSession: camera.PhotoSession | null = null
  private surfaceId: string = ''
  private context: common.UIAbilityContext | null = null
  private xComponentController: XComponentController = new XComponentController()
  // 屏幕尺寸
  private screenWidth: number = 0
  private screenHeight: number = 0
  // XComponent尺寸（用于坐标转换）
  private xComponentWidth: number = 0
  private xComponentHeight: number = 0
  // 对焦框相关变量
  @State showFocusBox: boolean = false
  @State focusBoxX: number = 0
  @State focusBoxY: number = 0
  private focusBoxTimer: number = -1

  aboutToAppear() {
    // 启动渐变动画
    this.startGradientAnimation()
    // 初始化颜色
    this.updateColors(0)
    // 获取上下文
    this.context = getContext(this) as common.UIAbilityContext
  }

  // 页面显示时获取屏幕尺寸
  onPageShow() {
    this.getScreenSize()
  }

  // 获取屏幕尺寸
  getScreenSize() {
    if (!this.context) {
      console.error('Context is null')
      return
    }

    window.getLastWindow(this.context)
      .then((windowClass: window.Window) => {
        const properties = windowClass.getWindowProperties()
        this.screenWidth = properties.windowRect.width
        this.screenHeight = properties.windowRect.height
        console.info(`Screen size: ${this.screenWidth} x ${this.screenHeight}`)
      })
      .catch((error: Error) => {
        console.error(`Failed to get screen size: ${error}`)
      })
  }

  aboutToDisappear() {
    // 释放相机资源
    this.releaseCamera()
  }

  // 申请相机权限
  async requestCameraPermission(): Promise<boolean> {
    if (!this.context) {
      console.error('Context is null')
      return false
    }

    try {
      const atManager = abilityAccessCtrl.createAtManager()
      const permissions: Permissions[] = ['ohos.permission.CAMERA']
      const result = await atManager.requestPermissionsFromUser(this.context, permissions)

      // 检查权限是否授予
      if (result.authResults[0] === 0) {
        console.info('Camera permission granted')
        return true
      } else {
        console.error('Camera permission denied')
        return false
      }
    } catch (error) {
      console.error(`Failed to request camera permission: ${error}`)
      return false
    }
  }

  // 选择最匹配屏幕比例的预览分辨率
  selectBestPreviewProfile(previewProfiles: camera.Profile[]): camera.Profile {
    if (this.screenWidth === 0 || this.screenHeight === 0) {
      console.warn('Screen size not available, using default preview profile')
      return previewProfiles[0]
    }

    // 计算屏幕宽高比（使用较大的值除以较小的值）
    const screenRatio = Math.max(this.screenWidth, this.screenHeight) /
                        Math.min(this.screenWidth, this.screenHeight)
    console.info(`Screen ratio: ${screenRatio}`)

    let bestProfile = previewProfiles[0]
    let minDiff = Number.MAX_VALUE

    // 遍历所有预览分辨率，找到与屏幕比例最接近的
    for (const profile of previewProfiles) {
      const profileRatio = Math.max(profile.size.width, profile.size.height) /
                          Math.min(profile.size.width, profile.size.height)
      const diff = Math.abs(profileRatio - screenRatio)

      console.info(`Preview profile: ${profile.size.width}x${profile.size.height}, ratio: ${profileRatio}, diff: ${diff}`)

      if (diff < minDiff) {
        minDiff = diff
        bestProfile = profile
      }
    }

    return bestProfile
  }

  // 处理点击对焦
  private async handleFocus(touchX: number, touchY: number): Promise<void> {
    if (!this.photoSession || !this.xComponentWidth || !this.xComponentHeight) {
      console.error('PhotoSession or XComponent size not ready')
      return
    }

    try {
      // 检查是否支持自动对焦模式
      const isFocusModeSupported = this.photoSession.isFocusModeSupported(camera.FocusMode.FOCUS_MODE_AUTO)
      if (!isFocusModeSupported) {
        console.warn('FOCUS_MODE_AUTO not supported')
        return
      }

      // 设置对焦模式为自动对焦
      await this.photoSession.setFocusMode(camera.FocusMode.FOCUS_MODE_AUTO)

      // 坐标转换：屏幕坐标 -> 相机归一化坐标
      // 转换公式：{y/h, 1-x/w}
      const focusPoint: camera.Point = {
        x: touchY / this.xComponentHeight,
        y: 1 - touchX / this.xComponentWidth
      }

      // 设置对焦点
      await this.photoSession.setFocusPoint(focusPoint)
      console.info(`Focus set to point: ${JSON.stringify(focusPoint)}`)
      
      // 显示对焦框
      this.showFocusBoxAt(touchX, touchY)
    } catch (error) {
      console.error(`Failed to set focus: ${JSON.stringify(error)}`)
    }
  }

  // 显示对焦框
  private showFocusBoxAt(x: number, y: number): void {
    // 清除之前的定时器
    if (this.focusBoxTimer !== -1) {
      clearTimeout(this.focusBoxTimer)
    }
    
    // 设置对焦框位置并显示
    this.focusBoxX = x
    this.focusBoxY = y
    this.showFocusBox = true
    
    // 2秒后自动隐藏对焦框
    this.focusBoxTimer = setTimeout(() => {
      this.showFocusBox = false
      this.focusBoxTimer = -1
    }, 2000)
  }

  // 初始化相机
  async initCamera() {
    if (!this.context) {
      console.error('Context is null')
      return
    }

    // 先申请相机权限
    const hasPermission = await this.requestCameraPermission()
    if (!hasPermission) {
      console.error('No camera permission, cannot initialize camera')
      return
    }

    try {
      // 创建相机管理器
      this.cameraManager = camera.getCameraManager(this.context)
      if (!this.cameraManager) {
        console.error('Failed to get camera manager')
        return
      }

      // 获取相机设备列表
      const cameras = this.cameraManager.getSupportedCameras()
      if (cameras.length === 0) {
        console.error('No cameras available')
        return
      }

      // 使用第一个后置摄像头
      const cameraDevice =
        cameras.find(c => c.cameraPosition === camera.CameraPosition.CAMERA_POSITION_BACK) || cameras[0]

      // 获取支持的场景模式
      const sceneModes = this.cameraManager.getSupportedSceneModes(cameraDevice)
      if (sceneModes.length === 0) {
        console.error('No scene modes available')
        return
      }
      const sceneMode = sceneModes[0]

      // 创建相机输入
      this.cameraInput = this.cameraManager.createCameraInput(cameraDevice)
      await this.cameraInput.open()

      // 获取支持的输出能力
      const outputCapability = this.cameraManager.getSupportedOutputCapability(cameraDevice, sceneMode)

      // 创建预览输出
      const previewProfiles = outputCapability.previewProfiles
      if (previewProfiles.length === 0) {
        console.error('No preview profiles available')
        return
      }

      // 选择最匹配屏幕比例的预览分辨率
      const matchedProfile = this.selectBestPreviewProfile(previewProfiles)
      console.info(`Selected preview resolution: ${matchedProfile.size.width} x ${matchedProfile.size.height}`)

      this.previewOutput = this.cameraManager.createPreviewOutput(matchedProfile, this.surfaceId)

      // 创建拍照会话
      this.photoSession = this.cameraManager.createSession(sceneMode) as camera.PhotoSession

      // 开始配置会话
      this.photoSession.beginConfig()
      this.photoSession.addInput(this.cameraInput)
      this.photoSession.addOutput(this.previewOutput)
      await this.photoSession.commitConfig()

      // 启动预览
      await this.photoSession.start()

      console.info('Camera preview started successfully')
    } catch (error) {
      console.error(`Failed to init camera: ${error}`)
    }
  }

  // 释放相机资源
  async releaseCamera() {
    try {
      if (this.photoSession) {
        await this.photoSession.stop()
        await this.photoSession.release()
        this.photoSession = null
      }

      if (this.cameraInput) {
        await this.cameraInput.close()
        this.cameraInput = null
      }

      this.previewOutput = null
      this.cameraManager = null

      console.info('Camera released successfully')
    } catch (error) {
      console.error(`Failed to release camera: ${error}`)
    }
  }

  startGradientAnimation() {
    // 使用线性渐变变换
    setInterval(() => {
      this.gradientAnimation = (this.gradientAnimation + 1) % 360
      this.updateColors(this.gradientAnimation)
    }, 50) // 50ms更新一次，实现流畅渐变
  }

  updateColors(angle: number) {
    // 生成基于角度的渐变颜色
    const hue1 = angle % 360
    const hue2 = (angle + 120) % 360
    const hue3 = (angle + 240) % 360

    this.colors = [
      [this.hslToRgb(hue1, 100, 50), 0.0],
      [this.hslToRgb(hue2, 100, 50), 0.5],
      [this.hslToRgb(hue3, 100, 50), 1.0]
    ]
  }

  // HSL 转 RGB 辅助函数
  hslToRgb(h: number, s: number, l: number): ResourceColor {
    s /= 100
    l /= 100
    const a = s * Math.min(l, 1 - l)
    const f = (n: number) => {
      const k = (n + h / 30) % 12
      return l - a * Math.max(Math.min(k - 3, 9 - k, 1), -1)
    }
    const r = Math.round(f(0) * 255)
    const g = Math.round(f(8) * 255)
    const b = Math.round(f(4) * 255)
    return `rgb(${r}, ${g}, ${b})`
  }

  build() {
    Column() {
      if (this.isBlackScreen) {
        // 相机预览背景
        Stack() {
          XComponent({
            id: 'cameraPreview',
            type: XComponentType.SURFACE,
            controller: this.xComponentController
          })
            .width('100%')
            .height('100%')
            .onLoad(() => {
              this.surfaceId = this.xComponentController.getXComponentSurfaceId()
              // 初始化相机并启动预览
              this.initCamera()
            })
            .onAreaChange((oldValue: Area, newValue: Area) => {
              // 获取XComponent的实际尺寸
              this.xComponentWidth = newValue.width as number
              this.xComponentHeight = newValue.height as number
            })
            .onTouch((event: TouchEvent) => {
              // 处理点击对焦
              if (event.type === TouchType.Down) {
                const touch = event.touches[0]
                this.handleFocus(touch.x, touch.y)
              }
            })
          
          // 对焦框
          if (this.showFocusBox) {
            Column()
              .width(70)
              .height(70)
              .border({
                width: 2,
                color: Color.White
              })
              .position({ x: this.focusBoxX - 35, y: this.focusBoxY - 35 })
          }
        }
        .width('100%')
        .height('100%')
      } else {
        // 正常界面 - 纯白色背景
        RelativeContainer() {
          Stack() {
            // 纯白色背景
            Column()
              .width('100%')
              .height('100%')
              .backgroundColor(Color.White)

            // 文字 - 使用渐变色
            Text(this.message)
              .id('HelloWorld')
              .fontSize($r('app.float.page_text_font_size'))
              .fontWeight(FontWeight.Bold)
              // 文字本身使用渐变色（API 20+）
              .shaderStyle({
                colors: this.colors,
                direction: GradientDirection.LeftBottom
              })
              .textAlign(TextAlign.Center)
              .alignRules({
                center: { anchor: '__container__', align: VerticalAlign.Center },
                middle: { anchor: '__container__', align: HorizontalAlign.Center }
              })
              .onClick(() => {
                // 点击文字后切换到黑屏
                this.isBlackScreen = true;
              })
          }
        }
      }
    }
    .width('100%')
    .height('100%')
  }
}