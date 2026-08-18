# DeepSeek Harness 一键启动器 · 使用说明

## 先说几句

这玩意儿是给 DeepSeek Harness 配的一键启动器：双击一下，环境帮你检查好，服务在后台悄悄启动，浏览器自己打开，你直接开用就行。

> 声明：这是个人做的第三方小工具，跟 DeepSeek 官方没有半点关系，纯粹为了方便大家。上游是 <https://github.com/deepseek-ai/deepseek-harness>（MIT 协议）。

不用装任何软件，全靠 Windows 自带的 PowerShell。电脑上要是连 Node.js 和 pnpm 都没有，它也会自己下载到 `data\tools\` 里，绝不动你的系统环境。

## 第一次用，四步走

1. 把 DeepSeek Harness 的源码放好，放哪都行（比如 `C:\deepseek-harness`）。启动器会自动找，找不到就弹个框让你自己选。
2. 双击 `src\dsh-launcher.bat`（或桌面上的快捷方式）。
3. 头一回会问端口：直接点"确认使用"用默认的就行，想换也能自己选，最好勾上"记住此配置"，下回就不用问了。
4. 第一次启动要等 40~50 秒（有进度条，不是卡死了），好了自动开浏览器。

打这儿往后，每次双击就开，不用再等。

## 平时怎么用

| 功能 | 操作 |
| --- | --- |
| 启动 | 双击启动器。服务本来就在跑的话，直接开浏览器，绝不重复起。 |
| 停止 | 按 `Ctrl+Alt+Shift+F12`，弹个确认框；嫌烦就勾"不再提示"。 |
| 强行停止 | 按 `Ctrl+Alt+P` 打开端口窗口，点"硬关闭服务"。 |
| 换端口 | `Ctrl+Alt+P`，选个端口确认，重启服务后生效。 |
| 查更新 | 每次启动后台自动查，有新版本弹 2 秒提示，点"更新并重启"。 |
| 开机预热 | 想让开机登录后服务就绪、打开即用，就在 `Ctrl+Alt+P` 里勾上"开机预热服务"。 |

快捷键就两个：`Ctrl+Alt+Shift+F12` 停服务，`Ctrl+Alt+P` 改端口。用不顺手想换，改法写在底下。（设置的复杂只是为了防止热键冲突）

## 常见问题

**问：双击了，浏览器没开，还提示启动失败？**
答：先翻 `data\logs\harness-launcher.log` 和 `harness-web.err.log`。多半是网络不通（自动装 Node/pnpm 没装上）或源码没放好。（也有可能是服务没拉起来，等一会再双击就好了）

**问：说"端口被占用"？**
答：占用中的端口会显示橙色"已使用中（可直接使用）"。占着端口的就是咱们自己的服务的话，直接确认就行，启动器认得它。想换就换个空闲的。

**问：按了停止，浏览器居然还能开？**
答：看一眼 `data\logs\harness-hotkey.log` 里有没有 `POST-STOP CHECK: clean`。还不行就上硬杀：`Ctrl+Alt+P` -> 硬关闭服务。（快捷键是软杀，只有 UI 的是硬杀）

**问：快捷键没反应？**
答：远程桌面断开、无头环境下快捷键和窗口都用不了，这是 Windows 的限制，不是坏了。另外它跟别的软件抢键时会自动换备用组合。（快捷键弹出会比较慢，本人就那么点能力了，见谅）

**问：更新失败会不会把服务搞坏？**
答：不会。更新失败会自动退回上一版接着用，放心。

**问：日志会不会越来越大占地方？**
答：超过 7 天的自动删，单个超 5MB 自动轮转，不用管。

## 想换快捷键？

打开 `src\Start-HotkeyListener.ps1`：

- 停止键：改 `$candidates` 列表（Mod 是修饰键，Vk 是按键码；第一个能注册成功的组合生效）。按键码表：<https://learn.microsoft.com/en-us/windows/win32/inputdev/virtual-key-codes>
- 改端口键（默认 `Ctrl+Alt+P`）：改 `$portConfigMod` 和 `$portConfigVk`（ALT=0x1，CTRL=0x2，SHIFT=0x4，MOD_NOREPEAT=0x4000）。

## 卸载

1. 取消开机预热（开过的话）：`Ctrl+Alt+P` 里取消勾选。
2. 停服务：`Ctrl+Alt+Shift+F12`，或端口窗口里"硬关闭服务"。
3. 把整个文件夹删了就行。日志和配置都在 `data\` 里，跟着一起没了；你的 Harness 源码一点不受影响。

有问题就带上 `data\logs\` 里的日志来提 Issue，最管用。

---

## English quick start

A one-click launcher for DeepSeek Harness on Windows: double-click to check the environment, start the hidden service, and open the browser.

Unofficial, third-party tool (not affiliated with DeepSeek). Upstream: <https://github.com/deepseek-ai/deepseek-harness> (MIT). Nothing to install - Node.js / pnpm are auto-downloaded into `data\tools\` if missing; system installs are never touched.

First use: put the harness source somewhere (e.g. `C:\deepseek-harness`), double-click `src\dsh-launcher.bat`, pick a port (the default is fine, tick "remember"), wait 40-50 s for the first cold start - the browser opens by itself.

Daily use:

- Start: double-click (opens the browser if it is already running).
- Soft stop: `Ctrl+Alt+Shift+F12` (popup; tick "don't ask again" to mute).
- Hard stop: `Ctrl+Alt+P` -> "Hard Stop".
- Change port: `Ctrl+Alt+P` -> pick a port -> OK (after restart).
- Update: checked automatically; a 2-second notice offers Update & Restart.
- Pre-warm (optional): `Ctrl+Alt+P` -> tick "pre-warm at login".
- The stop-hotkey candidate list looks complicated, but it only exists to avoid conflicts with other software.
- The hotkey is a SOFT stop; only the port dialog's "Hard Stop" button is a hard kill.

Troubleshooting: logs live in `data\logs\` (`harness-launcher.log`, `harness-web.err.log`, `harness-hotkey.log`). Failed updates roll back automatically. Logs auto-rotate (7 days / 5 MB). Hotkeys need an interactive desktop session. If the browser does not open, it can also just mean the service is still starting - wait a moment and double-click again. The hotkey confirmation popup can be a little slow - that is the best I could do, apologies.
