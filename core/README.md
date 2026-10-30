# Boome 终端核心

`core/` 是 Boome 直接维护并编译的源码。构建不把它当作 Git submodule，也不把它当作上游镜像或构建时的覆盖层。来源和下一次怎么跟进，见根目录 [UPSTREAM.md](../UPSTREAM.md)。

## 范围

- 源码来自 Ghostty v1.3.1，并直接包含此前三处修复。核心版本是 `1.3.1-boome.3`。
- 保留 macOS 嵌入运行时、终端模型、PTY、Metal、Core Text、配置、共享的初始化辅助代码、C 接口，以及构建和运行要用的资源。
- `pkg/` 保留这条构建链和它的本地包依赖。外部包仍按各自 `build.zig.zon` 里的哈希获取。
- 未迁入上游的 macOS Swift 应用、GTK 应用、CI、网站、Nix、发行脚本，以及独立产品的构建入口。部分共享类型和纯函数仍含其他平台的分支。这些分支不表示 Boome 支持那些平台。
- 保留运行时使用的字体和各自许可证；仅供测试的字体、图像和终端夹具已移除。

`src/shell-integration/zsh/boome-input` 是本仓库加的模块。它使用 zsh 内建模块、ZLE hooks，以及每个会话自己的私有邮箱。它不依赖 Python，也不包含 Warp 的代码。请求按提示符代次和缓冲版本校验。提交分两步。ZLE 先安装该请求的确认键，然后才接受确认。过期或冲突的请求不执行。zsh 处于可编辑提示符时，命令只在底部文本框里编辑。已加载的自动建议插件提供浅色后缀。Tab 走当前绑定的补全 widget。补全和历史搜索的结果回到这个文本框。格子盖住当前提示符，用来呈现已经执行的命令和输出。程序正在运行、备用屏幕、集成关闭或不支持的状态仍用原来的终端输入。

## 构建

从仓库根目录运行 `./scripts/build.sh`。Zig 的 install 只产出核心静态库和资源。上游应用的构建选项没有保留。根脚本把 install 前缀设为 `build/core/`，把缓存设为 `build/zig-cache/`。

静态归档的成员是当前构建图列出的对象文件，由 Zig 的 LLVM ar 合并。构建不扫描缓存，不调用 Xcode libtool，也不在链接前再打包一次。归档保留同名对象。

`include/ghostty.h` 和 `include/module.modulemap` 是 AppKit 应用使用的 C 边界。模块名是 GhosttyKit。核心源码变化后，根构建脚本让旧指纹失效，然后重编并重新链接应用。

开发采用根目录约定的 `confident-development-conventions`。核心和本地包不保留内嵌测试、测试构建入口或测试专用依赖；必要验收与临时验证资产的处理见根目录 README。运行时诊断、调试断言和产物完整性校验继续保留。

## 许可证

Ghostty 的 MIT 声明在 `LICENSE`。根目录还有一份 `THIRD_PARTY_NOTICES/ghostty-LICENSE`。字体、素材和依赖文件各自保留原来的许可证和版权声明。其中不是 MIT 的文件，不能改标成 MIT。
