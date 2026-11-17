# iThoughts `.itmz` 文件格式说明

> 依据：对你的 `iThoughts-main` 目录中 **全部 179 个 `.itmz`**（共 15,534 个主题、266 条关系连线）逐一解析统计得出。
> 写入方：iThoughts iOS 6.6–7.28、iThoughtsX 5.22–9.4（含 Mac App Store 版）。
> 标注说明：**【确认】** = 样本中可直接验证；**【推断】** = 由官方示例导图的标签或数值规律推断，未经原作者文档证实。

---

## 1. 容器：普通 ZIP 包

| 条目 | 出现率 | 说明 |
|---|---|---|
| `mapdata.xml` | 179/179 | **导图主体（必需）**，总是 ZIP 中第一个条目 |
| `style.xml` | 179/179 | 导图样式（布局、连线、各层级字体/形状/颜色） |
| `manifest.plist` | 179/179 | Apple plist：生成时间、版本号、主题数/字数统计 |
| `preferences.plist` | 179/179 | 文档偏好（`HideCompletedTasks`、`SnapToTopic`） |
| `preview.png` | 173/179 | 缩略图（Finder Quick Look 使用） |
| `display_state.plist` | 68/179 | 视图状态：选中主题 uuid、可视区域、缩放比例 |
| `assets/<UUID>/<文件名>` | 42 处 | **主题图片**，由主题的 `att-id`/`att-name` 引用 |
| `notes/<主题UUID>/<文件名>` | 少量 | **备注附件**（图片、SVG 手绘、DOCX 等），备注 Markdown 中以裸文件名引用 |
| `error.txt` | 15/179 | iOS 端写入的错误日志，可忽略但应原样保留 |

注意：
- ZIP 条目使用 Deflate 压缩；**条目时间戳经常是非法值**（如 “2026 年 14 月”），读取方不应校验日期。
- 有 `att-id` 却没有对应文件的情况真实存在（样本中 6 处），渲染时须容错。

## 2. `mapdata.xml` 总体结构【确认】

```xml
<iThoughts version="4.0" app="com.toketaware.ios.ithoughts" app-version="7.4"
           modified="2019-11-20T10:34:08" author="设备名" system-version="iPad 13.1.3"><topics>
<topic uuid="..." position="{0, 0}" text="中心主题" created="..." modified="...">
<topic uuid="..." position="{196, 0}" text="子主题" created="..." modified="...">
</topic>
</topic>
</topics><relationships>
<relationship type="0" uuid="..." end1-uuid="..." end1-style="2" end2-uuid="..." end2-style="1" b-offset="{166.89, 26.38}" color="DC322F" />
</relationships>
<groups>                      <!-- 可选，仅 5 个文件出现 -->
<group type="0" color="DC322F" member0="UUID" member1="UUID" />
</groups>
</iThoughts>
```

- **没有** `<?xml ...?>` 声明；UTF-8；每个元素后一个换行。
- 所有内容都在**属性**里（无文本节点）。属性值转义：`&amp; &lt; &gt; &quot; &apos;`，换行写作 `&#10;`。
- `<topics>` 下可以有多个顶层 `<topic>`（“同一画布上的多张导图”），但样本里都只有 1 个；“浮动主题”实际上是中心主题的子节点（带 `floating="1"`）。

## 3. `<topic>` 属性

| 属性 | 出现次数 | 含义 |
|---|---|---|
| `uuid` | 15534 | 唯一 ID（大小写混用，关系连线引用时大小写一致）【确认】 |
| `position` | 15534 | `{x, y}`：**本主题中心相对父主题中心**的偏移（顶层主题为画布绝对坐标）【确认：对称布局中子主题坐标严格对称】 |
| `created` / `modified` | 15534 | 本地时间 `YYYY-MM-DDTHH:MM:SS`，无时区 |
| `text` | 15485 | 主题文字，**Markdown**（`**粗**`、`_斜_`、`# 标题`、列表、`[链接][1]`、`<u> <del> <mark>`）|
| `note` | 257 | 备注，**Markdown**；附件以裸文件名引用 `notes/<本主题uuid>/` 下的文件 |
| `link` | 469 | 超链接，按用户输入原样保存：`https://…`、`www.…`、`me@x.org`、甚至无协议域名 |
| `color` | 1497 | 主题填充色 `RRGGBB`（无 `#`） |
| `icon1` / `icon2` | 819 / 12 | 图标名（如 `idea`、`smiley_sad`、`icon-hat-red`），映射表见 `itmz/icons.py` |
| `folded` | 1111 | `1` = 子主题折叠 |
| `shape` | 483 | 形状编码，见下表【确认：来自官方 welcome 导图中每个形状的文字标签】 |
| `text-alignment` | 7562 | 只出现值 `3`（居中）；推断 1=左、2=右【推断】 |
| `text-size` | 414 | 字号（pt） |
| `text-font` | 342 | `PostScript名 | 字体族 | 粗细 | ` 例：`Helvetica-Bold | Helvetica | bold | ` |
| `text-width` / `image-width` | 2171 / 2437 | 用户手动设定的文本宽度 / 图片宽度（pt，浮点） |
| `att-id` / `att-name` | 42 / 36 | 主题图片：`assets/<att-id>/<att-name>`（`att-name` 可能缺失） |
| `boundary` | 859 | `1` = 给该主题及其子树画外框 |
| `floating` | 90 | `1` = 浮动主题（与父主题无连线，自由摆放） |
| `callout` | 49 | `1` = 标注（callout），虚线指向父主题 |
| `summary1` / `summary2` | 1 | 摘要主题：括住从 summary1 到 summary2 的兄弟主题 |
| `task-progress` | 20 | 任务进度 0–100；`101` = 已完成【推断】 |
| `task-start` / `task-due` | 4 | 任务起止时间 |
| `task-priority` / `task-effort` / `resources` | 5/12/4 | 优先级、工时（`3.00h`，`-1.00h`=未设）、负责人（逗号分隔） |
| `cost` / `cost-type` | 8 / 12 | 成本数值 / 类型（1=固定值，2=汇总子项【推断】） |
| `numbering` | 4 | 自动编号格式，如 `0:^nn^.nn^.nn^...^ ` |
| `sorting` | 4 | 子主题自动排序，如 `+2` |
| `hugging` | 4 | 子主题“贴合”布局开关（`2`=关闭【推断】） |
| `map-layout`,`l1-link`,`l1-link-tapered`,`ln-link`,`auto-align` | 12 | 子导图自身的布局/连线样式（只在浮动子导图根上出现） |

