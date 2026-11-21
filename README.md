# CarPlay 小组件（Airaw 模块）

Airaw 的模块式 CarPlay 小部件：**时间 + 日期 + 天气**。装好后在 Airaw 里直接添加，可拖动、可调大小、按层叠摆放。

- 包名：`com.axs.carwidget`
- 组件类：`AxsCarWidget`（`UIView`，实现 Airaw 的 `identifier / pageIndex / pageType` 协议）
- 默认尺寸：200 × 200（`Resources/AirawInfo.plist`）

## 目录结构

```
carwidget/
├── Makefile                 # 主 bundle：装到 /Library/Airaw/Widgets/Controls
├── control                  # deb 元数据
├── build.sh                 # rootful / rootless / roothide 本地构建
├── Widget/Classes/
│   ├── AxsCarWidget.h              # Airaw 入口类 + 控制协议
│   ├── AxsCarWidget.m              # 卡片 UI、时钟、天气渲染、Airaw 桥接
│   ├── AxsCarWidgetWeatherSource.h # 联网天气（单例，全局一次请求）
│   └── AxsCarWidgetWeatherSource.m # 定位 → Open-Meteo → 写回 plist
├── Sources/
│   ├── AxsCarWidgetConfig.h      # 配置键、默认值、天气码映射
│   └── AxsCarWidgetPreferences.h # 路径（rootless/roothide）、flock 合并写入、通知
├── Resources/               # 复制进 bundle
│   ├── AirawInfo.plist      # 默认宽高
│   ├── Config.plist         # Airaw 内嵌设置面板（备用入口，见下）
│   └── ModuleInfo.plist     # 指向 Prefs bundle
├── AxsCarWidgetPrefs/       # 设置面板（独立的 UI bundle，避免与组件主二进制冲突）
│   ├── AxsCarWidgetRootListController.m
│   ├── AxsCarWidgetStepperCell.m
│   └── Resources/AxsCarWidgetRoot.plist
├── layout/DEBIAN/           # postinst（chown mobile）/ postrm（清理配置）
├── Preview/                 # 纯浏览器预览，不进包
└── .github/workflows/       # GitHub Actions 自动打包 + 发布
```

## 安装后的布局

```
/Library/Airaw/Widgets/Controls/AxsCarWidget.bundle/AxsCarWidget          # 组件
/Library/Airaw/Widgets/Controls/AxsCarWidget.bundle/AirawInfo.plist
/Library/Airaw/Widgets/Controls/AxsCarWidget.bundle/Config.plist
/Library/Airaw/Widgets/Controls/AxsCarWidget.bundle/ModuleInfo.plist
/Library/Airaw/Widgets/Controls/AxsCarWidget.bundle/Prefs/AxsCarWidgetPrefs   # 面板 bundle
```

rootless 由 Theos 自动加 `/var/jb`。设置写入 `/Library/Airaw/Preferences/com.axs.carwidget.plist`（与 Airaw 自带模块同规则）。

## 使用

1. Airaw → 小部件 → **添加** → 选“时间天气”。
2. 长按调整位置/大小；点组件旁的设置进入面板。
3. 面板里可改：时间格式、日期格式、显示天气、今日最高/最低、翻页提示、天气刷新间隔。
4. 改完点 Airaw 的 **立即应用修改**（或重连 CarPlay）。

时间/日期格式遵循 `NSDateFormatter`：`HH:mm` 24 小时制，`h:mm a` 12 小时制，`M月d日 EEE` → `11月21日 周六`。

## 天气数据的来源

组件用 **Open-Meteo**（免费、无需 key）联网取天气，缓存 20 分钟：

- 默认读定位（`CLLocationManager`，权限由 Airaw 宿主进程授权；8 秒拿不到定位就退回城市）。
- 城市名用 `CLGeocoder` 在手机上解析成经纬度，**只把坐标发给接口**，城市名不出设备。
- 结果写入 `/Library/Airaw/Preferences/com.axs.carwidget.plist`（与设置同一份文件，`flock` 串行写入，面板和组件互不覆盖）。
- 失败时保留上一次数据；从没成功过则退化为居中时钟，不显示假温度。

