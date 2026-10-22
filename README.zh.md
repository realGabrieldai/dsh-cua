# dsh-cua

**给 DSH 用的原生 macOS computer use —— 工具面和 Codex 内置 CUA 一致，并且保证绝不抢你的屏幕。**

`dsh-cua` 让 agent 能读原生 App 的辅助功能（Accessibility）树、点元素、输入文字、按键、
滚动和拖拽，同时你可以照常干自己的活。它由三部分组成：Swift 命令行、MCP stdio 服务器、
以及一个 DSH skill。

这个项目是被一次具体的失败逼出来的：最初为了查一个论文数据库，我们用 CDP 驱动一个真实
Chrome 窗口，结果每一步 Chrome 都跳到最前面，把用户从手头的事情里反复拽出来。截图循环类
的 agent 和浏览器脚本天生就有这个问题。`dsh-cua` 反过来设计：**「不抢焦点」是核心功能**，
一旦违反就直接报错，而不是给个警告了事。

## 和别家有什么不同

| | Codex 内置 CUA | 截图循环类 agent | **dsh-cua** |
|---|---|---|---|
| 实现方式 | 自带 `SkyComputerUseClient` 助手（Accessibility + ScreenCaptureKit + 合成输入），经 `codex app-server` 暴露 | 周期性全屏截图 + 坐标点击 | 优先走 Accessibility API，兜底用 `CGEventPostToPid` |
| 需要装 Codex | 需要 | 不需要 | **不需要** |
| 截图范围 | 单窗口 | 整块屏幕 | **只截单个窗口，而且只在你要的时候截** |
| 会不会动你的鼠标 | 不会 | 通常会 | **绝不** |
| 会不会抢焦点 | 不会 | 经常 | **绝不 —— 每次调用都校验，抢了就退出码 7** |
| 接入方式 | Codex 内部 | 五花八门 | **CLI + MCP + DSH skill** |

