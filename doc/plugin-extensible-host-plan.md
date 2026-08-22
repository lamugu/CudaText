# CudaText 可扩展宿主改造清单

> Fork: https://github.com/lamugu/CudaText  
> 基线: `master` @ `8ea0787`（上游最新）  
> 工作目录: `E:\0.application\CudaText-extensible`  
> 分支: `feature/plugin-extensible-host`  
> 目标: 核心变薄宿主，功能默认走 Python 插件 + 数据扩展，避免「改一处功能就要整包重编译」。

---

## 0. 原则（先定边界）

### 必须留在核心（Pascal）

| 能力 | 原因 |
|------|------|
| ATSynEdit 编辑缓冲 / 标签分组 | 性能与稳定性 |
| EControl / lite lexer 引擎 | 热路径 |
| 键位引擎、会话、崩溃备份 | 宿主职责 |
| Python 嵌入与 `cudatext_api` 桥 | 插件运行时 |
| zip 安装器骨架 | 分发入口 |
| 查找/保存等管线的**薄钩子** | 插件无法可靠拦截 |

### 默认外置（插件 / data）

- UI 工具、侧栏、网络（更新/LLM）、项目、注释、排序、偏好编辑器、LSP/Lint/Format、便签等业务
- lexer / 主题 / 图标 / snippet / 翻译（已有 `cudatext-data`）

### 明确不做

- **不**新增第二套 Pascal DLL 插件 ABI（成本高、文档与生态全在 Python）
- **不**把热路径（树助手、括号高亮等）硬搬回 Python（上游已证明会再吸回核心）

### 与本地旧改动的关系

`E:\0.application\CudaText` 上已有实验（大文件 Viewer、dlg 拖放、Smart Notes）可在本 fork **按阶段移植**，但先完成宿主契约，再合入业务插件。

---

## 1. 改造分期总览

| 阶段 | 主题 | 是否需重编译核心 | 交付物 |
|------|------|------------------|--------|
| **P0** | 能力注册表，去掉硬编码插件名 | 是（一次） | `capability` API + 改调用点 |
| **P1** | 特权管线钩子（保存 / 打开 / 查找） | 是（一次） | 稳定事件语义 + 文档 |
| **P2** | 菜单 / 工具栏声明式扩展 | 是（一次） | install.inf / API 扩展 |
| **P3** | 命令盘点与可覆盖命令 | 是（渐进） | 命令表 + deprecate 策略 |
| **P4** | 业务外置与迁移你的已有功能 | 插件为主 | Viewer / 拖放 / Smart Notes |
| **P5** | 宿主瘦身与文档 / 测试 | 视情况 | API wiki、测试插件 |

---

## 2. P0 — 能力注册表（解耦硬编码）

### 现状问题（最新上游仍存在）

| 调用点 | 硬编码 |
|--------|--------|
| `formmain.pas` | `cuda_project_man.open_dir` / `new_project_open_dir` |
| `formmain.pas` | `cuda_new_file.menu` |
| `formmain_cmd.inc` | `cuda_addonman.check_cudatext_updates` |
| `formmain.pas` | 工具栏 Hint → `cuda_comments,*` |
| `formmain.pas` | 默认热键 → `cuda_comments,cmt_toggle_line_body` |

### 修改清单

1. **新增宿主概念 `capability`（能力 ID）**  
   建议 ID：`open_folder`、`new_from_template`、`check_updates`、`comment_line_*`、`comment_stream`。

2. **注册方式（二选一或并存）**  
   - `install.inf`：`[capability1] id=open_folder method=open_dir`  
   - 运行时：`app_proc(PROC_CAPABILITY_REGISTER, 'open_folder;module;method')`

3. **核心只调注册表**  
   - 新增 `DoPyCapability('open_folder', args)`  
   - 替换上述所有 `DoPyCommand('cuda_…')`  
   - 未注册时：静默跳过或提示「缺少提供该能力的插件」

4. **触及文件**  
   - 新增：`app/proc_capabilities.pas`（或并入 `proc_globdata.pas`）  
   - 改：`formmain_py_pluginwork.inc`（解析 install.inf）  
   - 改：`formmain.pas`、`formmain_cmd.inc`  
   - 改：`py/cudatext.py`、`proc_py_const.pas`、`formmain_py_api.inc`（导出 API）  
   - 改：内置插件 `cuda_project_man` / `cuda_new_file` / `cuda_addonman` / `cuda_comments` 的 `install.inf`