### 3.1 形状编码 `shape`【确认】
| 值 | 形状 | 值 | 形状 |
|---|---|---|---|
| 0 | 圆角矩形 | 7 | 圆形 |
| 1 | 矩形 | 8 | 菱形 |
| 2 | 椭圆 | 9 | 平行四边形 |
| 3 | 下划线（Line） | 10 | 胶囊（Pill） |
| 4 | 无 | 11 | 正方形 |
| 5 | 方括号 | 12 | 三角形 |
| 6 | 圆括号 | | |

### 3.2 子导图布局 `map-layout`【确认：welcome 导图标签】
`1` 思维导图（左右发散，`style.xml` 默认）· `2` 垂直 · `3` 自上而下 · `4` 鱼骨图

## 4. `<relationship>` 关系连线

| 属性 | 说明 |
|---|---|
| `uuid` | 连线 ID |
| `end1-uuid` / `end2-uuid` | 两端主题的 uuid【确认】 |
| `type` | `0` 曲线（178）/ `1` 直线（48）/ `2` 折线（40）【推断：welcome 中流程图示例全是 2】 |
| `end1-style` / `end2-style` | 端点样式；`1` = 箭头（238 条在 end2）、`0`/`2` = 无箭头或其它【推断】 |
| `b-offset` | 曲线控制点偏移（贝塞尔），本工具重画时未使用，但原样保留 |
| `color` | 线色 `RRGGBB` |
| `dashed` | `1` = 虚线 |
| `center-text` | 连线中间标签 |

## 5. `<group>` 分组
`type="-1"` 为空占位；`type="0"` 带 `color` 与 `member0..N`（成员主题 uuid），画为包围成员子树的彩色框。

## 6. `style.xml`
单个 `<style>` 元素：整图设置（`mapLayout`、`level1LinkStyle`、`linkThickness`、`inheritColor`=子主题继承父主题颜色、`rainbow`…），以及若干 `<level n="…">`：该层级的 `topicShape`、`topicColor`、`textFont`、`textFontSize`。未定义的层级沿用最近的上一层级（字体/形状）。

## 7. `manifest.plist`
`AppID`、`AppVersion`、`Generated`(UTC)、`Hostname`、`MapRevision`(每次保存新 UUID)、`SystemOS`、`TopicCount`、`TopicWordCount`、`NoteCount`、`NoteWordCount`。

---

## 8. 本工具的兼容写回策略

1. **DOM 即模型**：保存时重新打开磁盘上的原文件，只修改 `text note link color icon1 icon2 folded position` 这 8 个属性以及树结构；其它属性、元素、ZIP 条目（图片、附件、`preview.png`、`display_state.plist`、`error.txt` …）**原样保留**。
2. **序列化与 iThoughts 一致**：无 XML 声明、相同的转义（含 `&apos;`、`&#10;`）、元素间换行。对 179 个样本做“打开→不改→保存”，`mapdata.xml` **逐字节相同**。
3. 新主题：大写 UUID、`created`/`modified` 为本地时间；被修改的主题更新 `modified`；根元素 `modified` 更新。
4. 删除主题时，引用它的关系连线、分组成员、摘要引用一并清理，避免悬空引用。
5. `manifest.plist` 更新 `Generated`、`MapRevision` 和各项计数；`mapdata.xml` 保持为 ZIP 第一项。
6. 原子写入（临时文件 + rename），覆盖前把原文件复制到 `.itmz-studio-backups/`。
7. 已知差异：`preview.png` 不会重新生成（Finder 缩略图显示旧图，直到在 iThoughts 中再次保存）。
