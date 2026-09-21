# AutoProxy

[![CI](https://github.com/ikvarxt/autoproxy/actions/workflows/ci.yml/badge.svg)](https://github.com/ikvarxt/autoproxy/actions/workflows/ci.yml)

一个 macOS 菜单栏小工具，管 Android 手机走 USB 线的代理链路。

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
| 状态行 | 代理中 / 就绪 / 已断网 / 未授权 / 无设备，图标用颜色+形状双编码 |
| 开启代理 | 先建隧道后设代理 —— 顺序反了手机会有一瞬间断网。首次开启会先提示后果，勾了「不再提示」就不再拦 |
| 停止代理 | 先清代理后拆隧道 —— 同理 |
| 清理手机代理 | 链路已断（隧道没了但代理还在）时出现 |
| 查看问题与解决方案… | 设备离场且代理未清理时出现，给出三条路径 |
| 安装代理证书… | 选本地 `.crt` → 推到 `/sdcard/Download/` → 拉起系统证书安装页 |
| 代理端口 | 默认 9000，可改；能一键读取 Reqable 的实际监听端口 |
| 重新插上时自动接回 | 默认开，可关 |
| 每天检查更新 | 默认开。查到新版本后台下好，等你不在抓包时自己换上去并重启 |
| 更新到 x.y.z | 包已就绪但还在抓包时出现，点它立刻装 |
| 设备选择 | 插了多台时出现，选中哪台管哪台，其余自动清理 |

设备插拔靠 `adb host:track-devices` 事件驱动，不靠轮询；定时器只用来刷新链路细节
（代理软件退出、隧道被别的进程拆掉）。

### 多台手机同时插着

**任何时刻只有一台手机身上有我们的代理。** 插了多台时菜单顶部会列出所有设备，选中的那台才是
被管理的对象；选中项记在本地，拔插后仍是它。

切换时代理状态跟着人走：新的那台立刻开起来，旧的那台清掉代理和隧道。新设备没授权、或本机端口
没人监听，就只切选中项不开代理，并弹窗说明原因。**只清指向 `127.0.0.1:<本机端口>` 的代理**，
指向别处的是别人设的，不碰。

### 自动重连

线一拔，`adb reverse` 建的隧道就没了，但手机上的 `http_proxy` 是持久设置，还原封不动指着
`127.0.0.1:9000`。所以插回来的那一刻手机其实是断网的，隧道补上就好。这件事工具自己做。

两种断法，各自对应一个动作：

| 实测到的情况 | 动作 |
|---|---|
| 代理还在、隧道没了（拔插线、adb server 重启、别的工具清了 reverse） | 补隧道 |
| 代理被清掉了，但记录说这台手机上次在抓 | 隧道和代理一起重建 |
| 代理指向别的地址 | 不管 —— 那是别人设的 |

**前提是本机端口确实有人监听。** 代理软件没开就重连，等于把手机的 HTTP 流量导向一个不存在的
端口，比不重连糟得多 —— 用户看到的是手机好好的却打不开任何网页，还会以为是手机坏了。
同一台设备 20 秒内只自动动手一次，链路真修不好时它退化成低频重试，而不是每 3 秒对手机发一轮命令。

### 证书安装能到哪一步

推文件和拉起安装页能自动做，**最后三下必须人点**：CA 证书 → 选文件 → 确定。
这不是没做完，是 Android 的硬性边界：由 adb 发起的 CA 安装会被 `CertInstaller` 直接拒绝
（「必须在设置中安装来自 Shell 的此证书」），只有用户在设置里亲自确认才作数。

### 自动更新

每天问一次 GitHub 的 `releases/latest`，版本号比手上这个新就把 zip 下回来，解压、核对包里的
bundle id 和版本号，**然后等到不在抓包的时候才换上去** —— 换一次要重启进程，而退出会顺手清掉
手机上的代理，正抓着包干这事等于掐断链路。等不及就点菜单里那一项。

替换交给一段外部脚本：进程活着的时候动不了自己的 bundle。脚本等主进程退出（最多 60 秒，
PID 有可能被复用，不能无限等），再走「旧的挪走 → 新的就位 → 删旧的」三步，任何一步失败都
退回旧版本。

自己下载的包不带 `com.apple.quarantine` —— 那是浏览器下载才打的标记，所以这条路径上不需要
再手动去隔离属性。

**局限**：产物是 ad-hoc 签名的，验不了发布者身份。这条链路的信任落在 HTTPS 和 api.github.com 上，
本地能做的只是核对 bundle id 与版本号对不对得上。

## 构建

需要 Xcode 命令行工具与 Swift 5.9+。

```bash
make test      # 单元测试
make app       # 产出 build/AutoProxy.app
make run       # 构建并启动
make deploy    # 一把梭：测试 → 构建 → 装进 /Applications → 启动
make install   # 只拷贝，不跑测试、不重启
```

`make deploy` 等价于 `scripts/deploy.sh`，脚本还认这几个参数：

| 参数 | 作用 |
|---|---|
| `--login` | 顺便设为登录启动（写 `~/Library/LaunchAgents/me.ikvarxt.autoproxy.plist`） |
| `--no-login` | 取消登录启动 |
| `--skip-tests` | 跳过单元测试 |

部署时是 `pkill` 掉旧实例而不是让它正常退出 —— 正常退出会顺手清掉手机上的代理，
等于每次部署都把进行中的代理给停了。杀掉后隧道和代理原样留着，新实例起来接着管。

## 发布

版本号只有一个出处：`Resources/Info.plist` 里的 `CFBundleShortVersionString`，语义化版本。

发版就是改这个数字然后推 main —— 流水线读到一个还没打过 tag 的版本号就自动建 tag、
构建、发 Release；版本号没动就什么也不做。

```bash
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 0.2.0' Resources/Info.plist
git commit -am 'chore: 0.2.0' && git push
```

`CFBundleVersion` 不用管，构建时会被流水线的 run number 覆盖。

下载下来的包是 ad-hoc 签名的，Gatekeeper 会拦，装完要去掉隔离属性：

```bash
xattr -dr com.apple.quarantine /Applications/AutoProxy.app
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
- 代理软件正在监听配置的端口（没监听时状态行会提示）
