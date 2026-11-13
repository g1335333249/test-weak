# 服务 e 点通 3.3.3 本地安全检查测试 tweak

目标 IPA：`服务e点通.ipa`（`com.nari.digitalAttendance`，iOS 15+，ARM64）。工程使用 Theos Logos，生成 rootless jailbreak 的 `.deb` 包。IPA 中的主程序 `cryptid=0`，因此可以检查 Objective-C 元数据；这里没有设备或服务端测试结果。

注入过滤不依赖 bundle ID：`EDTProbe.plist` 按 `NRXinTongLoginVC` 类匹配进程，tweak 初始化时再确认 `NRVpnTool` 也存在。因此同一应用重签后即使 bundle ID 改变，只要这些类名保持不变，仍可尝试注入。它不是对任意 iOS 应用通用；应用更新若重命名或移除这些类，需要重新分析并调整过滤条件。

## 已写入的测试点

| 开关 | 行为 | 静态依据 |
| --- | --- | --- |
| `vpn_override` | 将 `NRVpnTool -isVpnOnline` 强制设为在线或离线 | 主程序的方法签名为 `BOOL` |
| `location_override` | 将 `CLLocationSourceInformation -isSimulatedBySoftware` 返回 `NO`，把 `CLLocation -dataSourceDescription` 设为 `LocationDataSourceRealWorld`，把 `NRSpeedDKUtil`/`NRSpeedSignUtil` 的 `isVirtual` 置 0，并关闭两个高德定位管理器的 `detectRiskOfFakeLocation` | 主程序含这些 selector 与属性；此处覆盖本地识别与请求参数路径 |
| `custom_location_enabled` | 在定位开关打开且经纬度有效时，让 `CLLocation -coordinate` 返回指定坐标 | 用于验证应用是否直接读取 Core Location 坐标 |
| `direct_location_delivery` | 在上述条件下拦截 `CLLocationManager -requestLocation` 和 `-startUpdatingLocation`，直接向 delegate 回传测试位置 | 用于验证是否可跳过系统定位请求；尚未验证应用全部路径 |
| `device_id_override` | 对 `NSUserDefaults` 读取 `E_DIAN_TONG_DEVICE_ID` 及带账号后缀的同名前缀键时返回配置的旧设备 ID，并保留原值的字符串或 `NSData` 类型 | 实际安装数据中发现带后缀的键与 UTF-8 `NSData` 值；尚未确认登录请求一定从这里读取 |
| `idfv_override` | 用配置的 UUID 替换 `UIDevice -identifierForVendor` | 用于排查另一种设备标识路径，尚未确认应用使用它 |
| `network_log_enabled` | 在面板展示考勤小程序 `/attendapi/` 和 `/attend/` 请求及响应；默认开启 | `kaoqindaka_wx.zip` 内的前端调用 `$mipjs.post/get` 访问这些路径 |

注入后，应用右侧会出现可拖动的“测试”悬浮按钮。点开后可设置 VPN、定位和设备标识开关；点面板标题即可折叠。定位区可输入经纬度，或打开地图轻点选点并确认。打开“虚拟定位检测改写”和“使用指定经纬度”后，坐标改写才生效；再打开“直接返回测试位置”，可测试跳过 Core Location 的系统请求。地图选点使用 MapKit，需有地图数据网络连接，坐标以地图返回值为准。

两个设备标识输入框下方显示“原始”和“返回”值，可点“刷新当前读取值”重新读取。这里显示的是对应系统 API 的返回结果；应用若另用 Keychain、SDK 或服务端数据生成设备指纹，仍需结合登录请求确认。设置保存在应用自己的容器中，开关默认关闭。设备标识开关只有填写非空旧设备 ID 才生效；IDFV 开关只有填写有效 UUID 才生效。不要将真实旧设备 ID 提交到仓库。`settings.example.plist` 仅展示配置格式，不需要手动复制。

面板底部有考勤小程序请求日志。它在加载 `kaoqindaka_wx` 的 WebView 中观察 `$mipjs` 的 `post/get` 请求与 Promise 结果，未能找到该对象时回退观察 `uni.request`。仅保留最近 60 条，每条最多约 2 KB；URL 查询参数不显示，常见令牌和口令字段会隐藏。日志仅保存在当前应用进程内，重启或点“清空日志”后消失。复制日志前仍需检查是否包含业务数据。若请求由非 WebView 的原生网络模块发送、页面结构改变，或应答在日志层仍是密文，面板可能无法显示完整内容。