5. **验收**  
   - 禁用 `cuda_project_man` 后，打开文件夹不再崩溃，仅提示缺失能力  
   - 第三方插件可注册同名能力并替换默认实现（后注册覆盖或优先级字段）

---

## 3. P1 — 特权管线钩子

### 3.1 保存链路

| 项 | 说明 |
|----|------|
| 问题 | 插件无法可靠接管 Untitled 的 Ctrl+S（见 Smart Notes 设计） |
| 改法 | 在 `DoFileSave` / `formmain_loadsave.inc` 增加可短路钩子 |
| 建议事件 | 增强现有 `on_save_pre`：返回 `False` = 已处理且取消默认；或新增 `on_save_managed` |
| 触及 | `formmain.pas`、`formmain_loadsave.inc`、`formmain_py_helpers.inc`、API 文档 |
| 验收 | Smart Notes 类插件无需启发式猜 Untitled |

### 3.2 打开链路

| 项 | 说明 |
|----|------|
| 问题 | 大文件 Viewer、自定义打开器目前只能改 Pascal |
| 改法 | `on_open_pre` 可返回打开模式建议：`edit` / `view_text` / `view_binary` / `reject` |
| 触及 | `formmain.pas` 打开分支、`proc_globdata` 事件枚举 |
| 验收 | 「大文件 Viewer」可做成纯插件策略（核心只保留默认阈值可选） |

### 3.3 查找链路

| 项 | 说明 |
|----|------|
| 问题 | Find UI 与命令深度耦合 |
| 改法 | 扩展 `finder_proc` + `on_state_findbar`；允许插件注册 `count` / `extract` 提供者（含 Viewer） |
| 触及 | `form_find.pas`、`formmain_find.inc`、`form_frame.pas` |
| 验收 | Viewer Count All 可由插件或核心提供者实现，不写死一种算法入口 |

### 3.4 事件契约文档

- 统一「返回值语义表」：哪些事件可短路、优先级、lazy 加载  
- 文件：`wiki` 同步说明 + `cuda_make_plugin/events.py` 更新

---

## 4. P2 — 菜单 / 工具栏声明式扩展

### 修改清单

1. **install.inf 支持挂载点**  
   例：`menu=file/open`、`toolbar=main/after_save`，避免插件只能往「Plugins」堆菜单。

2. **核心默认菜单改为「骨架 + 能力按钮」**  
   - File → Open Folder：绑定 capability `open_folder`，无插件则隐藏或灰显  
   - 工具栏注释按钮：绑定 capability，不写死 `cuda_comments`

3. **触及文件**  
   - `formmain.lfm` / 菜单初始化代码  
   - `formmain_py_pluginwork.inc`  
   - `menu_proc` / `toolbar_proc` 文档

4. **验收**  
   - 更换 Project 插件实现无需改核心菜单字符串

---

## 5. P3 — 命令盘点与可覆盖命令

### 修改清单

1. **审计 `proc_cmd.pas`**  
   分类：`host-only` / `plugin-preferred` / `deprecated-to-plugin`。

2. **可覆盖机制**  
   - 插件通过 capability 或 `APP_PROC_SET_SUBCOMMANDS` 覆盖同功能  
   - 核心命令保留 ID 兼容，内部转发到 capability（过渡期）

3. **优先外置候选（非热路径）**  
   - 关于框增强、字符映射表、部分 Goto UI、主题挑选对话框（数据已外置，UI 可后移）  
   - **不优先外置**：书签核心、分组、编码转换管线

4. **触及**  
   - `proc_cmd.pas`、`formmain_cmd.inc`、命令文档

---

## 6. P4 — 业务迁移（含你已有改动）

在 P0–P1 就绪后，按独立 PR/提交移植：

| 功能 | 建议形态 | 依赖阶段 |
|------|----------|----------|
| 大文件 Viewer | 默认阈值可留核心；策略插件化（`on_open_pre`） | P1 |
| Viewer Count | 查找提供者 API | P1 |
| dlg `drag_files` / `on_drop_files` | **核心 API 扩展**（一次编译）+ 插件使用 | P0 后即可合 |
| Project / Tabs 拖出文件 | 纯插件改动 | 依赖 drag API |
| Smart Notes | 插件 + P1 保存钩子 | P1 |
| IME `OnUTF8KeyPress` | 小核心补丁，并入 dlg API 批次 | 任意早期 |

