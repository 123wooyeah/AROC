/**
 * 模型验证页面
 * 用于测试构图识别模型的效果
 */
import { common } from '@kit.AbilityKit';
import { abilityAccessCtrl, Permissions } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { picker } from '@kit.CoreFileKit';
import { fileIo } from '@kit.CoreFileKit';
import { router } from '@kit.ArkUI';
import { CompositionClassifier, COMPOSITION_LABELS, ClassificationResult } from '../model/CompositionClassifier';

@Entry
@Component
struct ModelVerifyPage {
  @State selectedImageUri: string = '';
  @State selectedImagePixelMap: image.PixelMap | null = null;
  @State isProcessing: boolean = false;
  @State result: ClassificationResult | null = null;
  @State allProbabilities: number[] = [];
  @State modelLoaded: boolean = false;
  @State statusMessage: string = '正在初始化模型...';
  
  private classifier: CompositionClassifier | null = null;
  
  async aboutToAppear() {
    // 初始化分类器
    const context = getContext(this) as common.UIAbilityContext;
    this.classifier = new CompositionClassifier(context);
    const success = await this.classifier.loadModel();
    this.modelLoaded = success;
    this.statusMessage = success ? '模型加载成功' : '模型加载失败';
  }
  
  // 选择图片
  async selectImage() {
    try {
      const photoSelectOptions = new picker.PhotoSelectOptions();
      photoSelectOptions.MIMEType = picker.PhotoViewMIMETypes.IMAGE_TYPE;
      photoSelectOptions.maxSelectNumber = 1;
      
      const photoPicker = new picker.PhotoViewPicker();
      const selectResult = await photoPicker.select(photoSelectOptions);
      
      if (selectResult.photoUris && selectResult.photoUris.length > 0) {
        this.selectedImageUri = selectResult.photoUris[0];
        await this.loadImage();
      }
    } catch (error) {
      const err = error as Error;
      console.error(`选择图片失败: ${err.message}`);
      this.statusMessage = `选择图片失败: ${err.message}`;
    }
  }
  
  // 加载图片
  async loadImage() {
    if (!this.selectedImageUri) return;
    
    try {
      // 打开文件
      const file = fileIo.openSync(this.selectedImageUri, fileIo.OpenMode.READ_ONLY);
      const stat = fileIo.statSync(file.fd);
      const fileSize = stat.size;
      
      // 读取文件内容
      const buffer = new ArrayBuffer(fileSize);
      fileIo.readSync(file.fd, buffer);
      fileIo.closeSync(file.fd);
      
      // 创建PixelMap
      const imageSource = image.createImageSource(buffer);
      this.selectedImagePixelMap = await imageSource.createPixelMap();
      
      // 清空之前的结果
      this.result = null;
      this.allProbabilities = [];
      this.statusMessage = '图片加载成功，点击识别按钮开始识别';
    } catch (error) {
      const err = error as Error;
      console.error(`加载图片失败: ${err.message}`);
      this.statusMessage = `加载图片失败: ${err.message}`;
    }
  }
  
  // 执行识别
  async classify() {
    if (!this.selectedImagePixelMap || !this.classifier) return;
    
    this.isProcessing = true;
    this.statusMessage = '正在识别...';
    
    try {
      // 执行识别
      const result = await this.classifier.classify(this.selectedImagePixelMap);
      this.result = result;
      
      // 获取所有概率
      if (this.classifier) {
        this.allProbabilities = await this.classifier.getAllProbabilities(this.selectedImagePixelMap);
      }
      
      this.statusMessage = result ? `识别完成: ${result.label}` : '识别失败';
    } catch (error) {
      const err = error as Error;
      console.error(`识别失败: ${err.message}`);
      this.statusMessage = `识别失败: ${err.message}`;
    } finally {
      this.isProcessing = false;
    }
  }
  
  build() {
    Scroll() {
      Column() {
        // 顶部栏：返回按钮 + 标题
        Row() {
          Button('返回')
            .fontSize(14)
            .backgroundColor('#666666')
            .onClick(() => {
              router.back()
            })
        
        Blank()
        
        Text('模型验证')
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
        
        Blank()
        
        // 占位，保持标题居中
        Button('返回')
          .fontSize(14)
          .backgroundColor('#666666')
          .visibility(Visibility.None)
      }
      .width('90%')
      .margin({ top: 20, bottom: 10 })
      
      // 状态信息
      Text(this.statusMessage)
        .fontSize(14)
        .fontColor('#666666')
        .margin({ bottom: 20 })
      
      // 选择图片按钮
      Button('选择图片')
        .width('80%')
        .height(50)
        .onClick(() => this.selectImage())
        .margin({ bottom: 20 })
      
      // 显示选中的图片
      if (this.selectedImagePixelMap) {
        Image(this.selectedImagePixelMap)
          .width(300)
          .height(200)
          .objectFit(ImageFit.Contain)
          .border({ width: 1, color: '#CCCCCC', radius: 10 })
          .margin({ bottom: 20 })
        
        // 识别按钮
        Button('识别构图')
          .width('80%')
          .height(50)
          .enabled(!this.isProcessing && this.modelLoaded)
          .onClick(() => this.classify())
          .margin({ bottom: 20 })
        
        // 显示识别结果
        if (this.result) {
          Column() {
            Text(`识别结果: ${this.result.label}`)
              .fontSize(20)
              .fontWeight(FontWeight.Bold)
            
            Text(`置信度: ${(this.result.confidence * 100).toFixed(2)}%`)
              .fontSize(18)
              .margin({ top: 10 })
            
            // 显示所有类别的概率
            if (this.allProbabilities.length > 0) {
              Text('所有类别概率:')
                .fontSize(16)
                .fontWeight(FontWeight.Bold)
                .margin({ top: 20, bottom: 10 })
              
              Scroll() {
                Column() {
                  ForEach(COMPOSITION_LABELS, (label: string, index: number) => {
                    Row() {
                      Text(`${index + 1}. ${label}`)
                        .width(120)
                        .fontSize(12)
                      
                      // 概率条
                      Stack() {
                        // 背景条
                        Row()
                          .width('100%')
                          .height(16)
                          .backgroundColor('#E0E0E0')
                        
                        // 概率条
                        Row()
                          .width(`${(this.allProbabilities[index] ?? 0) * 100}%`)
                          .height(16)
                          .backgroundColor('#4CAF50')
                      }
                      .width(150)
                      
                      Text(`${((this.allProbabilities[index] ?? 0) * 100).toFixed(1)}%`)
                        .width(60)
                        .fontSize(12)
                    }
                    .width('100%')
                    .margin({ top: 3 })
                  }, (label: string, index: number) => `${index}_${label}`)
                }
                .width('100%')
              }
              .width('100%')
              .margin({ top: 10 })
            }
          }
          .width('90%')
          .padding(20)
          .backgroundColor('#F5F5F5')
          .borderRadius(10)
        }
      }
      
      // 加载中提示
      if (this.isProcessing) {
        LoadingProgress()
          .width(50)
          .height(50)
          .margin({ top: 20 })
        
        Text('识别中...')
          .fontSize(16)
          .margin({ top: 10 })
        }
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#FFFFFF')
    .scrollBar(BarState.Auto)
  }
}
