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
| `device_id_override` | 改写登录和设备更新请求调用的 `NSString +getFCUUID`，并兼容 `NSUserDefaults` 读取 `E_DIAN_TONG_DEVICE_ID` 及带账号后缀的键 | `NRNoTrustTool -loginNotrust:andPwd:handleLoginBlock:`、`NRXinTongLoginVC -updateUserDevice` 均调用 `getFCUUID` |
| `idfv_override` | 用配置的 UUID 替换 `UIDevice -identifierForVendor` | `getFCUUID` 优先取 `FCUUID uuidForDevice`；仅改 IDFV 通常无法改变登录用的标识 |
| `network_log_enabled` | 在面板展示考勤小程序 `/attendapi/` 和 `/attend/` 请求及响应；默认开启 | `kaoqindaka_wx.zip` 内的前端调用 `$mipjs.post/get` 访问这些路径 |

注入后，应用右侧会出现可拖动的“测试”悬浮按钮。点开后可设置 VPN、定位和设备标识开关；点面板标题即可折叠。定位区可输入经纬度，或打开地图轻点选点并确认。打开“虚拟定位检测改写”和“使用指定经纬度”后，坐标改写才生效；再打开“直接返回测试位置”，可测试跳过 Core Location 的系统请求。地图选点使用 MapKit，需有地图数据网络连接，坐标以地图返回值为准。

两个设备标识输入框下方显示“原始”和“返回”值，可点“刷新当前读取值”重新读取。旧设备 ID 栏现在优先显示登录流程 `getFCUUID` 的实际值；其格式为 `UID_` 加去掉连字符的 UUID。设置保存在应用自己的容器中，开关默认关闭。设备标识开关只有填写非空旧设备 ID 才生效；IDFV 开关只有填写有效 UUID 才生效。不要将真实旧设备 ID 提交到仓库。`settings.example.plist` 仅展示配置格式，不需要手动复制。

面板底部有考勤小程序请求日志。它在加载 `kaoqindaka_wx` 的 WebView 中观察 `$mipjs` 的 `post/get` 请求与 Promise 结果，未能找到该对象时回退观察 `uni.request`。仅保留最近 60 条，每条最多约 2 KB；URL 查询参数不显示，常见令牌和口令字段会隐藏。日志仅保存在当前应用进程内，重启或点“清空日志”后消失。复制日志前仍需检查是否包含业务数据。若请求由非 WebView 的原生网络模块发送、页面结构改变，或应答在日志层仍是密文，面板可能无法显示完整内容。

`kaoqindaka_wx.zip` 原位于 IPA 的 `Payload/App.app/kaoqindaka_wx.zip`，已复制到本地工程目录，并解压为 `kaoqindaka_wx/` 供检查；两者都是应用资源，已加入 `.gitignore`，不会随 tweak 源码推送。包内 `static/locationhandler.js` 在前端根据 `lat`、`lng` 与基准位置计算签到范围；`static/js/index.*.js` 包含 `/attendapi/attend/sign`、`sign_with_note` 等接口路径。签到页面还会将定位回调的 `mock` 或错误码 `111` 记为 `virtual=1`，并随签到请求发送；目前这些 WebView 回调值只供日志观察，尚需在真机核实其原生来源。

## 旧设备 ID 与 IDFV 从哪里来

| 面板字段 | “原始”值的读取方式 | 替换值如何取得 |
| --- | --- | --- |
| 旧设备 ID | 点击“刷新当前读取值”时调用**当前这台设备**的 `NSString +getFCUUID`，显示登录请求实际采用的值；该方法先试 `FCUUID uuidForDevice`，再依次尝试 vendor、installation、session UUID 与随机 UUID，然后加 `UID_` 并去掉连字符。读取 `NSUserDefaults` 的旧键仍被兼容，但不作为登录值的主要展示来源 | 在**已获准登录的旧设备**上安装同一测试 tweak，关闭“旧设备 ID 替换”，打开面板读取“登录原始”值，再填入新设备。若旧设备已无法读取，可从你控制的设备注册服务端或原应用数据中核对该 ID |
| IDFV | 调用**当前这台设备**的 `UIDevice.currentDevice.identifierForVendor`，记录改写前返回的 UUID | 在已获准登录的旧设备上用相同方式读取“原始” IDFV，再手动填入新设备 |

