# itmz-studio

用于 iThoughts / iThoughtsX 导图（`.itmz`）的本地查看器、编辑器和批量导出工具。
**零第三方依赖**：只用 Python 3 标准库 + 浏览器原生 JavaScript，没有 npm、构建步骤、框架或 CDN，离线可用。
全部源码约 2,800 行，适合长期自己维护。

已在你的 179 个样本上验证：全部可以打开、渲染；未修改直接保存后的 XML 与原文件逐字节一致。

---

## 1. 快速开始（macOS）

```bash
python3 --version            # 需要 3.8+；若弹出“安装命令行开发者工具”，点安装即可（或 brew install python）
cd ~/Desktop/iThoughts-main/itmz-studio
python3 -m itmz serve ..     # 以上一级目录（你的导图库）为根目录启动，自动打开浏览器
```

也可以直接**双击 `start.command`**，效果相同。第一次双击时，如果 macOS 提示“无法验证开发者”，请右键 → 打开；如果提示没有执行权限，在终端运行 `chmod +x start.command export-all.command`。

浏览器地址是 `http://127.0.0.1:8765/`。服务只监听本机，关掉终端窗口或按 Ctrl+C 即可停止。

## 2. 功能

| 类别 | 功能 |
|---|---|
| 查看 | 按 iThoughts 存储的原始坐标还原布局；也可一键切换为“自动整理”布局（只影响显示，不改文件） |
| | 展开/折叠（折叠后显示隐藏的子主题数量）、全部展开/折叠、滚轮/触控板平移、捏合或 ⌘+滚轮缩放、适应窗口 |
| | Markdown 主题文字、备注（含附件图片、SVG/DOCX 附件链接）、超链接、主题图片、图标、颜色、形状 |
| | 关系连线（曲线/直线/折线、箭头、虚线、标签）、外框（boundary）、分组、标注（callout）、浮动主题、任务进度/截止日期徽章 |
| | 大纲侧栏、全文搜索（文字 + 备注 + 链接，回车逐个跳转） |
| 编辑 | 改文字（双击或 F2，直接打字也可）、添加子主题 / 同级主题、删除、拖动位置、同级上下移动、升级/降级 |
| | 侧栏编辑备注（Markdown + 预览）、链接、颜色（取色器 + iThoughts 常用色）、图标（113 个 iThoughts 图标） |
| | 撤销/重做（200 步）；离开页面前提醒未保存 |
| 保存 | 写回标准 `.itmz`（与 iThoughtsX 兼容，见 §5）；覆盖前自动备份到 `.itmz-studio-backups/`；另存为；新建导图 |
| | 文件在外部被改过（例如 iCloud 同步）时，保存前会提示冲突 |
| 导出 | Markdown、OPML、**单文件离线 HTML**（自带交互查看器和内嵌图片）、FreeMind/Freeplane `.mm`、JSON 全量 |

### 快捷键

| 键 | 作用 | 键 | 作用 |
|---|---|---|---|
| Tab | 添加子主题 | Enter | 添加同级主题 |
| F2 / 双击 / 直接打字 | 编辑文字（Shift+Enter 换行） | Delete | 删除主题 |
| Space | 折叠/展开 | 方向键 | 在主题间移动 |
| ⌘↑ / ⌘↓ | 与相邻同级交换 | ⌘← / ⌘→ | 升级 / 降级为上一同级的子主题 |
| ⌘Z / ⇧⌘Z | 撤销 / 重做 | ⌘S | 保存 |
| ⌘O | 打开 | ⌘F | 搜索 |
| ⌘+ / ⌘− / ⌘0 | 放大 / 缩小 / 适应窗口 | Esc | 取消选择 |

> 输入中文时请先按 F2 或双击进入编辑，因为输入法的首个按键不会触发“直接打字编辑”。

## 3. 批量导出（防止数据被锁死）

```bash
# 把整个导图库导出为 Markdown + OPML + 离线 HTML，目录结构与原来一致
python3 -m itmz export ~/Desktop/iThoughts-main -f md,opml,html -o ~/Desktop/itmz-export

# 全部格式；已存在的文件也覆盖
python3 -m itmz export ~/Desktop/iThoughts-main -f md,opml,html,mm,json -o ~/Desktop/itmz-export --overwrite

# 检查每个文件都能解析，并且“打开→保存”无损
python3 -m itmz check ~/Desktop/iThoughts-main

python3 -m itmz info ~/Desktop/iThoughts-main/Help/Help.itmz      # 查看单个导图的统计
python3 -m itmz new  ~/Desktop/新导图.itmz --title "我的想法"       # 新建空导图
```

也可以双击 `export-all.command`，它会把上级目录导出到桌面的 `itmz-export/`。

