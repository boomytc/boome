# Boome 开发约定

- Swift/AppKit 壳在 `src/`，自主维护的 Zig 终端核心在 `core/`。
- 生产代码的 `ghostty_*` 调用集中在 `src/GhosttyHost.swift`；C 模块名保持 GhosttyKit，不另建并行接口。运行时测试可直接读取库版本和构建模式来核验链接产物。
- 上游跟进方法、已处理终点和刻意偏离见 `UPSTREAM.md`。本地同级 Ghostty 仓库仅作源码参照，不是编译依赖；可 fetch 更新远程跟踪引用，不为 Boome 改写或切换它的工作树，快进其 main 需用户明确授权。不要恢复 submodule、构建时补丁或直接编译外部工作树。
- 按上游明确提交区间和最终源码判断，分类为吸收、参考或跳过。只将适用行为融入 Boome 现有实现，保留原有版权和许可证；完成验证后更新上游记录。
- 核心只构建 macOS arm64 的嵌入式静态库及资源，不恢复 Ghostty.app、GTK、网站、发行流水线或额外 libghostty-vt 产品。
- 构建：`./scripts/build.sh`；强制重编核心：`./scripts/build.sh --rebuild-lib`。Zig 必须是 0.15.2；每次最多一个重型 Zig 构建。
- Swift 回归：`./scripts/test-tab-logic.sh`。构建支持回归：`python3 -m unittest discover -s tests -p test_core_build.py`。真实库／控制器集成检查：`./scripts/test-core-runtime.sh`。Zig 定向测试命令见 README。
- 改核心源码后必须重编核心并链接应用，不能只跑跳过 Zig 的旧产物构建。构建脚本会按源码和工具链指纹自动判断。
- 区分单元测试、真实库运行时检查和实窗鼠标操作，用户实测不得写成助手实测。未做的项目明确记录。
- 命令输入文档与撤销／选区归属会话。zsh 协调走私有邮箱／FIFO，只有已确认的当前 ZLE 请求可发送提交键；不得将命令文本猜测式注入 PTY、解析屏幕重建输入、eval 解码请求或改写用户 shell 配置。不支持的状态保持原终端。
- 未经用户明确授权不提交，不默认推送。提交前重读实际差异，核验需求完整性、测试与暂存范围。
