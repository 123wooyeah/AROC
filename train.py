import os
os.environ['TF_CPP_MIN_LOG_LEVEL'] = '2'

import numpy as np
import tensorflow as tf
from tensorflow.keras import layers, models
from PIL import Image
import gc

# ==================== 配置 ====================
DATA_DIR = r'D:\TrainingModel\CompositionRecognitionModel\data\PICD'
MODEL_SAVE_PATH = r'D:\TrainingModel\CompositionRecognitionModel\model\composition_model.tflite'

CATEGORIES = [
    'C形曲线', 'O形曲线', 'S形曲线', '三角形',
    '中心点形', '单点三分', '图案', '垂直三线',
    '垂直二线', '垂直单边', '垂直均势', '垂直多线',
    '垂直居中', '多点三角', '多点垂直', '多点对角',
    '多点水平', '密集', '对角线', '散射',
    '水平三等分', '水平二等分', '漫射', '透视'
]

IMG_SIZE = (224, 224)
BATCH_SIZE = 16
EPOCHS = 30
VALIDATION_SPLIT = 0.15

# ==================== 加载数据 ====================
def load_data():
    """从文件夹结构加载图片和标签，过滤无效图片"""
    images = []
    labels = []
    invalid_count = 0

    for label_idx, category in enumerate(CATEGORIES):
        category_dir = os.path.join(DATA_DIR, category)
        if not os.path.exists(category_dir):
            continue
        for img_file in os.listdir(category_dir):
            if img_file.lower().endswith(('.jpg', '.jpeg', '.png')):
                img_path = os.path.join(category_dir, img_file)
                try:
                    with Image.open(img_path) as img:
                        img.verify()
                    images.append(img_path)
                    labels.append(label_idx)
                except Exception:
                    invalid_count += 1

    print(f"Total valid images: {len(images)} (skipped {invalid_count} invalid)")
    return images, labels

def preprocess_image(img_path, label):
    """图片预处理"""
    raw = tf.io.read_file(img_path)
    img = tf.image.decode_jpeg(raw, channels=3)
    img = tf.image.resize(img, IMG_SIZE)
    img = tf.cast(img, tf.float32) / 255.0
    return img, label

# ==================== 构建模型 ====================
def build_model(trainable_base=False):
    base_model = tf.keras.applications.MobileNetV2(
        input_shape=(*IMG_SIZE, 3),
        include_top=False,
        weights='imagenet'
    )
    base_model.trainable = trainable_base

    model = models.Sequential([
        base_model,
        layers.GlobalAveragePooling2D(),
        layers.Dropout(0.3),
        layers.Dense(256, activation='relu'),
        layers.Dropout(0.2),
        layers.Dense(len(CATEGORIES), activation='softmax')
    ])

    model.compile(
        optimizer=tf.keras.optimizers.Adam(learning_rate=1e-3 if not trainable_base else 1e-5),
        loss='sparse_categorical_crossentropy',
        metrics=['accuracy']
    )
    return model

# ==================== 训练 ====================
def train():
    img_paths, labels = load_data()
    if len(img_paths) == 0:
        print("No images found!")
        return

    # 打乱
    indices = np.arange(len(img_paths))
    np.random.seed(42)
    np.random.shuffle(indices)
    img_paths = np.array(img_paths)[indices]
    labels = np.array(labels)[indices]

    val_count = int(len(img_paths) * VALIDATION_SPLIT)
    train_paths, train_labels = img_paths[val_count:], labels[val_count:]
    val_paths, val_labels = img_paths[:val_count], labels[:val_count]

    print(f"Train: {len(train_paths)}, Validation: {len(val_paths)}")

    train_ds = tf.data.Dataset.from_tensor_slices((train_paths, train_labels))
    train_ds = train_ds.map(preprocess_image, num_parallel_calls=tf.data.AUTOTUNE)
    train_ds = train_ds.shuffle(buffer_size=2048).batch(BATCH_SIZE).prefetch(tf.data.AUTOTUNE)

    val_ds = tf.data.Dataset.from_tensor_slices((val_paths, val_labels))
    val_ds = val_ds.map(preprocess_image, num_parallel_calls=tf.data.AUTOTUNE)
    val_ds = val_ds.batch(BATCH_SIZE).prefetch(tf.data.AUTOTUNE)

    callbacks = [
        tf.keras.callbacks.EarlyStopping(patience=5, restore_best_weights=True, monitor='val_accuracy'),
        tf.keras.callbacks.ReduceLROnPlateau(factor=0.5, patience=3, monitor='val_loss'),
        tf.keras.callbacks.ModelCheckpoint(filepath='best_phase1.keras', monitor='val_accuracy', save_best_only=True),
    ]

    print("\n=== Phase 1: Training head only ===")
    model = build_model(trainable_base=False)
    model.fit(train_ds, validation_data=val_ds, epochs=EPOCHS, callbacks=callbacks)

    # 保存best权重
    best_model = models.load_model('best_phase1.keras', compile=False)

    # 清理
    del model
    gc.collect()

    # Phase 2: 微调
    print("\n=== Phase 2: Fine-tuning base layers ===")
    model2 = build_model(trainable_base=True)
    # 复制head权重
    for i in range(2, len(best_model.layers)):
        if i < len(model2.layers):
            model2.layers[i].set_weights(best_model.layers[i].get_weights())

    callbacks2 = [
        tf.keras.callbacks.EarlyStopping(patience=5, restore_best_weights=True, monitor='val_accuracy'),
        tf.keras.callbacks.ReduceLROnPlateau(factor=0.5, patience=3, monitor='val_loss'),
        tf.keras.callbacks.ModelCheckpoint(filepath='best_phase2.keras', monitor='val_accuracy', save_best_only=True),
    ]
    model2.fit(train_ds, validation_data=val_ds, epochs=EPOCHS, callbacks=callbacks2)

    # 保存最终tflite
    converter = tf.lite.TFLiteConverter.from_keras_model(model2)
    tflite_model = converter.convert()
    with open(MODEL_SAVE_PATH, 'wb') as f:
        f.write(tflite_model)
    print(f"\nFinal model saved to {MODEL_SAVE_PATH}")

    # 清理中间文件
    os.remove('best_phase1.keras')
    os.remove('best_phase2.keras')

if __name__ == '__main__':
    train()
