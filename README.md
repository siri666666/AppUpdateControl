# AppUpdateControl（应用更新控制）

iOS 15–16 越狱插件：通过轻量 Hook 系统守护进程 `appstored`，为每个 App Store 应用提供 **3 档独立更新控制**，弥补苹果系统只有全局自动更新开关的短板。

## 核心功能

- **三档单应用更新策略**：
  - **自动更新**：正常走系统后台自动更新。
  - **仅手动更新**：阻止 `appstored` 后台自动静默升级，但在 App Store 更新页中完整保留更新提示与手动更新按钮。
  - **禁用更新**：同时拦截后台自动更新、全部更新与手动点击更新，并从 App Store 更新列表隐藏（适合锁死旧版 App）。
- **全局默认策略可切**：支持「默认自动 + 个别手动/禁用」或「默认仅手动 + 个别自动/禁用」。
- **仅注入 `appstored`**：零 SpringBoard 注入、零第三方 App 注入、改完规则实时同步生效（无需注销桌面）。
- **原生双架构支持**：同时编译 `RootHide (iphoneos-arm64e)` 与 `Rootless (iphoneos-arm64)` `.deb` 包。

## 实现原理

通过逆向 `appstored`：
- Hook `PerformUpdatesTask` 与 `AppUpdateMemoryEntity`，在后台自动更新任务（`isBackgroundRequest == YES`）中利用系统原生的限制跳过分支过滤「仅手动」与「禁用」应用。
- Hook `PurchaseManager` 的 `processPurchases:requestToken:withReplyHandler:`，拦截禁用应用的手动更新与仅手动应用的后台更新。
- Hook `UpdatesService` / `SoftwareUpdateListener` 的更新列表与「全部更新」接口，隐藏并跳过禁用应用。

## 使用方法

1. 从 [Releases](https://github.com/siri666666/AppUpdateControl/releases) 下载对应越狱架构的 `.deb` 并安装。
2. 在 **系统设置 → App Store** 中开启「App 更新」。
3. 打开 **设置 → 应用更新控制**，选好默认策略并按需配置单个 App。

## 开源协议

基于 [MIT License](LICENSE) 开源；依赖 [opa334/AltList](https://github.com/opa334/AltList)。
