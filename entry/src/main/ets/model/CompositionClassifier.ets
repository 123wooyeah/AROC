/**
 * 构图识别分类器
 * 使用MindSpore Lite进行实时构图识别
 */
import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { mindSporeLite } from '@kit.MindSporeLiteKit';

// 24种构图类别（与训练脚本一致）
export const COMPOSITION_LABELS: string[] = [
  'C形曲线', 'O形曲线', 'S形曲线', '三角形',
  '中心点形', '单点三分', '图案', '垂直三线',
  '垂直二线', '垂直单边', '垂直均势', '垂直多线',
  '垂直居中', '多点三角', '多点垂直', '多点对角',
  '多点水平', '密集', '对角线', '散射',
  '水平三等分', '水平二等分', '漫射', '透视'
];

export interface ClassificationResult {
  label: string;
  confidence: number;
  index: number;
}

export class CompositionClassifier {
  private context: common.UIAbilityContext;
  private modelPath: string = 'composition_model.ms'; // 使用转换后的.ms模型
  private inputSize: number = 224; // 模型输入尺寸
  private model: mindSporeLite.Model | null = null;
  private isModelLoaded: boolean = false;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  /**
   * 加载模型
   */
  async loadModel(): Promise<boolean> {
    try {
      console.info('[CompositionClassifier] 开始加载模型...');
      
      // 从rawfile读取模型文件
      const resourceManager = this.context.resourceManager;
      const modelBuffer = await resourceManager.getRawFileContent(this.modelPath);
      
      console.info(`[CompositionClassifier] 模型文件大小: ${modelBuffer.buffer.byteLength} bytes`);
      
      // 配置运行环境
      const context: mindSporeLite.Context = {
        target: ['cpu'],
        cpu: {
          threadNum: 4,
          precisionMode: 'enforce_fp32'
        }
      };
      
      // 从buffer加载模型
      this.model = await mindSporeLite.loadModelFromBuffer(modelBuffer.buffer, context);
      
      if (this.model === null) {
        console.error('[CompositionClassifier] 模型加载失败: model is null');
        return false;
      }
      
      // 检查模型输入
      const inputs = await this.model.getInputs();
      if (inputs === null || inputs.length === 0) {
        console.error('[CompositionClassifier] 模型输入获取失败');
        return false;
      }
      
      console.info(`[CompositionClassifier] 模型加载成功，输入数量: ${inputs.length}`);
      console.info(`[CompositionClassifier] 输入名称: ${inputs[0].name}, 形状: ${inputs[0].shape}`);
      
      this.isModelLoaded = true;
      return true;
    } catch (error) {
      console.error(`[CompositionClassifier] 模型加载异常: ${JSON.stringify(error)}`);
      return false;
    }
  }

  /**
   * 预处理图像
   * 将图像调整为模型输入尺寸并归一化
   */
  private async preprocessImage(pixelMap: image.PixelMap): Promise<Float32Array> {
    try {
      const imageInfo = await pixelMap.getImageInfo();
      const width = imageInfo.size.width;
      const height = imageInfo.size.height;
      
      console.info(`[CompositionClassifier] 原始图像尺寸: ${width}x${height}`);
      
      // 检查尺寸是否有效
      if (width <= 0 || height <= 0) {
        console.error('[CompositionClassifier] 图像尺寸无效');
        throw new Error('Invalid image size');
      }
      
      // 保持宽高比缩放 - 使用较小的缩放比例
      const scaleX = this.inputSize / width;
      const scaleY = this.inputSize / height;
      const scale = Math.min(scaleX, scaleY);  // 使用较小的缩放比例，确保图像完整
      
      const newWidth = Math.round(width * scale);
      const newHeight = Math.round(height * scale);
      
      console.info(`[CompositionClassifier] 缩放比例: ${scale.toFixed(3)}, 新尺寸: ${newWidth}x${newHeight}`);
      
      // 缩放PixelMap
      await pixelMap.scale(scale, scale);
      
      // 读取像素数据
      const scalingImageInfo = await pixelMap.getImageInfo();
      const pixelBytesNumber = scalingImageInfo.size.width * 
                               scalingImageInfo.size.height * 4;
      const readBuffer = new ArrayBuffer(pixelBytesNumber);
      await pixelMap.readPixelsToBuffer(readBuffer);
      
      // 转换为Float32Array并归一化
      const uint8Data = new Uint8Array(readBuffer);
      const float32Data = new Float32Array(this.inputSize * this.inputSize * 3);
      
      // 计算填充偏移（居中填充）
      const offsetX = Math.floor((this.inputSize - newWidth) / 2);
      const offsetY = Math.floor((this.inputSize - newHeight) / 2);
      
      console.info(`[CompositionClassifier] 填充偏移: offsetX=${offsetX}, offsetY=${offsetY}`);
      
      // RGB归一化 (假设输入格式为RGBA)
      // 使用[-1, 1]归一化（MobileNet标准）
      // 填充为0（对应归一化后的-1）
      for (let i = 0; i < this.inputSize * this.inputSize; i++) {
        float32Data[i * 3] = -1.0;  // R
        float32Data[i * 3 + 1] = -1.0;  // G
        float32Data[i * 3 + 2] = -1.0;  // B
      }
      
      // 填充图像数据
      for (let y = 0; y < newHeight; y++) {
        for (let x = 0; x < newWidth; x++) {
          const srcIndex = (y * newWidth + x) * 4;
          const dstY = y + offsetY;
          const dstX = x + offsetX;
          const dstIndex = dstY * this.inputSize + dstX;
          
          const r = uint8Data[srcIndex];
          const g = uint8Data[srcIndex + 1];
          const b = uint8Data[srcIndex + 2];
          
          // 归一化到[-1, 1]范围
          float32Data[dstIndex * 3] = (r / 127.5) - 1.0;
          float32Data[dstIndex * 3 + 1] = (g / 127.5) - 1.0;
          float32Data[dstIndex * 3 + 2] = (b / 127.5) - 1.0;
        }
      }
      
      // 输出前几个像素值用于调试
      console.info(`[CompositionClassifier] 前5像素: R=${float32Data[0].toFixed(2)}, G=${float32Data[1].toFixed(2)}, B=${float32Data[2].toFixed(2)} | R=${float32Data[3].toFixed(2)}, G=${float32Data[4].toFixed(2)}, B=${float32Data[5].toFixed(2)}`);
      
      return float32Data;
    } catch (error) {
      console.error(`[CompositionClassifier] 图像预处理失败: ${JSON.stringify(error)}`);
      return new Float32Array(this.inputSize * this.inputSize * 3);
    }
  }