plist 里的天气字段：

| 键 | 类型 | 示例 |
|---|---|---|
| `weatherCity` | string | 上海 |
| `weatherTemperature` | number | 18 |
| `weatherUnit` | string | `C` / `F` |
| `weatherConditionCode` | number | 44（见下） |
| `weatherHigh` / `weatherLow` | number | 23 / 12 |

| `weatherFetchedAt` | number | unix 秒，判断是否过期 |

WMO 天气码 → Apple 天气码的映射在 `AxsCarWidgetConditionCodeFromWMO`，Apple 码 → SF Symbol 在 `AxsCarWidgetSymbolForConditionCode`，两者都在 `Sources/AxsCarWidgetConfig.h`。

## 构建

```sh
# Linux（CI 同款，GitHub 上的 macOS runner 对这个账号不可用）
sh build-linux.sh rootless

# 已有 macOS + Theos + iPhoneOS16.5.sdk
export THEOS=~/theos
make package THEOS_PACKAGE_SCHEME=rootless FORCE_PACKAGE_NAME=yes PACKAGE_BUILDNAME=rootless
```

`build-linux.sh` 会：经 theos/sdks 的稀疏克隆取 221 MB 的 16.5 SDK → 取 Theos → 生成 clang / ld / lipo / ldid 包装脚本 → 交叉编译 → 产出 `packages/*.deb`。

- 架构 `arm64 arm64e`（fat），最低 iOS 15.0，SDK 16.5。
- Linux 上的 `ld64.lld` 会退化成普通 arm64，所以脚本在合并 fat 时按 `-arch` 修正 arm64e 的 CPU 类型。
- 面板装在 Airaw 的 Control bundle 内，打包需要 `FORCE_PACKAGE_NAME=yes`。
- 构建脚本不安装、不重启设备。

产物检查：

```sh
dpkg-deb -I packages/*.deb
dpkg-deb -c packages/*.deb                       # 应看到 AxsCarWidget.bundle 与其中的 Prefs/
llvm-objdump --macho --universal-headers <bundle>/AxsCarWidget   # arm64 + arm64e
```

## 预览

`Preview/AxsCarWidgetPreview.html` 是按 `-layoutWidget` 的比例复刻的网页版，可调时间/日期格式、温度单位、天气代码，并对比 200×200、桌面背景、拉宽三种情况。

## 已验证 / 未验证

- 已验证：与官方模块 `SUMusicWidget`、`ClockWidget`、`TwiWidget` 的 bundle 结构、`AirawInfo.plist`、`Config.plist` 单元格类型一致；配置逻辑（钳位、天气码映射）用 C 版本跑过；Open-Meteo 返回字段与解析代码对照过真实响应；plist 全部通过解析；预览页在浏览器渲染正常。
- 已验证：`build-linux.sh` 在本机实际跑通（Theos + iPhoneOS16.5 SDK + clang/ld64.lld），产出 rootless deb，包内是 arm64 + arm64e 双切片，install_name 为 `/var/jb/Library/Airaw/Widgets/Controls/AxsCarWidget.bundle/AxsCarWidget`。
- 未验证：真机运行（Airaw 加载组件、面板自动挂载 `ModuleInfo.plist`、定位权限弹窗）。`ModuleInfo.plist` 的键名和面板的自动挂载方式是对照 Dcsyhi 的 API 文档推断的；如果 Airaw 不认，面板仍可通过 Airaw 的模块设置入口（读取内嵌 `Config.plist`）使用。

## 后续可加

- 电量 / 多主题 / 逐小时预报
- 中文以外的天气文字本地化（`en.lproj / zh.lproj`）
- 12/24 小时自动跟随系统、车机语言本地化（`en.lproj / zh.lproj`）
