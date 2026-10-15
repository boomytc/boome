# Boome

macOS 终端。窗口左侧是 Boome 自己画的垂直标签栏。每个标签是一个活着的 [Ghostty](https://github.com/ghostty-org/ghostty) surface：Metal 画格子，Core Text 画字。libghostty 以静态库形式嵌在 `GhosttyKit.xcframework` 里。这里不改 Ghostty 上游，也不编 Ghostty.app。

应用名 Boome，bundle id `com.boom.boome`。不用 Ghostty 的名字、bundle id 或图标。libghostty 是 MIT，声明在 [THIRD_PARTY_NOTICES/ghostty-LICENSE](THIRD_PARTY_NOTICES/ghostty-LICENSE)，源码在 `vendor/ghostty`。

## 钉住的版本

| | |
| --- | --- |
| Ghostty tag | `v1.3.1` |
| commit | `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28` |
| `minimum_zig_version` | `0.15.2` |

`vendor/ghostty` 是 git submodule，停在这个 tag 的 commit 上，不跟 `main`，也不跟浮动的 `tip`。

## 从空目录到打开 App

需要 Xcode（这台机器是 Xcode 27）和网络。Zig 必须是 **0.15.2**。版本不对就停，不要换别的 Zig 硬编。

```bash
git clone --recurse-submodules https://github.com/boomytc/boome.git
cd boome
git -C vendor/ghostty fetch --depth 1 origin tag v1.3.1
git -C vendor/ghostty checkout v1.3.1

# 只装这一版。校验打印出来的版本是 0.15.2。
mkdir -p "$HOME/.local/zig"
curl -fL -o /tmp/zig-aarch64-macos-0.15.2.tar.xz \
  https://ziglang.org/download/0.15.2/zig-aarch64-macos-0.15.2.tar.xz
tar -xJf /tmp/zig-aarch64-macos-0.15.2.tar.xz -C "$HOME/.local/zig"
"$HOME/.local/zig/zig-aarch64-macos-0.15.2/zig" version

./scripts/build.sh
open build/Boome.app
```

已经有检出时，重复执行 `./scripts/build.sh`。它在 `GhosttyKit.xcframework` 还在的时候跳过 Zig，只重编 Swift。要重编库：`./scripts/build.sh --rebuild-lib`。

### 实际的 Zig 命令

`v1.3.1` 的 `zig build --help` 里还有 `-Demit-xcframework` 和 `-Demit-macos-app`。没有 `-Demit-lib-vt`。`libghostty-vt` 被接在默认 install step 上，这个 tag 没有开关把它拿掉，所以下面这条命令仍会编出 `libghostty-vt`，Boome 不链接它。

`-Dxcframework-target` 的取值是 `native` 或 `universal`，默认 `universal`（macOS 两套架构，外加 iOS 和 iOS 模拟器）。Boome 只要这台 Mac 上的嵌入库，所以用 `native`。`emit-macos-app` 在打开 xcframework 时默认跟着变成 true，必须显式写成 false，否则会同时编出 Ghostty.app。

```bash
export PATH="$PWD/scripts/xcrun-shim:$HOME/.local/zig/zig-aarch64-macos-0.15.2:$PATH"
cd vendor/ghostty
zig build \
  -Doptimize=ReleaseFast \
  -Demit-xcframework=true \
  -Demit-macos-app=false \
  -Dxcframework-target=native \
  -j4
```

产物是 `vendor/ghostty/macos/GhosttyKit.xcframework`。资源在 `vendor/ghostty/zig-out/share/`（`ghostty/` 里的 shell integration 和主题，旁边的 `terminfo/78/xterm-ghostty`）。这些目录、`.zig-cache`、xcframework、`build/` 都不进 git。

### 这台 Mac 上 Zig 0.15.2 为什么还要一层垫片

Xcode 27 的 macOS 27 SDK 里，系统 `.tbd` 只列 `arm64e-macos`，不列 `arm64-macos`。Zig 0.15.2 把两者当成不同目标，链接自己的 build runner 时就会缺 `_abort` 这一类 libSystem 符号。修这个的链接器改动在 Zig 0.16，而 Ghostty `v1.3.1` 拒绝别的 Zig。

`scripts/macos-sdk-shim.py` 把当前 SDK 克隆到 `~/.cache/boome/MacOSX-arm64-shim.sdk`（不改 Xcode 自带的那份），并在每个 `arm64e-*` 旁边补上对应的 `arm64-*`。同一份垫片里的 `math.h` 还会补上 `INFINITY`：macOS 27 的头在编译器声明支持 modules 时不定义这个宏，Zig 0.15.2 自带的 libc++ 又要用它，结果是 `use of undeclared identifier 'INFINITY'`。`scripts/xcrun-shim/xcrun` 只拦 Zig 用来问 SDK 路径的那一次 `xcrun --sdk macosx --show-sdk-path`，其它 `xcrun` 仍走 `/usr/bin/xcrun`。Swift 链接用 Apple 的链接器和真正的 SDK。

编译 `src/renderer/shaders/shaders.metal` 需要 Metal 工具链。`xcrun -sdk macosx metal` 若报 missing Metal Toolchain，先执行 `xcodebuild -downloadComponent MetalToolchain`，再重跑构建。

Zig 0.15.2 的 HTTP 客户端访问 `deps.files.ghostty.org` 会拿到 400，访问一部分 GitHub 归档会中途断连。`scripts/prefetch-ghostty-deps.sh` 用 curl 把 `build.zig.zon` 里的包下下来，再 `zig fetch` 进全局缓存。哈希对不上就停。

Xcode 27 的 `libtool` 会丢掉 Zig 0.15.2 产出的、不是 8 字节对齐的对象文件，打出来的 `libghostty-fat.a` 里没有 `ghostty_surface_new`。`scripts/repack-libghostty.sh` 用 `ar` 把同一批静态库重新合上，再盖回 xcframework。库里已经有这个符号时脚本直接退出。链接还要带上 GameController：静态库里的 imgui macOS 后端引用了 `GCController`，`-force_load` 会把它拉进来。

## 壳在做什么

Swift + AppKit。所有 `ghostty_*` 调用都在 `src/GhosttyHost.swift`。升级 submodule 时只改这一处。

- 默认一个窗口，左侧标签栏宽 200。点一行就切换。悬停有一层很浅的底。选中行是同一背景上更亮的一层，字更重，不用另一块颜色。
- 标签菜单里的 Use Horizontal Tabs（⌥⌘T）把同一批标签从左侧栏收到窗口顶部一条，再按一次放回去。切换时侧栏和顶栏一起做宽度和高度动画，shell 不拆窗口、不销毁。右击标签可以新建、关闭、关闭其他、关闭右侧。
- Hide Sidebar（⌥⌘S）在垂直布局里把侧栏收成 0。水平布局里标签已经在顶上，Show Sidebar 会回到展开的垂直栏。标题栏左侧、红绿灯右边有一枚常驻的 `sidebar.left` 按钮，点它走同一条切换和同一段动画。展开时悬停是「收起侧栏 (⌥⌘S)」，收起后按钮留在原位，悬停是「展开侧栏 (⌥⌘S)」。收起后，开关右边只显示当前会话名，放不下会截断，悬停是完整名字；这一区域仍可拖动窗口，不提供下拉选择，切换会话由侧栏或顶部标签页列表承担。切到另一行、增删标签或窗口布局变化时，这一行会滚进可见范围；只更新标题不会拉动滚动位置。
- 窗口的位置和大小、标签在左侧还是顶部、侧栏开还是收，下次打开还在。不恢复当时的 shell。
- 每行的字仍是库报上来的标题，没有就用目录名，再没有就是 `Terminal 1`、`Terminal 2`。窗口标题用完整字符串。侧栏上面是目录名。第二行只在它能把标签分开时出现：远程主机、比 `~` 和 `/` 更长的父路径、或者同一行字重复时的序号和真正不同的那一段路径。本机主机名不重复贴。自己设的标签标题不拆。键盘切到另一行时，落点短闪一下。
- 悬停或选中时，行尾可以关掉这一行，不必先切过去。右键也是关闭。关掉没选中的行时，当前格子不动。底部 “New Tab” 平时没有底色，悬停才铺一层浅底，不和选中行抢一个实心。Cmd+T 开新标签。Cmd+W 关当前标签。关掉最后一个时留下一个新 shell，不关窗口。关闭其他和关闭右侧若有程序还在跑，只问一次：确认关掉这一批，取消则一个都不关。
- Cmd+Shift+[、Cmd+Shift+] 在相邻标签间切换。Ctrl+Tab 下一个，Ctrl+Shift+Tab 上一个。
- 切标签只显示和隐藏 surface，不销毁，也不停里面的 shell。键盘、鼠标、滚动、选区、剪贴板交给当前可见的 surface。
- 每个标签只有一个 surface。没有分屏。
- 字体、字号、主题色不另写配置。`ghostty_config_load_default_files` 读 `~/.config/ghostty/config`（以及库自己还会读的那些默认路径）。
- 资源按 Ghostty macOS 应用的摆法放进 bundle：`Contents/Resources/ghostty` 和 `Contents/Resources/terminfo`。库靠 `terminfo/78/xterm-ghostty` 找到资源目录，再把 `TERMINFO` 指到旁边的 terminfo，shell integration 从 `ghostty/shell-integration` 注入。`share/` 下其余文件（补全、man、主题）一并复制。缺 terminfo 哨兵或缺 shell integration 目录时，构建直接失败，不悄悄跳过。

新标签的工作目录来自 `ghostty_surface_inherited_config(..., GHOSTTY_SURFACE_CONTEXT_TAB)` 的 `working_directory`。那是库从当前 surface 记下的目录（shell integration 的 OSC 7），并且还要 Ghostty 配置里的 `tab-inherit-working-directory` 开着（默认开着）。库给不出路径时用家目录。Boome 不解析 shell 提示符。

因此在 shell integration 还没报过目录的时候（新开的第一个标签、集成被配置关掉、或者 `tab-inherit-working-directory = false`），新标签从家目录起。

`/usr/bin/login` 会在登录 shell 开头印 `Last login: ... on ttysNNN`。库只在家目录已经有 `.hushlogin` 时才给 login 加 `-q`。Boome 不创建、不删除这个文件。

应用图标是一枚橙色鬼魂，外面一圈云朵，底是透明的，源图在 `resources/AppIcon.png`。构建时打成 `AppIcon.icns`。侧栏和标题栏用库读到的终端 `background`，不再另铺一块米色。选中行也不再铺橙色：那一块和深色终端是两个表面。选中只是背景上更亮的一层，字保持浅色。侧栏行不再重复贴这枚图标：窄栏里每行一枚同样的鬼魂只会挤掉标题。

明确不做：分屏、Quick Terminal、AppleScript、滚动搜索、通知、内置浏览器、agent 状态环、SSH 包装、Linux、Windows、iOS、签名公证、上架。

## 验证

2026-10-14，在这台 Mac 上用 `./scripts/build.sh` 编出 `build/Boome.app`（xcframework 已在，这次跳过了 Zig），再 `open build/Boome.app`。进程是 LaunchServices 拉起的，bundle id `com.boom.boome`。窗口约 1100×720，左侧标签栏宽 200，选中行是蓝底白字，底部有 “+ New Tab”。

这次进程里实际做过的操作：

- 第一个标签的 shell 画出了登录行和 `echo BOOME_TAB1_OK` 的输出。字体和深色主题来自本机 `~/.config/ghostty/config`，仓库里没有第二份配置。
- Cmd+T 打开第二个标签。新格子里没有 `BOOME_TAB1_OK`，只有自己的登录行。在里面执行 `echo BOOME_TAB2_OK`，输出只出现在这个标签。
- Cmd+Shift+[ 切回第一个标签，`BOOME_TAB1_OK` 还在。Ctrl+Tab 再切到第二个标签，`BOOME_TAB2_OK` 还在。点侧栏第一行也能切回去。
- Cmd+W 关掉第一个标签。窗口还在，剩下的标签仍显示 `BOOME_TAB2_OK`，对应的 login 进程还在，被关掉的那个已经退出。
- 再 Cmd+W 关掉最后一个标签。窗口没有退出。侧栏仍有一行，格子里是新的登录行和提示符，旧的 login 进程没有了，新的 login 进程在。
- 在留下的 shell 里 `cd /tmp` 之后 Cmd+T。新标签的提示符是 `boom@M4-Pro-of-Boom /tmp %`，没有带上一条标签里的 `cd` 命令。工作目录来自库给出的当前 surface 目录。
- 新标签里 `printf '%s\n' "$TERM"` 印出 `xterm-ghostty`。bundle 里有 `Contents/Resources/terminfo/78/xterm-ghostty` 和 `Contents/Resources/ghostty/shell-integration/zsh`。

这次没有单独按 Cmd+Shift+] 和 Ctrl+Shift+Tab。下一个标签走的是 Ctrl+Tab，上一个走的是 Cmd+Shift+[。鼠标选区、滚动和剪贴板这次没有操作。`confirm-close-surface` 在光标不在提示符上时会弹确认，这条路径没有跑。

同一天稍后给图标和侧栏上了色，并重新编过、打开过。侧栏和标题栏用的是终端的深色背景，不再是米色板加一条白标题栏。鬼魂没有方板，选中行是橙色，字是深棕色，底部是 “+ New Tab”。终端格子里仍能看见登录行。Dock 图标用的是同一张透明底图打出来的 `AppIcon.icns`，这次没有单独截 Dock。

同一天再往后收了一轮侧栏，重新编过并 `open build/Boome.app`。看到的是：选中行上面是 `~`，下面是 `boom@M4-Pro-of-Boom`，字是深色，行尾有关闭标记；底部 “+ New Tab” 没有底色。点另一行，橙色会跟着过去。点选中行的行尾，这一行关掉，对应的 login 进程没了，剩下的行还在。菜单 Cmd+T 只新开一个 login。在当前格子里 `cd /tmp` 之后，提示符变成 `/tmp`，侧栏这一行变成 `tmp`，窗口标题仍是完整的 `/tmp`，关闭标记还在。悬停时的浅底、右键关闭、以及关掉没选中的那一行，这次没有单独看。浅色主题没有跑。

同一天再改了重复行。重新编过并打开。只有一个家目录标签时，侧栏只有 `~`，没有主机名。菜单 Cmd+T 再开一个家目录标签后，两行分别是 `~` / `1` 和 `~` / `2`。把选中的那个 `cd /tmp` 之后，它变成单独的 `tmp`，留下的家目录标签也回到只有 `~`。Ctrl+Tab 切回 `~`，窗口标题是完整的 `boom@M4-Pro-of-Boom:~`。键盘落点那一下短闪没有截到。远程主机和两条不同父路径的同名目录，这次没有造出来看。

同一天拿掉登录横幅。重新编过并打开。新会话的 login 参数里有 `-q`，格子第一行是提示符 `boom@M4-Pro-of-Boom ~ %`，没有 `Last login`。家目录里有空的 `.hushlogin`。

同一天加上原生水平标签和侧栏折叠。重新编过并打开。Cmd+T 后再 ⌥⌘T，标题栏出现两条系统标签和一个加号，侧栏让开，提示符还在。Ctrl+Tab 之后两条标签都还在。再 ⌥⌘T 回到左侧栏，两行是 `~` / `1` 和 `~` / `2`，两个 login 进程都还在。⌥⌘S 收起侧栏后提示符贴着窗口左缘，再按一次侧栏回来。把一条标签拖出窗口，这次没有单独看。

同一天去掉选中行的橙色底。重新编过并打开。两条家目录标签里，选中的是同一深色上更亮的一层，字是浅色，未选中的没有底。终端格子还是原来的深色。浅色主题没有跑。

同一天把水平/垂直改成同一扇窗口里切换。重新编过并打开。两条标签在左侧时是 `~` / `1` 和 `~` / `2`。⌥⌘T 之后它们排到标题栏下方，写成 `~ 1` 和 `~ 2`，右边有加号，提示符还在，仍是一个窗口、两个 login。再 ⌥⌘T 回到左侧栏。右击菜单这次没有点开。0.22 秒的过渡没有逐帧截。
