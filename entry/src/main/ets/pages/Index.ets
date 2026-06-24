@Entry
@Component
struct Index {
  @State message: string = 'Hello World';
  @State textColor: ResourceColor = Color.Black
  build() {
    RelativeContainer() {
      Text(this.message)
        .id('HelloWorld')
        .fontSize($r('app.float.page_text_font_size'))
        .fontWeight(FontWeight.Bold)
        .fontColor(this.textColor)
        .alignRules({
          center: { anchor: '__container__', align: VerticalAlign.Center },
          middle: { anchor: '__container__', align: HorizontalAlign.Center }
        })
        .onClick(() => {
          // this.message = 'Welcome';
          // this.textColor = Color.Blue;
        })
    }
    .height('100%')
    .width('100%')
  }
}