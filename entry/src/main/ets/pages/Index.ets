@Entry
@Component
struct Index {
  @State message: string = 'Hello World';
  @State isBlackScreen: boolean = false
  private gradientAnimation: number = 0
  @State colors: Array<[ResourceColor, number]> = []

  aboutToAppear() {
    // 启动渐变动画
    this.startGradientAnimation()
    // 初始化颜色
    this.updateColors(0)
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
        // 黑屏背景
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(Color.Black)
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