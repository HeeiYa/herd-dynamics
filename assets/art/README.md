# 当前美术素材

角色使用40×40像素画布、八方向动画，共23个动作、184个片段、1328帧。动物、地面与阴影由本项目制作，Astra使用Aseprite绘制，Opus 5.5调整。运行时使用最近邻采样。

| 路径 | 内容 |
| --- | --- |
| `v3/source/*.aseprite` | 24个可编辑角色时间轴，按动物和方向组织 |
| `v3/png/` | 当前角色导出单帧，路径为物种/动作/方向/帧号 |
| `v3/sheets/` | manifest引用的184张动画图条 |
| `v3/manifest.json` | 方向、时长、动作、锚点等图集构建输入 |
| `v2/source/`、`v2/png/` | 当前使用的两种草地与阴影源文件及PNG |
| `../../game/assets/` | 已构建的运行图集与动画元数据 |

编辑Aseprite时间轴后，将相应单帧导出到原路径；帧数或时长改变时同步manifest，然后从仓库根运行 `python tools/build_runtime_atlas.py`。

脚本需要Pillow，读取角色单帧和三张静态PNG，生成 `game/assets/animals.png`、`animals.json`并复制地面与阴影。它不覆盖Aseprite源文件；运行游戏不需要安装这些制作工具。

保留原画布尺寸、透明背景、动作ID及逐方向锚点。镜像方向的锚点与原方向相差一像素，不要直接统一。动作帧仅用于表现，捕食和吃草由模拟系统结算。

manifest中的初始制作日期和`review_candidate`是原始素材元数据，保留以维持既有图集来源哈希，不表示还有额外下载步骤。美术来源及许可范围见 [THIRD-PARTY.md](../../THIRD-PARTY.md)。
