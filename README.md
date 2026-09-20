# AutoProxy

一个 macOS 菜单栏小工具，管 Android 手机走 USB 线的抓包链路。

把手机的 HTTP 流量导到 Mac 上的 Reqable / Charles / mitmproxy，全程不经过 Wi-Fi：

```
adb reverse tcp:9000 tcp:9000            # USB 隧道，transport 是 UsbFfs
adb shell settings put global http_proxy 127.0.0.1:9000   # 全局代理，不绑 SSID
```

这两条命令手敲也能跑。这个工具存在的理由是第三件事：**手机离场后的收尾**。

## 为什么需要它

`settings put global http_proxy` 是全局设置，重启不丢，而且 Android 的设置界面里**没有任何入口**能改它。
一旦拔线时忘了清理，手机的表现是：信号满格、Wi-Fi 已连接，但所有 App 都打不开网页 —— 流量全发向一个
已经不存在的 USB 隧道。人不在电脑边时，除了装 Termux 手敲 `settings put global http_proxy :0`，
基本没救。

USB 线一拔，adb 连接同时断开，Mac 再也问不到手机的状态。所以本工具在每次探测后把
「这台手机离场前代理是开是关」落盘，设备不在场时据此给出警示和解决方案；设备重新接入时立即以实测为准覆盖记录。

## 功能

| 菜单项 | 行为 |
|---|---|
| 状态行 | 抓包中 / 就绪 / 已断网 / 未授权 / 无设备，图标用颜色+形状双编码 |
| 开启抓包 | 先建隧道后设代理 —— 顺序反了手机会有一瞬间断网 |
| 停止抓包 | 先清代理后拆隧道 —— 同理 |
| 清理手机代理 | 链路已断（隧道没了但代理还在）时出现 |
| 查看问题与解决方案… | 设备离场且代理未清理时出现，给出三条路径 |
| 安装抓包证书… | 选本地 `.crt` → 推到 `/sdcard/Download/` → 拉起系统证书安装页 |
| 代理端口 | 默认 9000，可改；能一键读取 Reqable 的实际监听端口 |

设备插拔靠 `adb host:track-devices` 事件驱动，不靠轮询；定时器只用来刷新链路细节
（代理软件退出、隧道被别的进程拆掉）。

### 证书安装能到哪一步

推文件和拉起安装页能自动做，**最后三下必须人点**：CA 证书 → 选文件 → 确定。
这不是没做完，是 Android 的硬性边界：由 adb 发起的 CA 安装会被 `CertInstaller` 直接拒绝
（「必须在设置中安装来自 Shell 的此证书」），只有用户在设置里亲自确认才作数。

## 构建

需要 Xcode 命令行工具与 Swift 5.9+。

```bash
make test      # 单元测试
make app       # 产出 build/AutoProxy.app
make run       # 构建并启动
make install   # 装到 /Applications
```

改图标后想肉眼比对七个状态：

```bash
ICON_SHEET_DIR=/tmp swift test --filter IconSheet && open /tmp/icons.png
```

签名身份默认 ad-hoc。要用自己的证书，建一个不入库的 `local.mk`：

```make
SIGN_IDENTITY := Developer ID Application: Your Name (TEAMID)
```

## 运行前提

- `adb` 在 PATH 里，或位于常见的 Android SDK 路径
- 手机已开启 USB 调试并授权过这台 Mac
- 抓包软件正在监听配置的端口（没监听时状态行会提示）
