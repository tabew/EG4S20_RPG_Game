# SDRAM完整RGB888缩放与长按K3声音控制

本次补回的是实际SDRAM原始图像缩放。旧256×192缩略图仍只保留兼容代码；当前640×480、24位图像不被改写或重新量化。1×、2×、4×均从四帧缓存中的原始RGB888读取，并在垂直消隐统一切换图像银行与比例。

## 现在下载哪个文件

SRAM下载 `build/zoom/EG4_Zoom.bit`。现有640×480、24bit BI_RGB素材、TF卡和分离器/音箱接线保持不变。旧加速版 `build/fast_switch/EG4_FastHigh.bit` 留作回退，不覆盖。

源码重建打开 `D:/jingsai/EG4_Zoom/EG4_Zoom.al`，使用本工程持久化的HIGH布线。也可以运行同目录 `rebuild_full.cmd`。旧工程的历史固件和交接包仍描述当时版本，本次新功能以此说明及新源码/固件为准。

## 按键

| 场景 | K3短按并松开 | K3长按约1.2秒 |
|---|---|---|
| 普通播放器 | 图片暂停／恢复 | 声音关／开 |
| 设置页 | 缩放1×→2×→4×→1× | 声音关／开，不切缩放 |
| RPG | 原游戏短按功能 | 全局声音关／开 |

长按释放不会再产生短按动作。音乐彩条继续由长按K2开关，设置K3不再承担彩条功能。现有HDMI音频源仍是48kHz采样的1kHz测试音，原PSG/PWM和已有换图音代码保留；本轮没有把游戏曲目改成HDMI背景音乐。

## 实物检查步骤

1. 下载新.bit，复位并等首图显示。
2. 如需观察固定图，普通界面短K3暂停；然后长K4进入设置。
3. 设置页短K3一次：HUD应从FULL640变2XCENTER，显示图片中心放大两倍。
4. 再短K3：显示4XCENTER，中心继续放大；再按恢复完整原图。
5. 长K3验证声音关／开，比例和AUTO/PAUSED不应因此变化。长按后松开也不应再跳一档缩放。
6. 退出设置，在2×或4×下K1/K2切图，检查换图、缓存和自动轮播仍正常，尤其首尾像素、重复竖线与闪烁。

缩放在下一个帧边界生效，最多约一帧调度延迟；不需要重新读取TF，也不破坏四帧缓存。HUD使用实际已生效比例，避免标签与画面在帧内不一致。

## 缩放映射

| 比例 | 从原图读取的中心区域 | 640×480输出像素映射 |
|---|---|---|
| 1× | x0..639，y0..479 | source=(x,y) |
| 2× | x160..479，y120..359 | source=(160+floor(x/2),120+floor(y/2)) |
| 4× | x240..399，y180..299 | source=(240+floor(x/4),180+floor(y/4)) |

这是整数最近邻放大，适合当前像素画。每个源像素重复为2×2或4×4，放大后可看到原像素块是正常效果。当前没有平移、任意比例、插值或缩小功能。

源域按输出行重新读取对应裁剪行，横向每2/4像素取一次FIFO数据，其余输出保留同一RGB888值。部分行尾突发为64或32字，全部实际SDRAM控制器接口不变；没有增加整行BRAM，也没有改已经消除竖线的下降沿SDRAM输出时序。模式通过按帧保持的两位载荷和epoch握手跨域；max30ns/min0约束两位都实际匹配并通过。

## 已完成验证

- 实际生产控制器、50MHz内存、+5ns PHY和独立SDRAM存储/时序模型；25.2MHz和5MHz像素时钟各6个完整帧，总3,686,400个输出RGB888逐像素比对。
- 1×/2×/4×源地址、首尾像素、128/64/32字突发、重复行、请求间断、最后源像素取空后仍可输出重复像素等检查通过，无正常读空。
- 帧中请求比例变化只在下一blank生效；缓存银行和缩放同拍换帧、后台实际写入后终止、整帧无请求、FIFO残留清除通过。
- 原四帧缓存回归通过：四次完整上传、28个完整RGB帧、12次无写入命中。原TF/FIFO/SDRAM控制器模块未改变。
- 真实原始按键映射与消抖：26次短K3、20次长K3，含普通界面／设置／RPG、不同缩放及长按释放不误触短按。
- 全部10组视频/HUD回归、原导航／暂停／真实按键，以及既有音频和HDMI顶层检查通过。
- 实际TD5.6.71036：综合、HIGH布局布线、生成位流完成；37源输入与快照一致。路由后LUT16054/19600、寄存器5995、9K RAM45/64、32K RAM16/16、DSP17/29、PLL2/4。
- 内部3逻辑时钟和5个CDC数据组均0setup/hold违例。新增缩放载荷2端点/2路径，30ns上限内最慢1.363ns。整体最差setup余量5.394ns、hold0.088ns。

**验证边界**：完整帧读回检查对原始存储模型预载不同银行的已知图像，真实控制器读取仍完整执行；完整写入另由缓存回归覆盖。参考／转发时钟没有寄存器端点不等于外部dieIO独立STA证明。新缩放版没有由AI自动下载或写Flash；板上实际放大与稳定性仍需上述步骤验收。

## 文件与复现

主.bit：756503字节，SHA256 `6a673064711d3867c522e13036aed62184e35b648d0bc82b4b6a8837285c6052`。

构建快照 `sim/sd/out/td_zoom_release/`，原生结果 `D:/jingsai/EG4_Zoom/`。同交付目录保留release_validation.json、source_sha256.json、资源与时序报告及关键回归日志。

```powershell
python sim/sdram/run_zoom.py 25
python sim/sdram/run_zoom.py 5
python sim/sdram/run_zoom.py epoch
python sim/sdram/run_zoom.py legacy
python tools/verify_media.py --case media_zoom_key --case media_navigation --case media_pause_key
python tools/verify_media_video.py
python tools/verify_basic_release.py --build sim/sd/out/td_zoom_release --outputs D:/jingsai/EG4_Zoom --report-prefix EG4_Zoom --firmware-stem EG4_Zoom --cea --zoom --require-bit
```

原始工作树和换图音代码在修改前保存在build/pre_zoom_source。交接包是在本次缩放实现之前生成的，不会自动包含本次新改动。