| 格式 | 适合 | 保留内容 |
|---|---|---|
| `md` | Obsidian、Typora、任何笔记软件 | 前两层为标题，其余为嵌套列表；备注、链接、任务、图标（emoji）、关系；附件复制到 `<名>.assets/` |
| `opml` | OmniOutliner、Workflowy、Logseq、幕布等大纲软件 | 文字、`_note` 备注、`url` 链接；颜色/图标/任务存在 `_itmz_*` 属性中 |
| `html` | 长期归档、发给别人看 | 和本工具相同的交互查看器（只读），图片以 data URI 内嵌，单文件、离线可开 |
| `mm` | **Freeplane**（开源、持续维护的思维导图软件） | 文字、备注、链接、颜色、折叠、左右方向、图标、图片、关系连线 |
| `json` | 自己写脚本处理 | 每个主题的全部原始属性、关系、分组、样式 |

在 HTML 里点 ⇪ 导出 只会导出单个文件，导出的是**磁盘上已保存**的版本。

## 4. 技术方案与选型理由

```
┌──────────────── 浏览器 (web/) ────────────────┐      ┌──────────── Python 3 标准库 (itmz/) ────────────┐
│ app.js  渲染（HTML 主题 + SVG 连线）/交互/编辑 │ JSON │ server.py   127.0.0.1 HTTP + JSON API            │
│ md.js   安全的 Markdown 渲染（白名单）        │◀────▶│ model.py    无损读写 .itmz（DOM 即模型）         │
│ app.css 样式                                  │      │ exporters/  md · opml · html · mm · json         │
└───────────────────────────────────────────────┘      │ __main__.py 命令行：serve/export/check/info/new  │
                                                       └──────────────────────────────────────────────────┘
```

**为什么不用现成的开源脑图库（jsMind、simple-mind-map、markmap 等）？**
iThoughts 的 `position` 存的是每个主题相对父主题的精确坐标。只要直接按坐标画，就能还原你原来的版面，不需要布局引擎。开源脑图库都有自己的数据模型和自动布局，接入后要做双向转换，而 iThoughts 特有的属性（callout、boundary、任务、形状、富文本……）在转换中容易丢失。自己写一个约 850 行的渲染器（web/app.js）反而更简单、更可控。

**为什么是 Python 标准库 + 原生 JS，而不是 Electron / Tauri / React？**

| 方案 | 依赖与维护负担 | 结论 |
|---|---|---|
| **本方案：Python stdlib + 原生 JS** | 0 依赖、无构建；macOS 自带或一条命令装上 Python；10 年后大概率仍能运行 | ✅ 推荐 |
| Electron + React + TS | 数百个 npm 包，每年要跟进升级，打包签名麻烦 | 负担过重 |
| Tauri + TS | 需要 Rust 工具链和 npm | 同上 |
| 纯前端单 HTML（File System Access API） | 只有 Chromium 支持写回原文件，Safari/Firefox 不支持；无法做批量命令行导出 | 不够通用 |

格式逻辑只在 Python 里实现一份，前端不碰 ZIP/XML。命令行批量导出和网页编辑因此共用同一套经过测试的代码。

**有没有更好的方案？** 建议“两条腿走路”：
1. **继续使用 `.itmz` 作为主格式**，用本工具查看和日常编辑。数据格式不变，将来还能用 iThoughts（iOS 版仍可用时）打开。
2. **定期执行一次批量导出**（`export-all.command`）。Markdown/OPML 用来全文检索和迁移，单文件 HTML 用来长期归档。如果以后想换到功能完整、仍在维护的思维导图软件，`.mm` 导出可以直接用 **Freeplane** 打开继续编辑（会损失部分样式，例如形状和精确坐标）。

## 5. 与原版 iThoughtsX 的兼容性

详见 [`docs/FORMAT.md`](docs/FORMAT.md) §8。要点：
- 保存时**只改动你编辑过的内容**。其它属性、图片和附件、`style.xml`、`display_state.plist` 等全部原样保留。
- XML 序列化方式与 iThoughts 相同。对 179 个样本做“打开→不改→保存”，结果逐字节一致（`python3 -m itmz check` 可随时复验）。
- 未解决：`preview.png` 缩略图不会重新生成，Finder 预览会显示旧图，在 iThoughts 里再保存一次即可刷新。
- **建议你自己验证一次**：用本工具改一个文件的副本（“另存为”），然后在 iThoughtsX 或 iOS 版 iThoughts 中打开它。

## 6. 源码目录