值得一读的同类项目：[`codex-cua-mcp`](https://github.com/parassharmaa/codex-cua-mcp)
把 Codex 的 CUA 工具重新用 MCP 暴露出来；[`axuse`](https://github.com/ctoldigital/axuse)
走的是基于 CDP 的 accessibility-first 路线；[`arc-cua`](https://github.com/shhivv/arc-cua)
是面向 computer-use agent 的快速 macOS 动作层。

## 安装

```bash
git clone <本仓库> && cd dsh-cua
swift build -c release          # 需要 macOS 14+ 和 Swift 6 工具链
./.build/release/dsh-cua doctor --json
bash scripts/install-skill.sh   # 装 DSH skill
```

然后注册 MCP 服务器（见 [mcp/README.md](mcp/README.md)），或者直接调命令行。

## 权限（先看这段）

macOS 不允许任何东西在没被授权的情况下驱动 App 或截窗口，而且授权是绑在**那个二进制文件**
上的，不是绑在你的终端上：

| 权限 | 用来干什么 | 系统设置里的位置 |
|---|---|---|
| **辅助功能** | 读 AX 树、按元素、发送输入 | 隐私与安全性 → **辅助功能** |
| **屏幕录制** | 只有 `get-app-state --screenshot` 需要 | 隐私与安全性 → **屏幕与系统音频录制** |

自己编出来的二进制没有签名，所以要手动点 `+` 把它加进去。`dsh-cua doctor` 会打印出该加哪个
路径，以及当前两项权限到底有没有给。两个坑：移动或重新编译二进制可能导致授权失效（要加最终
路径，清空重建后要重新加）；没有辅助功能权限时几乎所有命令都会返回 `PERMISSION_DENIED` ——
这个错误重试没用，它的意思是「去授权，然后再来」。

## 用法

每条命令都输出一个 JSON 对象。加 `--json` 输出紧凑单行。

```bash
dsh-cua doctor --json
dsh-cua list-apps --json
dsh-cua list-windows --app Safari --json
dsh-cua get-app-state --app Safari --json                    # 不截图，很快
dsh-cua get-app-state --app Safari --screenshot /tmp/s.png --json
dsh-cua click --app Safari --element e42 --json              # 推荐用法
dsh-cua click --app Safari --x 812 --y 460 --json            # 也会先做命中测试
dsh-cua type-text --app Notes --element e7 --text "你好" --json
dsh-cua press-key --app Safari --key return --json
dsh-cua scroll --app Safari --dx 0 --dy -600 --json
dsh-cua drag --app Finder --from "100,100" --to "400,400" --json
dsh-cua selftest --json
```

输出形状示例（真实数值会不同）：

```json
{"ok":true,
 "app":{"name":"Safari","bundleId":"com.apple.Safari","pid":501},
 "windows":[{"id":4211,"title":"Apple","focused":true,"bounds":{"x":0,"y":0,"w":1440,"h":900}}],
 "tree":[{"ref":"e1","role":"AXWindow","title":"Apple","enabled":true,
          "frame":{"x":0,"y":0,"w":1440,"h":900},"actions":["AXRaise"],"children":[]}],
 "stats":{"nodes":312,"truncated":false,"maxDepth":12},
 "screenshot":null,
 "frontmostApp":{"bundleId":"com.apple.Safari","pid":501,"unchanged":true}}
```

`<target>` 可以写 bundle id（`com.apple.Safari`）、`pid:501`，或者 App 名字。中文系统里显示名
可能是中文，解析器同时会匹配 bundle 的文件名，所以 `--app Finder` 能找到「访达」，而不会
匹配到某个名字里带 Finder 的扩展。

## 「不抢焦点」这条保证

每条命令在做任何事之前和之后都会记录当前最前面的 App。如果最前面的 App 变了，命令会报
`FOCUS_CHANGED` 并以退出码 **7** 结束 —— 这被当作本工具的 bug，而不是可以忽略的警告。

具体做法：

- **输入**走 `CGEvent.postToPid`，事件直接进目标进程的事件队列；从不使用全局 HID tap，
  也从不调用 `CGWarpMouseCursorPosition`。
- **点击**先用 `AXUIElementCopyElementAtPosition` 把坐标还原成真实元素，能 `AXPress` 就
  直接按，而不是把点击盲撒到坐标上。
- **输入文字**在元素 `AXValue` 可写时直接写值 —— 一个按键都不发。
- **截图**通过 `SCContentFilter(desktopIndependentWindow:)` 只截单个窗口；代码里根本没有
  全屏截图这条路径。
- 输入路径里不会出现 `activate`、`activateIgnoringOtherApps`、`open -a`。

你可以自己验证：在别的 App 处于最前面时执行 `dsh-cua get-app-state --app Finder --json`，
确认 `frontmostApp.unchanged` 是 `true`，并且最前面的 App 没有变。

## 安全

- 终端类和安全类 App 直接拉黑：`Terminal`、`iTerm2`、`Warp`、`WezTerm`、`kitty`、`Hyper`、
  `SecurityAgent`、`系统设置`、`钥匙串访问`。命中黑名单返回 `UNSUPPORTED`。
  `DSH_CUA_ALLOW_BLOCKED=1` 可以覆盖，但只在用户明确同意时用。
- `AXSecureTextField` 会被拒绝，不会往密码框里打字。
- `DSH_CUA_DRY_RUN=1` 只解析并报告计划，不执行任何输入。
- `dsh-cua selftest` 覆盖黑名单、密码框拒绝、JSON 信封形状，以及全部错误码/退出码映射。

## 开发

```bash
make build        # swift build -c release
make test         # dsh-cua selftest --json（73 条断言）
make mcp-test     # node mcp/test-server.mjs（31 项协议检查）
make lint
```

这里**故意没有 XCTest 测试目标**。这个包必须能在只装了 Command Line Tools 的机器上构建，
而那种环境下根本没有 `XCTest` 模块，`swift test` 连编译都过不去。断言放在
`Sources/DshCuaCore/SelfTest.swift` 里、由二进制自己跑，所以二进制能跑的地方它就能跑，
CI 跑的也是同一套。

架构见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)，冻结的接口定义见
[CONTRACT.md](CONTRACT.md)。

## 不做的事

Windows 和 Linux。OCR。录屏。故意去驱动你正在用的那个 App。破解验证码或绕过 TCC。
没有屏幕录制权限时，除了 `--screenshot` 之外的功能照常可用。

## 许可证

MIT，见 [LICENSE](LICENSE)。
