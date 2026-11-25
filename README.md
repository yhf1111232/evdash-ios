# EvDash (iOS)

GEKOO / 智科控制器 蓝牙调试工具 —— iOS 版。

蓝牙协议逆向自安卓版 **GEKOO 1.0.5**（包名 `uni.UNIEF9C31D`，开发者：苏州智骐驱动科技有限公司）。

---

## 功能（首版）

- 搜索 GEKOO 控制器（`GEKOO-BLE` / `ZX-D30` 前缀）
- 手动选择设备连接；只搜到一台时 3 秒自动连
- 读取控制器全部参数：**71 项 / 12 组**，中文名 + 单位 + 枚举文案
- 实时数据解析（电压 / 电流 / 转速 / 温度 / 故障码 / 硬件型号）

## 尚未实现

仪表盘界面、参数写入、恢复出厂、电机自学习、固件升级

---

## 目录结构

```
EvDash/
├── EvDash/
│   ├── EvDashApp.swift      应用入口
│   ├── ContentView.swift    界面：设备页 + 参数页
│   ├── BleManager.swift     CoreBluetooth 连接管理 + 实时数据解析
│   ├── FrameDecoder.swift   帧解码（跨包重组 + 回显过滤）★纯 Foundation
│   ├── ParamCodec.swift     参数编解码 ★纯 Foundation
│   ├── Params.swift         参数表（71 项，自动生成）★纯 Foundation
│   └── Info.plist           含蓝牙权限说明
├── Tests/
│   ├── main.swift           独立可执行测试（Windows 上用）
│   └── ProtocolTests.swift  XCTest 测试
├── project.yml              XcodeGen 工程定义
├── Package.swift            SwiftPM（仅用于跑逻辑测试）
└── .github/workflows/
    └── build-ipa.yml        云端编译出未签名 .ipa
```

★ 标记的三个文件不依赖 Apple 框架，可以在 Windows / Linux 上编译测试。

---

## 怎么装到 iPhone

见 **[INSTALL-GUIDE.md](INSTALL-GUIDE.md)** —— 全程在 Windows 上操作，不需要 Mac。

---

## 本地开发

### macOS（完整构建）

```bash
brew install xcodegen
xcodegen generate
open EvDash.xcodeproj
```

或直接跑测试：

```bash
swift test
```

### Windows / Linux（只跑协议逻辑测试）

```bash
swift test
```

Windows 上还可以用独立可执行版（不依赖 XCTest）：

```powershell
# 需要 Swift for Windows + Windows SDK 头文件，见 scripts/
.\ios_test.ps1
```

---

## 协议摘要

**BLE**

| 项 | 值 |
|---|---|
| Service | `0000FFE0-0000-1000-8000-00805F9B34FB` |
| 写 / 通知 | `0000FFE1-...` |
| bootloader 通道 | `0000FFE2-...` |
| 设备名前缀 | `GEKOO-BLE` / `ZX-D30` |
| 握手 | 首次写入前往 FFE2 发 `01 02` |

**帧格式**：`AA | CMD | 数据 | 校验`

| 方向 | 帧 | 说明 |
|---|---|---|
| 手机→控制器 | `AA 11 00 01` | 读全部参数 |
| 控制器→手机 | 131 字节 | `AA 11 00` + 63×word LE + 校验字 |
| 手机→控制器 | `AA 13 FF 01 AA 13 00 01` | 实时轮询（100 ms） |
| 控制器→手机 | 67 字节 | `AA 13 00` + 31×word LE + 校验字 |
| 手机→控制器 | `AA 21 00 01` | 进入写参数模式 |
| 手机→控制器 | `AA 12 00` + 126 字节 + 校验 | 写参数数据 |
| 手机→控制器 | `AA 21 01 01` | 恢复出厂 |
| 手机→控制器 | `AA 17 00 01` | 读蓝牙密码 |
| 手机→控制器 | `AA 14 06 00 00 00 00 00 00` | 电机自学习 |

**校验**：帧内所有 16 位小端字之和 == `0xFFFF`

**已知坑**：控制器会把轮询命令 `AA 13 00 01` 原样回显（4 字节）。原厂按 `b[2]==0 && b[3]==1` 直接丢 4 字节，但真帧 `AA 13 00 <word0lo> <word0hi>` 在 word0 低字节为 1 时同样符合该模式，会被误吞。本实现攒够 67 字节后用校验区分。

---

## 测试

38 项协议测试，覆盖：

- 131B 参数帧 / 67B 实时帧的校验与字段解码
- BLE 20 字节分包重组
- 回显帧 vs 歧义真帧
- 垃圾数据鲁棒性
- 写参数帧组帧
- 参数编解码往返（uint / bool / list / float / 位域）
- 参数表完整性（71 项、12 组、索引范围）

```
===== 38 passed, 0 failed =====
```
