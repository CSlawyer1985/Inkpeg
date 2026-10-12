# 文夹自有 App 图标

图标使用官网及宣传片的 `site/assets/mark.svg`：深色底、暖纸卡片、银色夹子与红色绳段。`scripts/make-icon.swift` 按同一 SVG 几何生成 16–1024 像素 iconset，再由系统 iconutil 生成 Inkpeg.icns。

不使用上游 Tendedero 名称、图标或 docs 效果图。实际 App 的 Info.plist 声明 CFBundleIconFile=Inkpeg.icns，打包检查比对真实资源 SHA；这不代表 Finder 或应用切换器实机验收。
