# Boome 终端核心

这里是 Boome 直接维护并编译的源码，不是 Git submodule、上游镜像或构建时覆盖层。来源和后续吸收规则见根目录 [UPSTREAM.md](../UPSTREAM.md)。

## 范围

- 以 Ghostty v1.3.1 为源码来源，直接纳入此前三处修复；核心版本标为 `1.3.1-boome.2`。
- 保留 macOS 嵌入运行时、终端模型、PTY、Metal/CoreText、配置、共享初始化辅助代码、C 接口、必要资源和回归夹具。
- `pkg/` 保留这条构建链及其本地包依赖闭包；外部包仍按各 `build.zig.zon` 的哈希获取。
- 未迁入上游 macOS Swift 应用、GTK 应用、CI、网站、Nix、发行和独立产品的构建入口。部分共享类型和纯函数仍含其他平台分支，不代表 Boome 支持这些平台。
- 字体、图像和终端夹具支持原有测试与回退字体，不是需要清理的编译产物。

`src/shell-integration/zsh/boome-input` 是本地增强模块：使用 zsh 内建模块、ZLE hooks 和每会话私有邮箱，不依赖 Python 或 Warp 代码。按提示符代次／缓冲版本校验请求，提交采用 ZLE 专用确认键的两阶段握手；过期或冲突请求不执行。该功能要求已完成集成的本地交互式 zsh，其他情况不接管终端。

## 构建

通常从仓库根目录运行 `./scripts/build.sh`。Zig 的 install 和 test 步骤仅对应核心静态库／资源与测试，未保留上游应用构建选项。默认 install 前缀由根脚本指定为 `build/core/`，缓存为 `build/zig-cache/`。

静态归档由当前构建图传入的确切输入交给 Zig 的 LLVM ar 合并，不扫描缓存、不调用 Xcode libtool，也不再事后重打包。归档保留同名对象成员并由链接回归验证。

`include/ghostty.h` 与 `include/module.modulemap` 是壳的唯一 C 边界，模块名仍为 GhosttyKit。核心改变后根构建脚本自动失效旧指纹，重编并重新链接应用。

## 许可证

Ghostty 原始 MIT 声明保留在 `LICENSE`，根目录 `THIRD_PARTY_NOTICES/ghostty-LICENSE` 也保留。字体、测试素材及依赖文件各自的许可证和版权声明维持原样；不要将这些材料一概重新标为 MIT。