---

## 7. P5 — 工程化

1. **API 版本**  
   - `install.inf` 的 `api=` 与 `app_api_version()` 对能力注册、新事件做版本门槛。

2. **测试插件**  
   - `cuda_testing_capabilities`：注册/覆盖/缺失  
   - `cuda_testing_save_hook`：短路保存  
   - 保留现有 `cuda_testing_*`

3. **文档**  
   - CudaText_API：capability、新事件、drag_files  
   - 本仓库 `doc/`：迁移指南（如何把硬编码功能改成插件）

4. **与上游同步策略**  
   - `upstream` remote 已加  
   - 尽量把改动做成**小而稳的宿主补丁**，便于 rebase；业务留在 `cuda_*`  
   - 不把 fork 专有业务强推上游；宿主钩子可择机向上游贡献

---

## 8. 建议目录 / 模块改动一览（实现时勾选）

### 核心（Pascal）

- [x] `app/proc_globdata.pas` — `TAppCapabilityInfo` + 注册/解析 API
- [x] `app/formmain_py_pluginwork.inc` — 解析 `[capability*]`
- [x] `app/formmain.pas` — 去掉硬编码 `DoPyCommand('cuda_…')`
- [x] `app/formmain_cmd.inc` — 更新检查走 capability
- [x] `app/formmain_py_helpers.inc` — `DoPyCapability`；`on_save_pre` 字符串短路
- [x] `app/form_frame.pas` — `on_save_pre` 返回路径则无对话框保存
- [ ] `app/formmain_find.inc` / `form_find.pas` / `form_frame.pas` — 查找提供者
- [x] `app/formmain_py_api.inc` / `proc_py_const.pas` — `PROC_CAPABILITY_*`
- [x] `app/proc_customdialog*.pas` + `proc_windows_dragfiles.pas` — 拖放 API（已移植）

### Python / 插件

- [x] `app/py/cudatext.py` — `PROC_CAPABILITY_*`
- [x] 内置四插件 `install.inf` 声明 capability
- [ ] `cuda_smart_notes`（移植）
- [ ] `cuda_testing_capabilities`（新建）

### 配置 / 文档

- [ ] `settings_default/default.json` — 仅保留宿主级选项
- [ ] `doc/plugin-extensible-host-plan.md`（本文件）
- [ ] API / plugins wiki 摘录更新

---

## 9. 第一批动手顺序（建议）

1. **P0.1** ~~实现 capability 注册表 + 替换 5 处硬编码~~ **已完成**（见 commit）
2. **P0.2** 文档与测试插件
3. ~~**移植** dlg 拖放 + IME 小补丁~~ **已完成**（`drag_files` / `on_drop_files`）
4. **P1.1** 保存短路钩子 → 再合 Smart Notes
5. **P1.2** 打开模式钩子 → 再合大文件 Viewer 策略
6. **P2/P3** 菜单声明式与命令盘点（可并行）

### P0 已落地的 capability ID

| ID | 默认提供者 | 方法 |
|----|------------|------|
| `open_folder` | cuda_project_man | open_dir |
| `new_project_open_dir` | cuda_project_man | new_project_open_dir |
| `new_file_from_template` | cuda_new_file | menu |
| `check_updates` | cuda_addonman | check_cudatext_updates |
| `comment_line_add` | cuda_comments | cmt_add_line_body |
| `comment_line_del` | cuda_comments | cmt_del_line |
| `comment_line_toggle` | cuda_comments | cmt_toggle_line_body |
| `comment_stream_toggle` | cuda_comments | cmt_toggle_stream |

运行时注册：`app_proc(PROC_CAPABILITY_REGISTER, 'id;module;method[;priority]')`  
查询：`app_proc(PROC_CAPABILITY_GET, 'id')` → `'module,method'`  
列举：`app_proc(PROC_CAPABILITY_ENUM, '')`

---

## 10. 成功标准

- 新增一类「IDE 功能」时：**默认只加 `cuda_*` + 可选 data zip**，无需改 Pascal  
- 改核心仅发生在：新宿主钩子、性能关键路径、安装器/API 桥  
- 内置插件可替换、可禁用，核心不因缺失某个 `cuda_*` 而逻辑断裂  
- 能持续 `git fetch upstream` 并较小冲突地变基
