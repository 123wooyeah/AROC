#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
构图识别模型验证脚本
用于测试composition_model.ms模型的识别效果
"""

import os
import sys
import numpy as np
from PIL import Image

# 24种构图类别（与训练脚本一致）
COMPOSITION_LABELS = [
    'C形曲线', 'O形曲线', 'S形曲线', '三角形',
    '中心点形', '单点三分', '图案', '垂直三线',
    '垂直二线', '垂直单边', '垂直均势', '垂直多线',
    '垂直居中', '多点三角', '多点垂直', '多点对角',
    '多点水平', '密集', '对角线', '散射',
    '水平三等分', '水平二等分', '漫射', '透视'
]

def preprocess_image(image_path, input_size=224):
    """
    预处理图像
    1. 读取图像
    2. 保持宽高比缩放
    3. 居中填充到input_size x input_size
    4. 归一化到[-1, 1]
    """
    # 读取图像
    img = Image.open(image_path).convert('RGB')
    width, height = img.size
    print(f"原始图像尺寸: {width}x{height}")
    
    # 保持宽高比缩放
    scale = min(input_size / width, input_size / height)
    new_width = int(width * scale)
    new_height = int(height * scale)
    print(f"缩放比例: {scale:.3f}, 新尺寸: {new_width}x{new_height}")
    
    # 缩放图像
    img_resized = img.resize((new_width, new_height), Image.LANCZOS)
    
    # 创建填充图像（黑色背景）
    img_padded = Image.new('RGB', (input_size, input_size), (0, 0, 0))
    
    # 计算填充偏移（居中）
    offset_x = (input_size - new_width) // 2
    offset_y = (input_size - new_height) // 2
    print(f"填充偏移: offsetX={offset_x}, offsetY={offset_y}")
    
    # 粘贴缩放后的图像
    img_padded.paste(img_resized, (offset_x, offset_y))
    
    # 转换为numpy数组
    img_array = np.array(img_padded, dtype=np.float32)
    
    # 归一化到[-1, 1]
    img_normalized = (img_array / 127.5) - 1.0
    
    # 转换为模型输入格式 [1, 224, 224, 3]
    input_data = np.expand_dims(img_normalized, axis=0)
    
    return input_data, img_padded

def predict_with_mindspore_lite(model_path, input_data):
    """
    使用MindSpore Lite进行推理
    """
    try:
        import mindspore_lite as mslite
    except ImportError:
        print("错误: 未安装mindspore-lite")
        print("请运行: pip install mindspore-lite")
        return None
    
    # 创建上下文
    context = mslite.Context()
    context.target = ["cpu"]
    
    # 加载模型
    model = mslite.Model()
    model.build_from_file(model_path, mslite.ModelType.MINDIR, context)
    
    # 获取输入
    inputs = model.get_inputs()
    
    # 设置输入数据
    inputs[0].set_data_from_numpy(input_data)
    
    # 执行推理
    outputs = model.predict(inputs)
    
    # 获取输出
    output_data = outputs[0].get_data_to_numpy()
    
    return output_data

def predict_with_onnx(model_path, input_data):
    """
    使用ONNX Runtime进行推理（需要先将.ms转换为.onnx）
    """
    try:
        import onnxruntime as ort
    except ImportError:
        print("错误: 未安装onnxruntime")
        print("请运行: pip install onnxruntime")
        return None
    
    # 创建推理会话
    session = ort.InferenceSession(model_path)
    
    # 获取输入名称
    input_name = session.get_inputs()[0].name
    
    # 执行推理
    output = session.run(None, {input_name: input_data})
    
    return output[0]

def print_result(output_data):
    """
    打印识别结果
    """
    # 找到最大概率的类别
    max_index = np.argmax(output_data[0])
    max_prob = output_data[0][max_index]
    
    print("\n" + "="*50)
    print("识别结果")
    print("="*50)
    print(f"主要构图: {COMPOSITION_LABELS[max_index]}")
    print(f"置信度: {max_prob*100:.2f}%")
    
    # 打印前5个可能的类别
    print("\n前5个可能的构图:")
    top5_indices = np.argsort(output_data[0])[-5:][::-1]
    for i, idx in enumerate(top5_indices):
        print(f"  {i+1}. {COMPOSITION_LABELS[idx]}: {output_data[0][idx]*100:.2f}%")
    
    # 打印所有类别的概率
    print("\n所有构图类别概率:")
    for i, label in enumerate(COMPOSITION_LABELS):
        prob = output_data[0][i]
        bar = '█' * int(prob * 50)
        print(f"  {label:12s}: {prob*100:6.2f}% {bar}")

def main():
    # 模型路径
    model_path = "entry/src/main/resources/rawfile/composition_model.ms"
    
    # 检查模型文件
    if not os.path.exists(model_path):
        print(f"错误: 模型文件不存在: {model_path}")
        return
    
    # 获取图片路径
    if len(sys.argv) < 2:
        print("用法: python verify_model.py <图片路径>")
        print("示例: python verify_model.py test.jpg")
        return
    
    image_path = sys.argv[1]
    
    # 检查图片文件
    if not os.path.exists(image_path):
        print(f"错误: 图片文件不存在: {image_path}")
        return
    
    print(f"处理图片: {image_path}")
    print(f"模型文件: {model_path}")
    
    # 预处理图像
    input_data, img_padded = preprocess_image(image_path)
    print(f"输入数据形状: {input_data.shape}")
    
    # 保存预处理后的图像（用于调试）
    debug_path = "debug_preprocessed.jpg"
    img_padded.save(debug_path)
    print(f"预处理后的图像已保存到: {debug_path}")
    
    # 尝试使用MindSpore Lite推理
    print("\n尝试使用MindSpore Lite推理...")
    output_data = predict_with_mindspore_lite(model_path, input_data)
    
    if output_data is None:
        print("\nMindSpore Lite不可用，请确保已安装:")
        print("  pip install mindspore-lite")
        return
    
    # 打印结果
    print_result(output_data)

if __name__ == "__main__":
    main()