“返回”显示开关和输入值生效后，当前 API 调用返回给应用的值。新设备面板无法凭空获取旧设备的值。IDFV 是 iOS 的供应商标识，和 `getFCUUID` 的最终字符串不是同一字段。即使“登录返回”与输入值一致，也只能说明客户端调用点被改写，不能据此判定服务端设备绑定已被绕过。

已安装数据样本还含有带相同账号后缀的 `E_DIAN_TONG_LOGIN_INFO`，其 JSON 中有 `deviceId` 字段；样本里它与单独保存的设备 ID 相同。当前 tweak 未改写这份登录缓存，测试登录时需检查应用实际使用的字段。

## 新终端禁止登录的静态判断链

登录按钮先调用 `NRNoTrustTool -loginNotrust:andPwd:handleLoginBlock:`。它构造传给 `EnSDK_loginWithUsername:password:userType:extra:loginBlock:` 的 `deviceInfo`，包括 `deviceId`（`NSString +getFCUUID`）、`deviceModel`、`platformType`、`osVersion`、用户名、版本号等。`NRNoTrustTool` 从登录错误响应中解析 `code`、`messages`，遇到 SDK 的二次认证码时转为客户端 `code=2`；登录页依据结果显示消息或进入验证码流程。成功后，登录页把同一个 `getFCUUID` 值写入 `E_DIAN_TONG_LOGIN_INFO.deviceId`。面容验证成功的分支随后调用 `/manage/user/api/user/mobile/updateDevice`，提交 `userUuid`、`deviceId`、设备型号、平台和系统版本。

IPA 中未找到“新终端设备，禁止登录”的固定文案，也未找到把旧 ID 与当前 ID 在客户端直接比较并拒绝登录的分支。因此该提示很可能来自登录服务返回的 `messages`，但具体服务端规则、错误码和是否允许更换设备需要用真机请求或服务端日志确认。`updateDevice` 发生在后续流程，不能仅凭方法名认定它负责首次登录拦截。

## 构建与测试

在 Actions 手动运行 **Build EDT Probe**，也可以推送受监控的文件触发构建。运行结果包含 `edt-probe-rootless`（可安装的 `.deb`）和 `edt-probe-dylib`（独立 `.dylib` 及配套注入过滤 `.plist`）。只取得 dylib 时仍需把配套 plist 放在注入器要求的位置；直接安装 rootless 越狱测试设备时使用 `.deb`。工作流使用 macOS runner、自带的 iPhoneOS SDK 和 Theos 源码，并运行 `make clean package FINALPACKAGE=1`。

注入后直接在悬浮面板中逐项配置。保存后重新发起登录或定位测试；定位 SDK 若已经初始化并缓存了检测状态，可能需要重启应用再测。通过系统日志搜索 `[EDTProbe]`，确认 tweak 已加载且目标方法被调用。

建议每次只打开一个开关，分别记录：登录结果、VPN 状态、定位结果、服务端返回的错误码。VPN 在线和离线两档都需要分别测；此应用包含企业 VPN SDK，不能从方法名推断哪档会解除限制。

## 结果边界与修复方向

这份工程是待验证的本地绕过 PoC，当前没有证明新终端登录、VPN 或虚拟定位限制已被绕过。特别是 `NRXinTongLoginVC -updateUserDevice` 和 `API_updateUserDevice` 暗示有服务端设备注册流程；若服务端独立绑定设备或验证位置与网络，单改客户端返回值不会通过。

防护上，设备注册与变更应由服务端决定并要求额外验证；敏感请求应绑定短时挑战、账号、设备注册状态以及服务端可验证的信号。定位真实性与 VPN 策略不能只依赖一个客户端布尔值。测试时应同时检查服务端是否拒绝篡改后的请求。