  /**
   * 执行推理
   */
  async classify(pixelMap: image.PixelMap): Promise<ClassificationResult | null> {
    if (!this.isModelLoaded || this.model === null) {
      console.error('[CompositionClassifier] 模型未加载');
      return null;
    }
    
    try {
      // 预处理图像
      const inputData = await this.preprocessImage(pixelMap);
      
      // 获取模型输入
      const inputs = await this.model.getInputs();
      if (inputs === null || inputs.length === 0) {
        console.error('[CompositionClassifier] 获取模型输入失败');
        return null;
      }
      
      // 设置输入数据
      const inputTensor = inputs[0];
      inputTensor.setData(inputData.buffer);
      
      // 执行推理
      const outputs = await this.model.predict(inputs);
      if (outputs === null || outputs.length === 0) {
        console.error('[CompositionClassifier] 推理失败: outputs is null or empty');
        return null;
      }
      
      // 获取输出数据
      const outputTensor = outputs[0];
      // 计算元素数量（从shape中计算）
      let elementsCount = 1;
      for (const dim of outputTensor.shape) {
        elementsCount *= dim;
      }
      const outputData = new Float32Array(elementsCount);
      const outputBuffer = outputTensor.getData();
      // 将ArrayBuffer转换为Float32Array
      const tempArray = new Float32Array(outputBuffer);
      for (let i = 0; i < elementsCount && i < tempArray.length; i++) {
        outputData[i] = tempArray[i];
      }
      
      // 找到最大概率的类别
      let maxIndex = 0;
      let maxProb = outputData[0];
      for (let i = 1; i < outputData.length && i < COMPOSITION_LABELS.length; i++) {
        if (outputData[i] > maxProb) {
          maxProb = outputData[i];
          maxIndex = i;
        }
      }
      
      const result: ClassificationResult = {
        label: COMPOSITION_LABELS[maxIndex],
        confidence: maxProb,
        index: maxIndex
      };
      
      console.info(`[CompositionClassifier] 识别结果: ${result.label}, 置信度: ${result.confidence.toFixed(4)}`);
      
      return result;
    } catch (error) {
      console.error(`[CompositionClassifier] 推理异常: ${JSON.stringify(error)}`);
      return null;
    }
  }
  
  /**
   * 获取所有类别的概率
   */
  async getAllProbabilities(pixelMap: image.PixelMap): Promise<number[]> {
    if (!this.isModelLoaded || this.model === null) {
      console.error('[CompositionClassifier] 模型未加载');
      return [];
    }
    
    try {
      // 预处理图像
      const inputData = await this.preprocessImage(pixelMap);
      
      // 获取模型输入
      const inputs = await this.model.getInputs();
      if (inputs === null || inputs.length === 0) {
        return [];
      }
      
      // 设置输入数据
      const inputTensor = inputs[0];
      inputTensor.setData(inputData.buffer);
      
      // 执行推理
      const outputs = await this.model.predict(inputs);
      if (outputs === null || outputs.length === 0) {
        return [];
      }
      
      // 获取输出数据
      const outputTensor = outputs[0];
      let elementsCount = 1;
      for (const dim of outputTensor.shape) {
        elementsCount *= dim;
      }
      console.info(`[CompositionClassifier] 模型输出维度: ${outputTensor.shape}, 元素数量: ${elementsCount}, 类别数量: ${COMPOSITION_LABELS.length}`);
      
      const outputData = new Float32Array(elementsCount);
      const outputBuffer = outputTensor.getData();
      const tempArray = new Float32Array(outputBuffer);
      for (let i = 0; i < elementsCount && i < tempArray.length; i++) {
        outputData[i] = tempArray[i];
      }
      
      // 返回所有概率
      const probabilities: number[] = [];
      const count = Math.min(COMPOSITION_LABELS.length, outputData.length);
      console.info(`[CompositionClassifier] 返回概率数量: ${count}`);
      for (let i = 0; i < count; i++) {
        probabilities.push(outputData[i]);
      }
      
      return probabilities;
    } catch (error) {
      console.error(`[CompositionClassifier] 获取概率异常: ${error}`);
      return [];
    }
  }

  /**
   * 释放模型资源
   */
  release(): void {
    if (this.model !== null) {
      // MindSpore Lite的Model对象会在垃圾回收时自动释放
      this.model = null;
      this.isModelLoaded = false;
      console.info('[CompositionClassifier] 模型资源已释放');
    }
  }
}
