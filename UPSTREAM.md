# 上游对齐

Boome 的终端核心源自 [Ghostty](https://github.com/ghostty-org/ghostty)。这里记录来源、已处理范围、刻意偏离与持续吸收方式；不是 Git 依赖锁，也不是上游整树同步承诺。

## 当前基线

- 源码来源：Ghostty `v1.3.1`，`332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`。
- 核心在 `core/` 中直接维护，版本标为 `1.3.1-boome.2`，Zig 仍为 0.15.2。
- 上游已处理至 `a2e440396403385680008e456a741a7776091412`。此前核对的 21 个领先提交按适用性处理如下；“已处理”表示完成评估，不表示 Boome 已等同于该上游版本。
- 本地 `/Users/boom/workspace/ghostty` 是此开发机的参照仓库，不是构建输入。换机器、没有该目录或没有 Git 元数据，均不影响从本仓库源码构建。
- 最初的源码所有权迁移不额外升级到上游 main。本地新增行为单独列在下方，不代表扩大上游同步范围。

## 已吸收行为

| 上游提交 | Boome 原吸收提交 | 当前实现 |
| --- | --- | --- |
| `a9139e56c3e99209648d25063c60c4c9f61b3645` | `918474c` | `core/src/Surface.zig`：鼠标上报已消费按下时，释放不再被提示符点击拦截；Shift 未被捕获时仍保留提示符光标移动。 |
| `ad97d331459a0762f7aea5f56fe86748e03b860f` | `f76ccf4` | `core/src/termio/Termio.zig`：在 processOutput 的同一把锁内，先通知 PTY 尺寸，再更新网格。 |
| `a2e440396403385680008e456a741a7776091412` | `eb13902` | `core/src/terminal/formatter.zig`：按单元格输出 OSC 8，保留显式 id、换链接直接打开新的、空单元格前关闭、跨行延续；纯文本不输出，HTML 继续使用锚点。 |

这三处及其已有 VT 回归直接保留在源码中，不再保存或应用补丁文件，不在旧实现旁边维护另一条运行路径。

## 参考或跳过

| 内容 | 处理与原因 |
| --- | --- |
| GTK 4.18、libadwaita 1.7 及旧版本条件分支清理、GTK 翻译与 Blueprint 整理 | 跳过。Boome 是 AppKit 壳，不构建 GTK 应用；未迁入该应用源码及构建依赖。既有核心翻译资源保留，以免迁移改变资源内容。 |
| GitHub Actions token 更新、VOUCHED 名单 | 跳过。属于 Ghostty 仓库治理与 CI，不是嵌入库行为。 |
| OSC context signal 改名为 hierarchical context | 暂不吸收。线上仍是 OSC 3008，Boome 不调用被改名的 C 符号；不为无消费者的改名增加并行兼容接口。 |

## 刻意偏离

- 产品界面、会话、窗口、项目浏览与编辑器由 Boome 自己维护，不迁入上游 Swift 应用。
- 核心构建只暴露 macOS arm64 的静态嵌入库、资源和测试，不保留 GTK、Ghostty.app、网站、发行流水线或独立 libghostty-vt 产品的构建入口。
- 保留嵌入库的 C ABI、GhosttyKit 模块名、配置和 shell integration 契约。必要共享辅助代码及原有测试夹具不因目录精简而随意删除。
- 核心版本来自自身 manifest，不读取 Boome 的 Git tag 推测 Ghostty 版本。
- 使用当前构建图的确切静态归档输入；不再使用 xcframework、Xcode libtool 或缓存扫描重打包。
- 本地命令输入增强由 AppKit NSTextView 和 zsh ZLE 协调实现，只借鉴 Warp 的交互模型，不迁入其 Rust 编辑器或 UI 框架。命令文本经每 surface 的私有目录／FIFO 传递；提交校验会话、提示符代次、缓冲版本和期限，先在 ZLE 安装请求专用确认键，再由应用发送确认。普通按键／粘贴在待确认期间暂停转发，不将命令文本模拟输入到运行程序。
- shell integration 增加 `zsh/boome-input` 本地模块；关闭、运行、未知上下文或不支持的 shell 回到原终端链路。不得以屏幕提示符猜测可编辑缓冲，也不得用 eval 解码编辑请求。应用运行时资源固定取自身 bundle，不能继承父终端的 Ghostty 路径。
- 保留原始版权、MIT 声明及各依赖／字体／素材各自的许可证。上游源码不是全部同一许可证的独立原创代码。

## 跟进方法

1. 在参照仓库检查工作树和远程跟踪状态；可 fetch 更新远程跟踪引用。快进其 main 需用户明确授权；不要修改其源码、切换其工作树来完成 Boome 构建。
2. 以上面的“已处理终点”为起点，固定新的目标提交。即使本地 main 已快进，也按这个明确区间核对，不只看 `main..origin/main`。
3. 同时读取提交记录和目标快照／净差异，识别合并、后续撤销与重构，避免重复或过期吸收。
4. 分类为吸收、仅参考或跳过。检查是否进入 macOS 嵌入库、是否有 Boome 消费者、是否覆盖现有本地行为。
5. 将接受的行为融入现有核心或 Swift 边界，迁移实际消费者；不额外保留补丁覆盖层、重复实现或未经选择的整树副本。
6. 按范围运行核心定向测试、Swift 回归、完整构建和必要运行时／实窗验证。核心改动必须实际重编并链接，不能拿旧缓存的 Swift 构建当作核心验证。
7. 完成验证后更新终点、处理记录和刻意偏离。标明未验证项目；用户实测、API 集成测试与助手鼠标实窗操作分开记录。仅按明确授权提交，不默认推送。

例如从根目录读取后续范围：

```bash
upstream="../ghostty"  # 可换成本机参照仓库位置；不是构建参数
base="a2e440396403385680008e456a741a7776091412"
target="$(git -C "$upstream" rev-parse origin/main)"
git -C "$upstream" log --reverse --oneline "$base..$target"
git -C "$upstream" diff --stat "$base" "$target"
```

迁移的验证结果见 README 的验证记录。