`kaoqindaka_wx.zip` 原位于 IPA 的 `Payload/App.app/kaoqindaka_wx.zip`，已复制到本地工程目录，并解压为 `kaoqindaka_wx/` 供检查；两者都是应用资源，已加入 `.gitignore`，不会随 tweak 源码推送。包内 `static/locationhandler.js` 在前端根据 `lat`、`lng` 与基准位置计算签到范围；`static/js/index.*.js` 包含 `/attendapi/attend/sign`、`sign_with_note` 等接口路径。签到页面还会将定位回调的 `mock` 或错误码 `111` 记为 `virtual=1`，并随签到请求发送；目前这些 WebView 回调值只供日志观察，尚需在真机核实其原生来源。

## 旧设备 ID 与 IDFV 从哪里来

| 面板字段 | “原始”值的读取方式 | 替换值如何取得 |
| --- | --- | --- |
| 旧设备 ID | 点击“刷新当前读取值”时，从**当前这台设备**的应用 `NSUserDefaults.standardUserDefaults` 读取 `E_DIAN_TONG_DEVICE_ID` 或其带账号后缀的键；实际样本中值为 UTF-8 编码的 `NSData`，面板会解码显示。hook 也记录应用通过 `objectForKey:` 或 `stringForKey:` 读取同一键时的原值 | 在**已获准登录的旧设备**上安装同一测试 tweak，关闭“旧设备 ID 替换”，打开面板读取“原始”值，再手动填入新设备的输入框。若旧设备已无法读取，可从你控制的设备注册服务端或原应用数据中核对该 ID |
| IDFV | 调用**当前这台设备**的 `UIDevice.currentDevice.identifierForVendor`，记录改写前返回的 UUID | 在已获准登录的旧设备上用相同方式读取“原始” IDFV，再手动填入新设备 |

“返回”显示开关和输入值生效后，当前 API 调用返回给应用的值。新设备面板无法凭空获取旧设备的值；旧设备 ID 显示“（空）”只表示当前读取的 `NSUserDefaults` 键没有值，不代表应用没有使用其他存储或服务端设备标识。IDFV 是 iOS 的供应商标识，和应用自定义的 `E_DIAN_TONG_DEVICE_ID` 不是同一字段。即使两项“返回”与输入值一致，也只能说明这些 hook 路径改写成功，不能据此判定服务端设备绑定已被绕过。

已安装数据样本还含有带相同账号后缀的 `E_DIAN_TONG_LOGIN_INFO`，其 JSON 中有 `deviceId` 字段；样本里它与单独保存的设备 ID 相同。当前 tweak 未改写这份登录缓存，测试登录时需检查应用实际使用的字段。

## 构建与测试

在 Actions 手动运行 **Build EDT Probe**，也可以推送受监控的文件触发构建。运行结果包含 `edt-probe-rootless`（可安装的 `.deb`）和 `edt-probe-dylib`（独立 `.dylib` 及配套注入过滤 `.plist`）。只取得 dylib 时仍需把配套 plist 放在注入器要求的位置；直接安装 rootless 越狱测试设备时使用 `.deb`。工作流使用 macOS runner、自带的 iPhoneOS SDK 和 Theos 源码，并运行 `make clean package FINALPACKAGE=1`。

注入后直接在悬浮面板中逐项配置。保存后重新发起登录或定位测试；定位 SDK 若已经初始化并缓存了检测状态，可能需要重启应用再测。通过系统日志搜索 `[EDTProbe]`，确认 tweak 已加载且目标方法被调用。

建议每次只打开一个开关，分别记录：登录结果、VPN 状态、定位结果、服务端返回的错误码。VPN 在线和离线两档都需要分别测；此应用包含企业 VPN SDK，不能从方法名推断哪档会解除限制。

## 结果边界与修复方向

这份工程是待验证的本地绕过 PoC，当前没有证明新终端登录、VPN 或虚拟定位限制已被绕过。特别是 `NRXinTongLoginVC -updateUserDevice` 和 `API_updateUserDevice` 暗示有服务端设备注册流程；若服务端独立绑定设备或验证位置与网络，单改客户端返回值不会通过。

防护上，设备注册与变更应由服务端决定并要求额外验证；敏感请求应绑定短时挑战、账号、设备注册状态以及服务端可验证的信号。定位真实性与 VPN 策略不能只依赖一个客户端布尔值。测试时应同时检查服务端是否拒绝篡改后的请求。
