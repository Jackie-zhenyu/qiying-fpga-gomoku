# 精选RTL仿真测试

这些testbench从项目开发目录精选，保留其原有断言和激励。原始运行日志、历史结果文件、旧源码副本和依赖个人Flash备份的运行器未收录。

新的 `run_unit_tests.py` 使用 `suites.json` 中的明确文件列表调用Icarus Verilog，只执行本地仿真。不会打开串口、调用TD、生成位流或写入板卡。配置存储测试中的Flash为SystemVerilog模型，地址和擦写行为不涉及真实硬件。

## 使用

安装Python 3.9+与Icarus Verilog，并将 `iverilog`、`vvp` 加入PATH。在仓库根目录执行：

```text
python tests/run_unit_tests.py --list
python tests/run_unit_tests.py voice
python tests/run_unit_tests.py settings
python tests/run_unit_tests.py config_store --timeout 600
```

可用 `--iverilog` 和 `--vvp` 指定已安装程序的路径。每次运行会新建 `build/tests/测试名-时间戳/`，保存编译、运行输出和结果；不覆盖旧结果。

| 测试名 | 主要范围 |
|---|---|
| `voice` | 串口帧解析、口令和播报ID、生命周期 |
| `settings` | 设置状态与配置更新 |
| `spi_owner` | SPI资源归属切换 |
| `config_store` | 配置双副本、CRC、提交顺序与恢复 |
| `config_commit` | 提交过程中的中断模拟 |
| `config_faults` | 忙超时和写入校验故障 |
| `config_owner` | 配置与棋谱存储共享SPI的互斥 |
| `actions`、`actions_voice` | 交互动作及语音事件衔接 |
| `controls`、`menu` | 交互状态和菜单操作 |

## 验证范围

本次发布整理未重新运行仿真；仅检查了列出文件均存在、Python入口语法，以及源码和资料的发布范围。因此这里没有附加当前发布快照的测试通过徽章或成功日志。运行结果应以实际产生的 `result.json` 为准，不能用叶级测试代替整机时序或物理验收。
