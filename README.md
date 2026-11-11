# 羊群之中 · Herd Dynamics

由羊、狼与牧羊犬组成的2D自主群体模拟。观察动物觅食、结群、追猎与保护，调整场景和参数，也可以抓放动物、移动镜头和查看行为线索。

## 启动

当前支持 **Windows x64**，使用 **Godot 4.7.2标准版**、**LimboAI 1.8.1** 与 **Forward+**。显卡及驱动需要支持Forward+和计算着色器。

1. 克隆仓库或下载并解压源码。
2. 安装 [Godot 4.7.2标准版](https://github.com/godotengine/godot-builds/releases/tag/4.7.2-stable)，在项目管理器导入 [game/project.godot](game/project.godot)。
3. 等待首次资源导入完成，按 **F5** 运行。

仓库已包含运行图集、动画元数据和LimboAI的Windows x64编辑器/运行DLL。启动游戏无需Python、Pillow、Aseprite或Git LFS。

也可使用根目录 `Open-Godot.cmd`：脚本依次查找 `GODOT_EXE` 环境变量、本地 `tools/godot-4.7.2/` 中的引擎，以及PATH中的 `godot`。`GODOT_EXE` 填写Godot 4.7.2可执行文件的完整路径，不包含额外引号。

默认场景为40羊、4狼和2犬。右侧场景面板可以修改数量、布局、种子和牧场大小，再重置生成。

## 操作

| 操作 | 输入 |
| --- | --- |
| 选择动物 | V切换选择工具，然后左键点击 |
| 抓取与放下 | G切换抓取工具，左键拖动；右键或Esc取消 |
| 放置动物 | B切换放置工具，选择物种后左键放置 |
| 移动 / 缩放镜头 | 中键拖动 / 滚轮 |
| 跟随所选动物 / 总览 | F / Home |
| 暂停 / 单步 | Space / N |
| 重置场景 | R |
| 开关右侧面板 / 界面 | P / H |

地表绿色表示可用草量，进食后变浅，并随模拟时间恢复。角色检查器展示任务、目标与局部知识；目标线使用动物已观测的位置。暂停中的操作需要单步或继续模拟后生效。

## 实现与目录

个体行为树决定策略，集中运动系统执行意图，交互系统统一结算捕食、吃草与生命周期。单个后台线程拥有模拟世界，主线程负责输入和显示。GPU执行批量运动数值计算与图集动画采样，CPU保留行为树、身份校验和交互结算。

| 路径 | 内容 |
| --- | --- |
| `game/scenes/main.tscn`、`game/scripts/main.gd` | 场景和系统组合入口 |
| `game/ai/trees/`、`game/scripts/ai/` | 三类行为树、感知、调度与协作 |
| `game/scripts/simulation/` | 数据、身份、运动、交互与发布 |
| `game/scripts/presentation/`、`game/scenes/ui/` | 批量表现与观察界面 |
| `game/assets/` | 可直接运行的图集和元数据 |
| `assets/art/` | 当前美术的可编辑源文件与导出帧 |
| `game/tests/` | 模拟、行为、线程与表现回归 |
| `tools/build_runtime_atlas.py` | 从导出帧重建运行图集 |

显示帧率与模拟推进速度分别计量：高压力下界面仍可响应，模拟可能减速。软分离允许拥挤时重叠；场景没有障碍物导航。当前只验证Windows x64，仓库不附其他平台的插件二进制。

## 构建与验证

在PowerShell中从仓库根目录执行，替换示例中的引擎路径：

```powershell
$godot = 'C:/Tools/Godot-4.7.2/Godot_v4.7.2-stable_win64_console.exe'
& $godot --headless --path game --editor --import --quit
& $godot --headless --path game --script res://tests/simulation_tests.gd
& $godot --headless --path game --script res://tests/dog_protection_tests.gd
```

GPU和图形回归需要实际图形设备，不使用 `--headless`。导出Windows程序前，在Godot中安装匹配版本的导出模板，再执行：

```powershell
New-Item -ItemType Directory -Force build/windows | Out-Null
& $godot --headless --path game --export-release 'Windows Desktop' ../build/windows/Sheep.exe
```

运行导出程序时，保持EXE、PCK和LimboAI DLL在同一目录。导入、导出和图形测试按顺序运行。

仅在编辑素材后才需要重建图集：安装Python和Pillow，执行 `python tools/build_runtime_atlas.py`。素材组织和编辑说明见 [assets/art/README.md](assets/art/README.md)。

## 来源与许可

代码采用 [MIT](LICENSE)。Godot、LimboAI和插件标识的许可及美术来源见 [THIRD-PARTY.md](THIRD-PARTY.md)。
