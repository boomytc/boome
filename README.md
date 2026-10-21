# Boome

Boome 是 macOS 终端。窗口左侧是 Boome 画的垂直标签栏，每个标签是一个终端 surface。Metal 画格子，Core Text 画字。

终端核心在 `core/`，源码来自 [Ghostty](https://github.com/ghostty-org/ghostty)，编成静态库后链进应用。构建只读本仓库里的这份源码。

应用名是 Boome，bundle id 是 `com.boom.boome`。Ghostty 的 MIT 声明在 [THIRD_PARTY_NOTICES/ghostty-LICENSE](THIRD_PARTY_NOTICES/ghostty-LICENSE) 和 `core/LICENSE`。其他依赖、字体和素材仍用各自的许可证。

## 核对版本

| | |
| --- | --- |
| 核心源码来源 | Ghostty `v1.3.1`，`332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28` |
| Boome 核心版本 | `1.3.1-boome.2` |
| 上游已处理终点 | `a2e440396403385680008e456a741a7776091412` |
| Zig | `0.15.2` |

下一段上游改动按 [UPSTREAM.md](UPSTREAM.md) 的提交区间处理。表里的终点表示这些提交已经评估过。`core/` 与上游 main 不是同一棵树。构建不使用 submodule，也不读取本机的 Ghostty 目录。

## 构建并打开应用

安装 Xcode。这台机器用的是 Xcode 27。第一次拉取依赖时需要网络。Zig 必须是 `0.15.2`。版本不同时，脚本打印 `Zig <version> does not match minimum_zig_version 0.15.2. Stop.` 然后退出。

```bash
git clone https://github.com/boomytc/boome.git
cd boome

mkdir -p "$HOME/.local/zig"
curl -fL -o /tmp/zig-aarch64-macos-0.15.2.tar.xz \
  https://ziglang.org/download/0.15.2/zig-aarch64-macos-0.15.2.tar.xz
tar -xJf /tmp/zig-aarch64-macos-0.15.2.tar.xz -C "$HOME/.local/zig"
"$HOME/.local/zig/zig-aarch64-macos-0.15.2/zig" version

./scripts/build.sh
open build/Boome.app
```

`zig version` 应打印 `0.15.2`。构建结束后，应用在 `build/Boome.app`。

再次运行 `./scripts/build.sh` 时，其中的 `core_fingerprint` 调用 `scripts/core-fingerprint.py`。指纹计入 `core/` 里常规文件的内容、大小和权限。名为 `.zig-cache`、`zig-out`、`__pycache__` 或 `.DS_Store` 的路径不计。元数据是 Zig 的路径和版本、macOS SDK 的路径和 build 版本、SDK 副本路径、`ReleaseFast` 和 `aarch64-macos`。另外计入这五个脚本：`scripts/build.sh`、`scripts/core-fingerprint.py`、`scripts/macos-sdk-shim.py`、`scripts/xcrun-shim/xcrun`、`scripts/prefetch-ghostty-deps.sh`。指纹不变时复用 `build/core/lib/libghostty.a`。`core/` 里的文件有修改、新增或删除时，脚本重编核心。`./scripts/build.sh --rebuild-lib` 在指纹未变时也重编核心。

产物是 `build/core/lib/libghostty.a`、`build/core/include/` 和 `build/core/share/`。Swift 使用的模块名是 GhosttyKit。核心只构建 macOS arm64 嵌入库和资源。Ghostty.app、GTK 和 libghostty-vt 都没有产物。`swiftc` 的 `-sdk` 指向 Apple 的 SDK。`scripts/build.sh` 取这个路径时把 `PATH` 设成 `/usr/bin:/bin`，所以用的是 `/usr/bin/xcrun`。

静态归档由 Zig 的 LLVM ar 合并当前构建图列出的对象，并保留同名对象。链接行仍包含 GameController 和 `-force_load`。不要改回 Xcode libtool。libtool 会丢掉没有按 8 字节对齐的 Mach-O 对象。

如果 Metal 编译报 missing Metal Toolchain，先运行：

```bash
xcodebuild -downloadComponent MetalToolchain
```

依赖由 `scripts/prefetch-ghostty-deps.sh` 用 curl 下载。`zig fetch` 按 `build.zig.zon` 里的哈希校验。

## 运行测试

同一时间只跑一个重型 Zig 构建。

### 运行核心的定向测试

Xcode 27 自带的 macOS 27 SDK 里，有些系统 `.tbd` 只列出 `arm64e-macos`。Zig 0.15.2 不能把它们匹配到 `arm64-macos`。下面的命令先做一份 SDK 副本，再跑测试。副本写在 `~/.cache/boome`，不修改 Xcode。副本里还补上 libc++ 要用的 `INFINITY`。`scripts/xcrun-shim/xcrun` 只在参数同时包含 `--show-sdk-path` 和 `macosx` 时返回这份副本。其他 `xcrun` 请求交给 `/usr/bin/xcrun`。

```bash
export ZIG="$HOME/.local/zig/zig-aarch64-macos-0.15.2/zig"
python3 scripts/macos-sdk-shim.py
export PATH="$PWD/scripts/xcrun-shim:$PATH"
cd core
"$ZIG" build test \
  -Dtest-filter=hyperlink -Dtest-filter=resize \
  --cache-dir ../build/zig-cache -j4 --summary all
```

### 运行应用和构建检查

在仓库根目录运行。

标签和会话逻辑：

```bash
./scripts/test-tab-logic.sh
```

构建脚本和指纹：

```bash
python3 -m unittest discover -s tests -p test_core_build.py
```

zsh 命令输入协议：

```bash
python3 -m unittest discover -s tests -p test_command_input_zsh.py
```

真实的 libghostty 和 AppKit 控制器：

```bash
./scripts/test-core-runtime.sh
```

运行前至少唤醒一块显示器。两块显示器都休眠时，CoreVideo 没有活动显示器，这项检查失败。检查使用独立的应用标识，关闭默认配置，并使用临时 HOME。检查直接调用真实库里的会话迁移、编辑和退出确认接口。检查不拖动物理鼠标，也不覆盖跨屏操作。

要让隔离测试窗口接收鼠标和键盘事件，先把辅助功能里的输入控制权限授给测试进程，然后运行：

```bash
BOOME_INPUT_UI_SMOKE=1 ./scripts/test-core-runtime.sh
```

要看 bash 的回退，运行：

```bash
BOOME_INPUT_FALLBACK_SMOKE=1 BOOME_TEST_SHELL=/bin/bash ./scripts/test-core-runtime.sh
```

## 窗口行为

下面是当前应用的行为。生产代码里的 `ghostty_*` 调用都在 `src/GhosttyHost.swift`。核心 C API 有变化时，在这个文件里适配。

### 标签和窗口

默认一个窗口。左侧标签栏宽 200 点。点一行就切换到那个标签。悬停时行上有一层浅底。选中行用同一背景上更亮的一层，字更重。选中行不用另一块颜色。

标签只在左侧栏。拖到一行的上边缘或下边缘会调整顺序。拖到一行中央会创建分组，或加入已有分组。组标题可以折叠和展开。整个组可以拖动排序。把成员拖过分组边界，会把该成员拖出这个组。

标签行的右键菜单始终有 **New Tab**、**Close Tab** 和 **New Group**。**Close Other Tabs** 在只剩一个标签时不可用。**Close Tabs to the Right** 在最后一行不可用。**Group with Active Tab** 要同时满足两个条件才出现。点中的标签不是当前标签。点中的标签没有分组，或不在当前标签那一组。点中的标签已经在组里时，菜单有 **Remove from Group**。还存在其他分组时，菜单有 **Move to Group**。

组标题的右键菜单有 **Rename Group…**、**Ungroup** 和 **Close Group**。标签行和组标题都有 **Move to New Window**。这一项在选中对象已经包含全部标签时不可用。还有其他可以接收会话的窗口时，菜单再加 **Move to Window**。

会话或整个组拖出所有 Boome 窗口时，会进入一个独立窗口。拖进其他窗口的侧栏时，按落点排序或分组。目标侧栏收起时，可以拖到终端或面板区域，会话加到那个窗口的末尾。Esc 取消拖拽。**Move to New Window** 和 **Move to Window** 做同一种搬运。**New Window**（⌘N）直接新建独立窗口。

搬运保留原来的 surface、shell、正在运行的程序和终端内容。最后一条会话搬走后，空的来源窗口关闭。来源窗口的编辑器有未保存内容时，编辑器窗口留下。这种情况下不新建替代 shell，也不把编辑缓冲搬到目标窗口。保存或放弃内容之后，可以关窗，也可以用 ⌘T 再创建会话。

**Hide Sidebar**（⌥⌘S）把侧栏宽度收到 0。标题栏左侧、红绿灯右边有一枚常驻按钮，符号是 `sidebar.left`。点它走同一条切换，也走同一段动画。侧栏展开时，悬停文字是 **收起侧栏 (⌥⌘S)**。收起后按钮留在原位，悬停文字是 **展开侧栏 (⌥⌘S)**。收起后，标题栏不显示当前会话名。侧栏收起时，用键盘换标签，或者先展开侧栏再点一行。切到另一行、增加或删除标签，以及窗口布局变化时，当前行滚进可见范围。只更新标题时，滚动位置不动。

每行的字来自库报上来的标题。库没有标题时用目录名。目录名也没有时用 `Terminal 1`、`Terminal 2`，序号继续增加。窗口标题用完整字符串。侧栏第一行是目录名。第二行只在它能把标签区分开时出现。出现的情况有三种：远程主机、比 `~` 和 `/` 更长的父路径，以及同一行字重复时的序号加上真正不同的那段路径。本机主机名不重复显示。用户自己设的标签标题不拆开。用键盘切到另一行时，落点短闪一下。

悬停或选中时，行尾可以关掉这一行，不必先把这一行选成当前标签。右键里的 **Close Tab** 也关闭它。关掉的不是当前行时，当前格子不动。底部的 **New Tab** 平时没有底色，悬停时才铺一层浅底。⌘T 打开新标签。终端有焦点时，⌘W 关闭当前标签。关掉最后一个标签时留下一个新 shell，窗口不关。

进程已经退出，命令框里没有未提交文本，也没有进行中的提交时，标签直接关闭。进程还在、命令框里有未提交文本，或提交还在进行时，对话框是 **Close this terminal?**。按钮是 **Close** 和 **Cancel**。**Close Other Tabs** 和 **Close Tabs to the Right** 把选中的标签合成一批。这一批里只要有一个标签需要确认，就只问一次。对话框是 **Close these terminals?**。**Close** 关掉这一批。**Cancel** 一个都不关。关闭整扇窗口时，按同样的条件检查每个标签。其中有标签需要确认时，对话框是 **Close this window?**。按钮也是 **Close** 和 **Cancel**。这个对话框还开着时，窗口里的标签都不关闭。

⌘⇧[ 是 **Previous Tab**。⌘⇧] 是 **Next Tab**。Ctrl+Tab 切到下一个标签。Ctrl+Shift+Tab 切到上一个标签。

切换标签只显示和隐藏 surface。surface 不销毁，里面的 shell 也不停。终端有焦点时，键盘、鼠标、滚动、选区和剪贴板交给当前可见的 surface。文件树和编辑器使用 AppKit 自己的输入、选区和剪贴板。

新建、切换和关闭会话都针对当前窗口。关闭一扇窗口不会停掉其他窗口的终端。退出应用时，每个窗口分别检查正在运行的程序和未保存内容。已经确认退出的窗口暂时不再接受新输入。任一确认选了取消之后，输入恢复。等待其他窗口确认时新做的编辑还留在原来的窗口里。

每个标签只有一个 surface。没有分屏。

### 项目浏览器和编辑器

标题栏第二枚按钮是文件夹图标，对应 **Show Project Explorer** 和 **Hide Project Explorer**（⌥⌘E）。面板位于标签栏和终端之间。只有这一个工具，所以没有工具切换栏。浏览器默认跟随当前会话的工作目录。

浏览器标题栏里，省略号按钮的辅助功能名称是 **Project Explorer options**。菜单项是 **Choose Project Folder…**、**Follow Current Session**、**Show Hidden Files**、**Refresh**。已经有项目目录时还有 **Reveal Project in Finder**。旁边另有 **Refresh Project Explorer** 和 **Close Project Explorer**。目录按需异步读取。文件夹排在前面，名称按自然顺序排序。符号链接不递归展开。文件行的右键有 **Open**、**Open Externally**、**Reveal in Finder** 和 **Copy Path**。

双击文件，或选中文件后按回车，在终端右侧的编辑器里打开。对目录按回车或双击，用来展开和收起。编辑器打开 UTF-8 文本，上限 2 MB。它支持撤销、重做、**Find…**（⌘F）和 **Save**（⌘S）。保存保留 UTF-8 BOM、原来的换行格式，以及可执行权限。保存使用原子写入。

打不开时的提示是这三句：

- `Only regular text files can be edited. Use Open Externally for folders and other file types.`
- `This file exceeds the editor's 2 MB limit. Use Open Externally to open it in another application.`
- `This is a binary file or is not UTF-8 text. Use Open Externally to open it in another application.`

磁盘内容变了时，对话框是 **This file changed outside Boome**。按钮是 **Cancel** 和 **Overwrite**。符号链接改了指向时，第一次保存也弹出这个对话框。选择 **Overwrite** 之后保存仍然失败。标题是 **Could not save**，后面带文件名。编辑留在当前文件。

标题栏最右侧的按钮开合编辑器。菜单名是 **Show Editor** 和 **Hide Editor**。关闭编辑器、切换文件、关闭窗口或退出时，未保存的内容会打开对话框。标题是 **Save changes to** 加上文件名。按钮是 **Save**、**Don’t Save** 和 **Cancel**。保存失败时留在当前文件。编辑器有焦点时，⌘W 关闭编辑面板。其他时候 ⌘W 仍关闭当前终端标签。项目浏览器和编辑器同时展开时，窄窗口按最小宽度变宽，给终端留至少 240 点。

窗口的位置和大小、标签栏和项目浏览器的开合、固定的项目目录，以及隐藏文件偏好，下次打开还在。记下位置的那扇窗口关闭后，还开着的窗口接管这份位置记忆。重启后只创建一个新 shell。窗口集合、分组、旧 shell 和未保存的编辑缓冲都不恢复。编辑器默认收起。以前记下的水平标签布局会改成展开的左侧标签栏。

### 命令输入

支持的本地 zsh 在提示符编辑态显示原生命令输入框。单击定位、拖选、Shift 扩选、双击选词、三击选行、按选区替换、撤销、重做和 Unicode 输入都由 `NSTextView` 处理。Enter 执行。Shift+Enter 或 Option+Enter 换行。输入法确认候选不会直接提交。粘贴写进输入框，按 Enter 之前不执行。光标在视觉上的第一行时，上键交给 zsh 的 `up-line-or-history`。在视觉上的最后一行时，下键交给 `down-line-or-history`。其他位置仍在输入框里移动光标。Tab 把草稿交给 shell 做补全。Ctrl+R 交给 `history-incremental-search-backward`。Esc 以及 **Terminal** 同样交回。点 **Edit command** 恢复原生编辑。输入框、选区和撤销管理器属于这个会话。跨窗口搬运时不重建它们。

bash、远程 shell、REPL、密码提示，以及交互程序自己的输入框，仍走普通终端。下面几种情况也走普通终端：zsh 握手还没建立、shell integration 关闭、keymap 不受支持，以及 exec 之后失去集成。

原生草稿和 shell 缓冲冲突时，草稿保留。必须选 **Use draft** 或 **Use shell**。**Use draft** 只重新确认基线，不执行。**Use shell** 放弃原生草稿。关标签、关窗口和退出时，未提交的非空草稿也进入关闭确认。草稿不跨应用重启保留。

### 配置、资源和启动

字体、字号和主题色没有另一份 Boome 配置。`ghostty_config_load_default_files` 加载库的默认文件。`$XDG_CONFIG_HOME` 未设置时，XDG 目录是 `~/.config`。会加载的文件是：

- `~/.config/ghostty/config`
- `~/.config/ghostty/config.ghostty`
- `~/Library/Application Support/com.mitchellh.ghostty/config`
- `~/Library/Application Support/com.mitchellh.ghostty/config.ghostty`

前两行是 XDG 路径。文件名 `config` 是 Ghostty 1.2 及更早的位置，`config.ghostty` 是现在的位置。后两行在 Application Support，bundle id 来自 `core/src/build_config.zig` 的 `bundle_id`。两份 XDG 文件都存在时，两份都加载，旧路径在前。两份 Application Support 文件的路径不同且都存在时，同样两份都加载。路径和顺序见 `core/src/config/Config.zig` 的 `loadDefaultFiles`。

把窗口拖到另一块显示器时，窗口和字体的逻辑尺寸不变。渲染缓冲按那块屏幕的 1× 或 2× 重配。垂直同步改跟那块屏幕的刷新率。倍率相同也会更新显示器。这次更新不靠重新布局来触发。

启动时把 `GHOSTTY_RESOURCES_DIR` 和 `TERMINFO` 固定到应用自己的 bundle，并清除继承来的 `GHOSTTY_BIN_DIR`。从其他终端启动时，应用用的是自己的资源目录。资源按 Ghostty macOS 应用的位置放进 bundle，即 `Contents/Resources/ghostty` 和 `Contents/Resources/terminfo`。库靠 `terminfo/78/xterm-ghostty` 找到资源目录，再把 `TERMINFO` 指到旁边的 terminfo。shell integration 从 `ghostty/shell-integration` 注入。`share/` 下的补全、man 和主题一并复制。缺少 terminfo 的这个文件，或缺少 shell integration 目录时，构建失败。

新标签的工作目录来自 `ghostty_surface_inherited_config(..., GHOSTTY_SURFACE_CONTEXT_TAB)` 的 `working_directory`。那是库从当前 surface 记下的目录，来源是 shell integration 的 OSC 7。还要求 Ghostty 配置里的 `tab-inherit-working-directory` 开着。这个选项默认开着。库给不出路径时用家目录。Boome 不解析 shell 提示符。

shell integration 还没报过目录时，新标签从家目录起。还没报过，是因为这是第一个标签、集成被关掉，或 `tab-inherit-working-directory = false`。

`/usr/bin/login` 会在登录 shell 开头打印 `Last login: ... on ttysNNN`。家目录已经有 `.hushlogin` 时，库才给 login 加上 `-q`。Boome 不创建这个文件，也不删除它。

应用图标是一枚橙色鬼魂，外面一圈云朵，底是透明的。源图在 `resources/AppIcon.png`。构建时打成 `AppIcon.icns`。侧栏和标题栏用库读到的终端 `background`。选中行是背景上更亮的一层，字保持浅色。侧栏每一行不重复贴这枚图标。

当前不做这些事：分屏、Quick Terminal、AppleScript、滚动搜索、通知、内置浏览器、agent 状态环、SSH 包装、Linux、Windows、iOS、代码签名、公证、上架。

## 验证记录

下面按日期记录当时跑过的检查，以及明确没跑的项目。助手操作和用户实测分开写。

2026-10-14，在这台 Mac 上用 `./scripts/build.sh` 编出 `build/Boome.app`。当时 xcframework 已在，这次跳过了 Zig。然后执行 `open build/Boome.app`。进程由 LaunchServices 拉起，bundle id 是 `com.boom.boome`。窗口约 1100×720，左侧标签栏宽 200。当时选中行是蓝底白字，底部有 “+ New Tab”。

这次进程里实际做过的操作：

- 第一个标签的 shell 画出了登录行，以及 `echo BOOME_TAB1_OK` 的输出。字体和深色主题来自本机 `~/.config/ghostty/config`。仓库里没有第二份配置。
- ⌘T 打开第二个标签。新格子里没有 `BOOME_TAB1_OK`，只有它自己的登录行。在里面执行 `echo BOOME_TAB2_OK`。输出只出现在这个标签。
- ⌘⇧[ 切回第一个标签，`BOOME_TAB1_OK` 还在。Ctrl+Tab 再切到第二个标签，`BOOME_TAB2_OK` 还在。点侧栏第一行也能切回去。
- ⌘W 关掉第一个标签。窗口还在。剩下的标签仍显示 `BOOME_TAB2_OK`。对应的 login 进程还在。被关掉的那个已经退出。
- 再按 ⌘W 关掉最后一个标签。窗口没有退出。侧栏仍有一行。格子里是新的登录行和提示符。旧的 login 进程没有了。新的 login 进程在。
- 在留下的 shell 里 `cd /tmp`，然后按 ⌘T。新标签的提示符是 `boom@M4-Pro-of-Boom /tmp %`。新标签没有带上一条标签里的 `cd` 命令。工作目录来自库给出的当前 surface 目录。
- 新标签里 `printf '%s\n' "$TERM"` 印出 `xterm-ghostty`。bundle 里有 `Contents/Resources/terminfo/78/xterm-ghostty` 和 `Contents/Resources/ghostty/shell-integration/zsh`。

这次没有单独按 ⌘⇧] 和 Ctrl+Shift+Tab。下一个标签走的是 Ctrl+Tab。上一个标签走的是 ⌘⇧[。鼠标选区、滚动和剪贴板这次没有操作。光标不在提示符上时，`confirm-close-surface` 会弹确认。这条路径没有跑。

同一天稍后给图标和侧栏上了色，并重新编过、打开过。侧栏和标题栏用的是终端的深色背景。鬼魂没有方板。当时选中行是橙色，字是深棕色，底部是 “+ New Tab”。终端格子里仍能看见登录行。Dock 图标用的是同一张透明底图打出来的 `AppIcon.icns`。这次没有单独截 Dock。

同一天再收了一轮侧栏，重新编过并 `open build/Boome.app`。看到的是：选中行上面是 `~`，下面是 `boom@M4-Pro-of-Boom`，字是深色，行尾有关闭标记。底部 “+ New Tab” 没有底色。点另一行，橙色会跟着过去。点选中行的行尾，这一行关掉，对应的 login 进程没了，剩下的行还在。菜单 ⌘T 只新开一个 login。在当前格子里 `cd /tmp` 之后，提示符变成 `/tmp`，侧栏这一行变成 `tmp`，窗口标题仍是完整的 `/tmp`，关闭标记还在。悬停时的浅底、右键关闭，以及关掉没选中的那一行，这次没有单独看。浅色主题没有跑。

同一天再改了重复行。重新编过并打开。只有一个家目录标签时，侧栏只有 `~`，没有主机名。菜单 ⌘T 再开一个家目录标签后，两行分别是 `~` 加 `1`，以及 `~` 加 `2`。把选中的那个 `cd /tmp` 之后，它变成单独的 `tmp`。留下的家目录标签也回到只有 `~`。Ctrl+Tab 切回 `~`。窗口标题是完整的 `boom@M4-Pro-of-Boom:~`。键盘落点那一下短闪没有截到。远程主机和两条不同父路径的同名目录，这次没有造出来看。

同一天拿掉登录横幅。重新编过并打开。新会话的 login 参数里有 `-q`。格子第一行是提示符 `boom@M4-Pro-of-Boom ~ %`，没有 `Last login`。家目录里有空的 `.hushlogin`。

同一天加上原生水平标签和侧栏折叠。重新编过并打开。⌘T 后再按 ⌥⌘T。标题栏出现两条系统标签和一个加号，侧栏让开，提示符还在。Ctrl+Tab 之后两条标签都还在。再按 ⌥⌘T 回到左侧栏。两行是 `~` 加 `1` 和 `~` 加 `2`。两个 login 进程都还在。⌥⌘S 收起侧栏后，提示符贴着窗口左缘。再按一次，侧栏回来。把一条标签拖出窗口，这次没有单独看。

同一天去掉选中行的橙色底。重新编过并打开。两条家目录标签里，选中的是同一深色上更亮的一层，字是浅色。未选中的没有底。终端格子还是原来的深色。浅色主题没有跑。

同一天把水平和垂直两种排列改成在同一扇窗口里切换。重新编过并打开。两条标签在左侧时是 `~` 加 `1` 和 `~` 加 `2`。⌥⌘T 之后它们排到标题栏下方，写成 `~ 1` 和 `~ 2`。右边有加号，提示符还在。仍是一个窗口、两个 login。再按 ⌥⌘T 回到左侧栏。右击菜单这次没有点开。0.22 秒的过渡没有逐帧截。

### 2026-10-15：排序、分组和多窗口

接管 Pi 留下的排序、分组和多窗口实现后，补修了两处。单成员组可以从边界脱组。多窗口退出期间，已经批准的窗口不能继续输入。同时删除了临时拖拽追踪输出。`./scripts/test-tab-logic.sh` 的 213 项检查、完整构建和空白检查通过。另用真实 libghostty 和 AppKit 控制器执行 30 项运行时集成检查，全部通过。覆盖范围包括连续迁移、同一个 surface 和 shell PID 与局部变量保持、编辑器焦点和未保存内容保留、最后一条会话移走后保留编辑器窗口、退出取消后恢复输入与焦点，以及再次退出时保存另一窗口的文档。

本轮助手在实窗里复测了同窗口鼠标拖拽排序、右键跨窗口迁移，以及来源编辑器缓冲保留。连续跨窗口鼠标拖拽的助手自动化反复中断。随后用户在真实窗口里实测，确认没有问题。该项验收按用户实测通过。上面 30 项运行时集成检查直接调用迁移和确认 API。鼠标连续跨窗口拖拽的通过依据是用户实测，未计作助手自动化通过。

### 2026-10-15：核心源码改由本仓库维护

`core/` 已纳入实际使用的终端源码、依赖构建定义、资源和测试夹具。此前三处补丁对应的生产文件，与打补丁后的旧基线逐字节一致。其余迁移改动集中在构建入口、版本来源，以及移除不使用的应用分支。原来的 submodule、补丁目录、xcframework，以及按缓存扫描再打包的流程，已经删除。上游对照改为按 [UPSTREAM.md](UPSTREAM.md) 选择性吸收。那份对照不参与 Boome 构建。

本轮验证通过了四组检查：257 项 hyperlink 和 resize 定向 Zig 检查，213 项 Swift 检查，20 项构建支持检查，32 项真实 libghostty 和 AppKit 集成检查。运行时确认加载 `1.3.1-boome.1` 的 ReleaseFast 核心。保留的有 surface、shell PID、局部变量、源编辑缓冲，以及退出取消后的输入和焦点。原库的 93 个 `ghostty_*` 导出符号集合保持一致。源码变化会触发重编。随后不变的构建复用核心库。

提交前修正了根 `.gitignore` 的 `build/` 规则。原来的规则会漏掉 `core/src/build/`。改为 `/build/`，并补了仓库布局回归。核验了 940 个核心源文件与资源的暂存字节和执行权限。另从暂存区导出一份源码副本并完成构建。那份副本的路径含空格，没有 `.git`，没有 `vendor`，`build` 是空的。复用了已校验的全局依赖缓存。这次不是完全无缓存的联网引导。

运行时初次检查时，两块显示器都在休眠，CoreVideo 没有活动显示器，检查失败。唤醒后完整重测通过。测试入口已补上活动显示器的前置检查。没有更改显示器的分辨率或布局。

本轮运行时检查直接调用迁移和确认 API。不计作物理鼠标拖拽、fzf 点击、拖窗或跨屏实测。这些项目本轮没有重新验收。

### 2026-10-15：原生命令输入

命令输入参照 Warp 把输入当成独立文本编辑器的做法，用 AppKit `NSTextView` 实现定位、拖选、扩选、多行和撤销。没有迁入 Warp 的代码。zsh 通过私有目录、FIFO 和 ZLE hooks 发布真实缓冲区及提示符代次。原生草稿不会逐字注入 PTY。提交先校验版本和期限，再安装该请求的确认键，然后发送确认。过期、冲突和取消都不自动执行。已经暂存到 ZLE 的提交在取消时还原原来的 shell 缓冲。提交、补全和增量历史搜索都经正常的 ZLE widget 执行。搜索后按回车可以直接执行，不需要额外按键。补全和增量历史搜索期间，暂停原生接管。目录事件通知驱动正常握手。定时器只用来兜底失败和超时。提交前再次读取 shell 状态时，仍校验原始草稿基线，不静默换成新版本。从 shell 历史载入的非空待执行命令，同样进入关闭确认。

修正了按下和抬起之前的鼠标坐标同步。运行时资源固定到 Boome 自己的 bundle。验证时，即使父环境指向无效的 Ghostty 路径，也可以启动，也可以回退。核心版本为 `1.3.1-boome.2`。已经重编并链接应用。

本轮通过的检查：252 项 Swift 检查，34 项 Python 检查（其中 20 项构建支持，14 项真实 zsh 和 PTY 协议），257 项核心定向检查，45 项真实库和控制器运行时检查，17 项真实窗口 CGEvent 交互检查，3 项 bash 回退检查。运行时覆盖原来的 shell PID 和变量、Unicode 提交、运行中程序的输入不被截获、跨窗携带命令草稿和选区及独立撤销管理器、文件编辑缓冲独立，以及退出批准和取消。实窗检查覆盖自动焦点、点击定位、拖选、替换、撤销、双击选词、三击选行、Shift 扩选、Unicode 粘贴、Shift+Enter 换行，以及点击 **Run** 后恢复输入。

输入法预编辑的防误提交和关闭保护，由 AppKit 接口检查覆盖。Unicode 粘贴没有说成中文拼音候选的全流程实测。没有重做跨屏、物理鼠标连续跨窗拖拽、fzf、vim，或任意 zsh 插件组合的人工验收。非 zsh、远程 shell 和应用自身输入仍走普通终端。不提供跨应用重启的命令草稿恢复。

### 2026-10-18：测试审计和遗留代码清理

逐符号核对了 `src/`、`tests/`、`scripts/` 和 `core/` 里 Boome 自己的改动。删除了生产代码里没有调用、测试也没有覆盖的这些项：`TabList.append`、`BoomeChrome.accent`、`icon(pointSize:)`、没有 selector 的 `TabRowView.closePressed`、从不构造的 `CursorStyle.hidden`、只写不读的 `TerminalSurfaceView.cursorHidden`、关闭 AppKit tabbing 后没有入口的 `newWindowForTab`，以及和 `paste` 实现完全相同的 `pasteAsPlainText`。标签右键菜单改为调用已有的 `TabList.requestingCloseOthers` 和 `requestingCloseRight`。测试覆盖的 API 与生产里的内联实现因此不再各写一份。

测试侧删除了重复的 “close window 不是 tab close”、已经移除的 ⌥⌘T 墓碑断言，以及和重复历史用例覆盖相同的 zsh 用例。重排断言改为校验真实顺序和替选身份。自然排序断言不再强解包。原子保存用例用硬链接证明写时替换。`ghostty.h` 改为按 `#filePath` 定位。zsh 用例去掉固定 sleep，并新增 “安装失败不导出邮箱路径” 回归。修正了 `boome-input` 在邮箱校验失败时把 `BOOME_INPUT_DIR` 留给子进程的问题。`ghostty-integration` 加载桥接模块前，增加资源是否存在的检查。

本轮验证：250 项 Swift 检查，20 项构建支持检查，14 项真实 zsh 和 PTY 协议检查，45 项真实库和控制器运行时检查，17 项真实窗口 CGEvent 交互检查，3 项 bash 回退检查。核心因 shell integration 变化实际重编，并重新链接应用。随后不变的构建复用核心库。没有删除上游保留、当前又没有构建入口的 `core/src/lib_vt.zig` 和 `core/src/build/Config.zig` 执行项，以免扩大和上游源码的差异。`build/` 下未跟踪的旧重打包目录约 344 MB，已确认被忽略，没有当作代码清理删除。没有重做物理鼠标跨窗拖拽、跨屏，或任意 zsh 插件组合的人工验收。
