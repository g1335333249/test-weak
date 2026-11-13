# 服务 e 点通 3.3.3 本地安全检查测试 tweak

目标 IPA：`服务e点通.ipa`（`com.nari.digitalAttendance`，iOS 15+，ARM64）。工程使用 Theos Logos，生成 rootless jailbreak 的 `.deb` 包。IPA 中的主程序 `cryptid=0`，因此可以检查 Objective-C 元数据；这里没有设备或服务端测试结果。

## 已写入的测试点

| 开关 | 行为 | 静态依据 |
| --- | --- | --- |
| `vpn_override` | 将 `NRVpnTool -isVpnOnline` 强制设为在线或离线 | 主程序的方法签名为 `BOOL` |
| `location_override` | 将 `CLLocationSourceInformation -isSimulatedBySoftware` 返回 `NO`，并关闭两个高德定位管理器的 `detectRiskOfFakeLocation` | IPA 含这些 selector 和管理器属性 |
| `custom_location_enabled` | 在定位开关打开且经纬度有效时，让 `CLLocation -coordinate` 返回指定坐标 | 用于验证应用是否直接读取 Core Location 坐标 |
| `direct_location_delivery` | 在上述条件下拦截 `CLLocationManager -requestLocation` 和 `-startUpdatingLocation`，直接向 delegate 回传测试位置 | 用于验证是否可跳过系统定位请求；尚未验证应用全部路径 |
| `device_id_override` | 对 `NSUserDefaults` 读取 `E_DIAN_TONG_DEVICE_ID` 时返回配置的旧设备 ID | IPA 含此键；尚未确认登录请求一定从这里读取 |
| `idfv_override` | 用配置的 UUID 替换 `UIDevice -identifierForVendor` | 用于排查另一种设备标识路径，尚未确认应用使用它 |

注入后，应用右侧会出现可拖动的“测试”悬浮按钮。点开后可设置 VPN、定位和设备标识开关；点面板标题即可折叠。定位区可输入经纬度，或打开地图轻点选点并确认。打开“虚拟定位检测改写”和“使用指定经纬度”后，坐标改写才生效；再打开“直接返回测试位置”，可测试跳过 Core Location 的系统请求。地图选点使用 MapKit，需有地图数据网络连接，坐标以地图返回值为准。

两个设备标识输入框下方显示“原始”和“返回”值，可点“刷新当前读取值”重新读取。这里显示的是对应系统 API 的返回结果；应用若另用 Keychain、SDK 或服务端数据生成设备指纹，仍需结合登录请求确认。设置保存在应用自己的容器中，开关默认关闭。设备标识开关只有填写非空旧设备 ID 才生效；IDFV 开关只有填写有效 UUID 才生效。不要将真实旧设备 ID 提交到仓库。`settings.example.plist` 仅展示配置格式，不需要手动复制。

## 构建与测试

在 Actions 手动运行 **Build EDT Probe**，也可以推送受监控的文件触发构建。从运行结果下载 `edt-probe-rootless` 包，在已安装兼容注入环境的 rootless 越狱测试设备上安装。工作流使用 macOS runner、自带的 iPhoneOS SDK 和 Theos 源码，并运行 `make clean package FINALPACKAGE=1`。

注入后直接在悬浮面板中逐项配置。保存后重新发起登录或定位测试；定位 SDK 若已经初始化并缓存了检测状态，可能需要重启应用再测。通过系统日志搜索 `[EDTProbe]`，确认 tweak 已加载且目标方法被调用。

建议每次只打开一个开关，分别记录：登录结果、VPN 状态、定位结果、服务端返回的错误码。VPN 在线和离线两档都需要分别测；此应用包含企业 VPN SDK，不能从方法名推断哪档会解除限制。

## 结果边界与修复方向

这份工程是待验证的本地绕过 PoC，当前没有证明新终端登录、VPN 或虚拟定位限制已被绕过。特别是 `NRXinTongLoginVC -updateUserDevice` 和 `API_updateUserDevice` 暗示有服务端设备注册流程；若服务端独立绑定设备或验证位置与网络，单改客户端返回值不会通过。

防护上，设备注册与变更应由服务端决定并要求额外验证；敏感请求应绑定短时挑战、账号、设备注册状态以及服务端可验证的信号。定位真实性与 VPN 策略不能只依赖一个客户端布尔值。测试时应同时检查服务端是否拒绝篡改后的请求。