```
itmz-studio/
├── README.md                 本文件
├── start.command             双击启动（以上级目录为导图库）
├── export-all.command        双击批量导出到 ~/Desktop/itmz-export
├── docs/
│   └── FORMAT.md             .itmz 格式规范（基于 179 个样本的分析）
├── itmz/                     Python 包（只用标准库）
│   ├── __init__.py           版本号
│   ├── __main__.py           命令行入口：serve / export / check / info / new
│   ├── model.py              ItmzDocument：读取、to_json、apply_json、无损序列化、原子保存
│   ├── icons.py              图标名 → 原图文件名 / 标签 / emoji / FreeMind 名
│   ├── server.py             本地 HTTP 服务与 JSON API（含安全检查）
│   └── exporters/
│       ├── __init__.py       导出器注册表 EXPORTERS
│       ├── common.py         公共工具：附件复制、链接规范化、任务摘要…
│       ├── markdown.py  opml.py  html.py  freemind.py  jsonx.py
├── web/                      浏览器端（无构建步骤，直接改直接刷新）
│   ├── index.html            页面骨架（导出 HTML 时会被内联）
│   ├── app.css               样式（形状编码 .shape-N 在这里）
│   ├── md.js                 安全 Markdown 渲染器
│   └── app.js                渲染、布局、交互、编辑、保存（按 10 个小节组织）
└── tests/
    └── test_itmz.py          单元测试：python3 -m unittest discover -s tests
```

### HTTP API（供扩展参考）
| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/info` | 版本、根目录、图标表 |
| GET | `/api/files` | 列出根目录下所有 `.itmz` |
| GET | `/api/map?path=` | 读取导图 → `{path, mtime, map}` |
| GET | `/api/file?path=&name=` | 读取包内附件（仅 `assets/`、`notes/`、`preview.png`） |
| GET | `/api/icon?name=` | 读取 iThoughts 原图标 PNG（找到 iThoughtsX 资源目录时） |
| GET | `/api/export?path=&fmt=` | 下载导出文件（带附件时为 zip） |
| POST | `/api/save` | `{path, mtime, topics, saveAs?, force?}` |
| POST | `/api/new` | `{path, title}` |

POST 请求必须带 `X-Itmz: 1` 头，所有请求都会校验 Host，这样你浏览的其它网页无法读写你的文件。

## 7. 扩展指南

**新增一种导出格式**（如 PlantUML）：在 `itmz/exporters/` 新建模块，定义 `EXT = ".puml"` 和 `export(doc, out_path) -> list[str]`（可用 `doc.to_json()` 与 `model.walk()`），然后在 `exporters/__init__.py` 的 `EXPORTERS` 中注册。命令行、网页导出菜单（再加一行 `<a data-fmt=…>`）和测试会自动可用。

**让一个新属性可编辑**（如 `shape`）：
1. `itmz/model.py`：把属性名加入 `MANAGED_ATTRS`（只有在这里的属性才会被写回，这是兼容性的安全阀）；
2. `web/index.html`：在 `#inspector` 加一个输入控件；
3. `web/app.js` 第 8 节：`bindField(控件, 'shape', true)`，并在 `fillInspector()` 中回填。

**调整外观**：形状、颜色、字体都在 `web/app.css`（`.shape-0` … `.shape-12` 对应 iThoughts 形状编码）。

**改动之后**：`python3 -m unittest discover -s tests`；用真实样本跑 `ITMZ_SAMPLES=~/Desktop/iThoughts-main python3 -m unittest discover -s tests` 和 `python3 -m itmz check ~/Desktop/iThoughts-main`。

**建议的后续功能（按价值排序）**
1. 拖动主题到另一个主题上以更换父节点（目前用 ⌘← / ⌘→ 升降级）；
2. 关系连线的新建、删除与编辑；
3. 主题图片的插入与替换（写入 `assets/<新UUID>/`，设置 `att-id`/`att-name`）；
4. 任务字段（进度、日期、优先级）的编辑；
5. 保存时重新生成 `preview.png`（可在浏览器端用 canvas 渲染后随保存请求上传）；
6. 导入：OPML / Markdown / FreeMind → `.itmz`；
7. 打印 / PDF：目前可用浏览器的“打印 → 存储为 PDF”（工具栏和侧栏在打印时会自动隐藏）；
8. 如果需要“双击 .itmz 直接打开”的原生体验，可以再用 Tauri/Electron 套壳，核心代码不需要修改。

## 8. 已知限制
- 渲染是“高保真近似”，不是像素级复刻：字体度量、部分特殊形状（菱形、三角形）、渐细连线、彩虹配色、画布背景纹理的显示效果与原版不同，但数据都会原样保留。
- 新建主题的位置是按简单规则估算的。iThoughts 打开文件后若开启“自动对齐”，会重新排版。
- “自动整理”布局只影响显示，不会写入文件；只有在“原始”布局下拖动主题才会保存新位置。
- 加密（设置了密码）的 `.itmz` 不受支持（样本中没有）。
