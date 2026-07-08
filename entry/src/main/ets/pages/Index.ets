import { camera } from '@kit.CameraKit';
import { common } from '@kit.AbilityKit';
import { abilityAccessCtrl, Permissions } from '@kit.AbilityKit';
import { SuppressWarnings, SuppressWarningsType } from '@kit.BasicServicesKit';
import { window } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';
import { CompositionClassifier, COMPOSITION_LABELS, ClassificationResult } from '../model/CompositionClassifier';

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
  private xComponentController: XComponentController = new XComponentController()
  private surfaceId: string = ''
  private context: common.UIAbilityContext | null = null
  private receiverSurfaceId: string = ''
  // ImageReceiver用于获取预览帧数据
  private imageReceiver: image.ImageReceiver | null = null
  // 构图识别相关变量
  private compositionClassifier: CompositionClassifier | null = null
  private classifyInterval: number = -1
  @State currentComposition: string = ''
  @State currentConfidence: number = 0.0
  @State compositionResult: ClassificationResult | null = null
  @State isClassifying: boolean = false
  // 模型运行状态信息
  @State modelLoadStatus: string = '未加载'
  @State classifyCount: number = 0
  @State classifySuccessCount: number = 0
  @State classifyFailCount: number = 0
  @State lastClassifyTime: string = ''
  @State lastError: string = ''
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
    // 初始化构图识别器
    if (this.context) {
      this.modelLoadStatus = '正在加载模型...'
      this.compositionClassifier = new CompositionClassifier(this.context)
      this.compositionClassifier.loadModel()
        .then((success) => {
          if (success) {
            this.modelLoadStatus = '模型加载成功 ✓'
            console.info('[Index] Composition classifier initialized successfully')
          } else {
            this.modelLoadStatus = '模型加载失败 ✗'
            this.lastError = '模型文件可能不存在或格式错误'
            console.error('[Index] Failed to initialize composition classifier')
          }
        })
        .catch((error: Error) => {
          this.modelLoadStatus = '模型加载异常 ✗'
          this.lastError = error.message || '未知错误'
          console.error('[Index] Model load error: ' + error)
        })
    } else {
      this.modelLoadStatus = '上下文初始化失败 ✗'
    }
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
    // 停止构图识别定时器
    if (this.classifyInterval !== -1) {
      clearInterval(this.classifyInterval)
      this.classifyInterval = -1
    }
    // 释放构图识别器
    if (this.compositionClassifier) {
      this.compositionClassifier.release()
    }
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

      // 创建ImageReceiver用于构图识别
      this.imageReceiver = image.createImageReceiver(matchedProfile.size.width, matchedProfile.size.height, 
                                                     image.ImageFormat.JPEG, 2)
      this.receiverSurfaceId = await this.imageReceiver.getReceivingSurfaceId()
      console.info(`ImageReceiver created, surfaceId: ${this.receiverSurfaceId}`)

      this.previewOutput = this.cameraManager.createPreviewOutput(matchedProfile, this.surfaceId)

      // 创建拍照会话
      this.photoSession = this.cameraManager.createSession(sceneMode) as camera.PhotoSession

      // 开始配置会话
      this.photoSession.beginConfig()
      this.photoSession.addInput(this.cameraInput)
      this.photoSession.addOutput(this.previewOutput)
      
      // 添加ImageReceiver作为额外输出（用于构图识别）
      const previewOutputForReceiver = this.cameraManager.createPreviewOutput(matchedProfile, this.receiverSurfaceId)
      this.photoSession.addOutput(previewOutputForReceiver)
      
      await this.photoSession.commitConfig()

      // 启动预览
      await this.photoSession.start()

      console.info('Camera preview started successfully')
      
      // 启动构图识别定时器（每秒识别一次）
      this.startCompositionClassification()
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

  // 启动构图识别定时器
  startCompositionClassification() {
    // 每1.5秒识别一次构图
    this.classifyInterval = setInterval(async () => {
      if (this.imageReceiver && this.compositionClassifier) {
        this.isClassifying = true
        this.classifyCount++
        
        try {
          // 从ImageReceiver读取最新一帧
          const nextImage = await this.imageReceiver.readNextImage()
          if (nextImage) {
            // 尝试获取JPEG组件（某些设备支持JPEG输出）
            let jpegComponent: image.Component | null = null
            try {
              jpegComponent = await nextImage.getComponent(image.ComponentType.JPEG)
            } catch (e) {
              console.error(`[Composition] JPEG获取失败: ${e}`)
            }
            
            if (jpegComponent && jpegComponent.byteBuffer && jpegComponent.byteBuffer.byteLength > 100) {
              // 使用JPEG数据（实际是NV21格式的YUV数据）
              const bufferSize = jpegComponent.byteBuffer.byteLength
              console.info(`[Composition] 图像数据大小: ${bufferSize} bytes`)
              
              try {
                // 预览尺寸
                const width = 2336
                const height = 1088
                
                // 将数据当作NV21格式处理
                const pixelMap = await this.nv21ToPixelMap(
                  jpegComponent.byteBuffer,
                  width,
                  height
                )
                
                if (pixelMap) {
                  const result = await this.compositionClassifier.classify(pixelMap)
                  if (result) {
                    this.currentComposition = result.label
                    this.currentConfidence = result.confidence
                    this.classifySuccessCount++
                    this.lastClassifyTime = new Date().toLocaleTimeString()
                    this.lastError = ''
                    console.info(`[Composition] ${result.label}: ${(result.confidence * 100).toFixed(1)}%`)
                  } else {
                    this.classifyFailCount++
                    this.lastError = '识别结果为空'
                  }
                  pixelMap.release()
                } else {
                  this.classifyFailCount++
                  this.lastError = 'PixelMap创建失败'
                }
              } catch (decodeError) {
                this.classifyFailCount++
                this.lastError = `NV21处理失败: ${decodeError}`
                console.error(`[Composition] NV21 error: ${decodeError}`)
              }
            } else {
              // JPEG不可用，尝试YUV
              let yComponent: image.Component | null = null
              let uComponent: image.Component | null = null
              let vComponent: image.Component | null = null
              
              try {
                yComponent = await nextImage.getComponent(image.ComponentType.YUV_Y)
              } catch (e) {
                console.error(`[Composition] YUV_Y获取失败: ${e}`)
              }
              
              try {
                uComponent = await nextImage.getComponent(image.ComponentType.YUV_U)
              } catch (e) {
                console.error(`[Composition] YUV_U获取失败: ${e}`)
              }
              
              try {
                vComponent = await nextImage.getComponent(image.ComponentType.YUV_V)
              } catch (e) {
                console.error(`[Composition] YUV_V获取失败: ${e}`)
              }
              
              if (yComponent && yComponent.byteBuffer && uComponent && uComponent.byteBuffer && vComponent && vComponent.byteBuffer) {
                const ySize = yComponent.byteBuffer.byteLength
                const uSize = uComponent.byteBuffer.byteLength
                const vSize = vComponent.byteBuffer.byteLength
                console.info(`[Composition] YUV大小: Y=${ySize}, U=${uSize}, V=${vSize}`)
              
                try {
                  // 预览尺寸
                  const width = 2336
                  const height = 1088
                  
                  // YUV转RGB并创建PixelMap
                  const pixelMap = await this.yuvToPixelMap(
                    yComponent.byteBuffer,
                    uComponent.byteBuffer,
                    vComponent.byteBuffer,
                    width,
                    height
                  )
                  
                  if (!pixelMap) {
                    this.classifyFailCount++
                    this.lastError = 'PixelMap创建失败'
                    nextImage.release()
                    return
                  }
                  
                  // 执行构图识别
                  const result = await this.compositionClassifier.classify(pixelMap)
                  if (result) {
                    // 更新识别结果
                    this.currentComposition = result.label
                    this.currentConfidence = result.confidence
                    this.classifySuccessCount++
                  this.lastClassifyTime = new Date().toLocaleTimeString()
                  this.lastError = ''
                  console.info(`[Composition] ${result.label}: ${(result.confidence * 100).toFixed(1)}%`)
                } else {
                  this.classifyFailCount++
                  this.lastError = '识别结果为空'
                }
                // 释放PixelMap
                pixelMap.release()
                } catch (decodeError) {
                  this.classifyFailCount++
                  this.lastError = `YUV处理失败: ${decodeError}`
                  console.error(`[Composition] YUV error: ${decodeError}`)
                }
              } else {
                this.classifyFailCount++
                this.lastError = 'YUV组件获取失败'
              }
            }
            // 释放Image
            nextImage.release()
          } else {
            this.classifyFailCount++
            this.lastError = '未获取到预览帧'
          }
        } catch (error) {
          this.classifyFailCount++
          this.lastError = `识别异常: ${error}`
          console.error(`[Composition] Classification error: ${error}`)
        } finally {
          this.isClassifying = false
        }
      }
    }, 1500) // 每1.5秒识别一次
    console.info('[Composition] Classification timer started')
  }

  startGradientAnimation() {
    // 使用线性渐变变换
    setInterval(() => {
      this.gradientAnimation = (this.gradientAnimation + 1) % 360
      this.updateColors(this.gradientAnimation)
    }, 50) // 50ms更新一次，实现流畅渐变
  }

  // NV21转PixelMap
  async nv21ToPixelMap(nv21Buffer: ArrayBuffer, width: number, height: number): Promise<image.PixelMap | null> {
    try {
      const nv21Data = new Uint8Array(nv21Buffer)
      
      // NV21格式：Y平面 + VU交错
      const ySize = width * height
      const vuSize = ySize / 2
      
      console.info(`[Composition] NV21: Y=${ySize}, VU=${vuSize}, 总=${nv21Data.length}`)
      
      // 创建RGBA数据buffer
      const rgbaSize = width * height * 4
      const rgbaData = new Uint8Array(rgbaSize)
      
      // NV21转RGB
      for (let i = 0; i < height; i++) {
        for (let j = 0; j < width; j++) {
          const yIndex = i * width + j
          
          // VU交错数据索引
          const vuIndex = ySize + (Math.floor(i / 2) * width) + (j & ~1)
          const v = nv21Data[vuIndex] - 128
          const u = nv21Data[vuIndex + 1] - 128
          
          const y = nv21Data[yIndex]
          
          // YUV转RGB公式
          let r = y + 1.402 * v
          let g = y - 0.34414 * u - 0.71414 * v
          let b = y + 1.772 * u
          
          // 限制范围0-255
          r = Math.max(0, Math.min(255, r))
          g = Math.max(0, Math.min(255, g))
          b = Math.max(0, Math.min(255, b))
          
          const rgbaIndex = yIndex * 4
          rgbaData[rgbaIndex] = Math.round(r)     // R
          rgbaData[rgbaIndex + 1] = Math.round(g) // G
          rgbaData[rgbaIndex + 2] = Math.round(b) // B
          rgbaData[rgbaIndex + 3] = 255           // A
        }
      }
      
      // 输出前几个像素值用于调试
      console.info(`[Composition] NV21前5像素: Y=${nv21Data[0]}, V=${nv21Data[ySize]}, U=${nv21Data[ySize+1]}`)
      console.info(`[Composition] RGB前5像素: R=${rgbaData[0]}, G=${rgbaData[1]}, B=${rgbaData[2]}`)
      
      // 创建PixelMap
      const options: image.InitializationOptions = {
        size: { width, height },
        pixelFormat: image.PixelMapFormat.RGBA_8888,
        editable: true
      }
      
      const pixelMap = await image.createPixelMapSync(rgbaData.buffer, options)
      return pixelMap
    } catch (error) {
      console.error(`[Composition] NV21转换失败: ${error}`)
      return null
    }
  }

  // YUV转PixelMap
  async yuvToPixelMap(yBuffer: ArrayBuffer, uBuffer: ArrayBuffer, vBuffer: ArrayBuffer, 
                      width: number, height: number): Promise<image.PixelMap | null> {
    try {
      const yData = new Uint8Array(yBuffer)
      const uData = new Uint8Array(uBuffer)
      const vData = new Uint8Array(vBuffer)
      
      // 创建RGBA数据buffer
      const rgbaSize = width * height * 4
      const rgbaData = new Uint8Array(rgbaSize)
      
      // YUV转RGB
      for (let i = 0; i < height; i++) {
        for (let j = 0; j < width; j++) {
          const yIndex = i * width + j
          const uvIndex = Math.floor(i / 2) * Math.floor(width / 2) + Math.floor(j / 2)
          
          const y = yData[yIndex]
          const u = uData[uvIndex] - 128
          const v = vData[uvIndex] - 128
          
          // YUV转RGB公式
          let r = y + 1.402 * v
          let g = y - 0.34414 * u - 0.71414 * v
          let b = y + 1.772 * u
          
          // 限制范围0-255
          r = Math.max(0, Math.min(255, r))
          g = Math.max(0, Math.min(255, g))
          b = Math.max(0, Math.min(255, b))
          
          const rgbaIndex = yIndex * 4
          rgbaData[rgbaIndex] = Math.round(r)     // R
          rgbaData[rgbaIndex + 1] = Math.round(g) // G
          rgbaData[rgbaIndex + 2] = Math.round(b) // B
          rgbaData[rgbaIndex + 3] = 255           // A
        }
      }
      
      // 创建PixelMap
      const options: image.InitializationOptions = {
        size: { width, height },
        pixelFormat: image.PixelMapFormat.RGBA_8888,
        editable: true
      }
      
      const pixelMap = await image.createPixelMapSync(rgbaData.buffer, options)
      return pixelMap
    } catch (error) {
      console.error(`[Composition] YUV转换失败: ${error}`)
      return null
    }
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
          
          // 构图识别结果显示
          if (this.currentComposition !== '') {
            Column() {
              Text(this.currentComposition)
                .fontSize(18)
                .fontColor(Color.White)
                .fontWeight(FontWeight.Bold)
                .textShadow({ radius: 2, color: '#88000000', offsetX: 1, offsetY: 1 })
              
              Text(`${(this.currentConfidence * 100).toFixed(1)}%`)
                .fontSize(14)
                .fontColor('#FFFFFF')
                .margin({ top: 4 })
                .textShadow({ radius: 2, color: '#88000000', offsetX: 1, offsetY: 1 })
            }
            .padding({ left: 16, right: 16, top: 8, bottom: 8 })
            .backgroundColor('#88000000')
            .borderRadius(8)
            .position({ x: 16, y: 50 })
          }
          
          // 模型运行状态信息面板
          Column() {
            // 模型加载状态
            Row() {
              Text('模型状态: ')
                .fontSize(12)
                .fontColor('#AAAAAA')
              Text(this.modelLoadStatus)
                .fontSize(12)
                .fontColor(this.modelLoadStatus.includes('成功') ? '#4CAF50' : 
                           this.modelLoadStatus.includes('失败') || this.modelLoadStatus.includes('异常') ? '#F44336' : '#FFC107')
                .fontWeight(FontWeight.Medium)
            }
            .width('100%')
            .margin({ bottom: 6 })
            
            // 识别统计
            Row() {
              Text(`识别次数: ${this.classifyCount}`)
                .fontSize(12)
                .fontColor('#AAAAAA')
              Blank()
              Text(`成功: ${this.classifySuccessCount}`)
                .fontSize(12)
                .fontColor('#4CAF50')
              Text(` | 失败: ${this.classifyFailCount}`)
                .fontSize(12)
                .fontColor('#F44336')
            }
            .width('100%')
            .margin({ bottom: 6 })
            
            // 当前状态
            Row() {
              Text(this.isClassifying ? '⏳ 识别中...' : '✓ 等待下次识别')
                .fontSize(12)
                .fontColor(this.isClassifying ? '#FFC107' : '#4CAF50')
            }
            .width('100%')
            .margin({ bottom: 6 })
            
            // 最后识别时间
            if (this.lastClassifyTime !== '') {
              Row() {
                Text(`最后识别: ${this.lastClassifyTime}`)
                  .fontSize(11)
                  .fontColor('#888888')
              }
              .width('100%')
              .margin({ bottom: 4 })
            }
            
            // 错误信息
            if (this.lastError !== '') {
              Row() {
                Text(`错误: ${this.lastError}`)
                  .fontSize(11)
                  .fontColor('#F44336')
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .width('100%')
            }
          }
          .width(280)
          .padding(10)
          .backgroundColor('#99000000')
          .borderRadius(8)
          .position({ x: 16, y: 120 })
          .justifyContent(FlexAlign.Start)
          .alignItems(HorizontalAlign.Start)
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