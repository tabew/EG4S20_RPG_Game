# HDMI背景音乐与效果音版

本版把HDMI持续1kHz测试音替换为现有PSG混音：背景旋律、RPG事件音效和图片切换双音提示都会从HDMI分离器输出。现有640×480原图、四帧缓存、12.5MHz读图和1×/2×/4×中心缩放保留。

## 使用方式

SRAM下载 `build/music/EG4_Music.bit`。原TF图片素材、HDMI分离器供电和3.5mm音箱接线不变，不需要额外的音乐文件。

- 默认声音开启，播放现有合成背景曲，不再持续发固定测试音。
- 长按K3约1.2秒：全局声音关／开，包含背景曲和效果音；松开不会再产生短按。
- 普通界面短按K3：图片暂停／恢复自动轮播，不控制声音。手动K1/K2后短K3即可重新自动播放。
- 设置页短按K3：1×／2×／4×缩放；长K3仍只管声音。
- 图片完成切换后有对应提示音；RPG原有操作／战斗事件触发相应效果音。

序列模式沿用节奏曲，图库用探索曲；RPG沿用探索、战斗、结局的场景选曲。声音来自工程原有三首合成旋律，并非WAV/MP3播放器。开机短提示属于事件音效，不是原来的持续测试音。

## 音频接法和实现

原来PSG只连接R-2R/PWM，HDMI在自身编码器中产生测试正弦。现在顶层明确选择 `AUDIO_PCM_EN=1`，将真实 `snd_dac` 混音接入HDMI；编码器继续使用48kHz采样节拍、原ACR、Audio InfoFrame、IEC60958、BCH和原厂串行器。

原PSG按约32kHz更新8位混音，音高ROM和音效时长保持不变。HDMI在像素域以48kHz采集保持的混音，避免直接把PSG采样率改成48kHz而造成音高和时长变化。转换为有符号16位 `(dac-128)*64`，再左对齐到24位LPCM容器。左右声道相同，不是独立立体声。原始合成有效精度仍是8位，不宣称24位音质。幅度峰值约±7680，处于原测试音幅度附近。

CEA640×480使用25.2MHz像素时钟，采样间隔525拍，N6144/CTS25200。所有音频逻辑同属像素时钟域，没有新增异步音频接口。静音后少量已经排队的样本会先输出，随后为数字零；恢复播放继续采集音乐，不切回测试音。

原来的1kHz发生器只保留在PCM关闭的诊断默认参数中，用于兼容旧独立验证；生产top固定启用真实PCM，综合会消除不可观察的测试音路径。原PWM、蜂鸣器和音高包络彩条继续使用同一混音。

## 验证和范围

- 25.2MHz外部PCM独立TMDS解码：4200包、1599立体声样本／1600采样；525拍间隔；966静音零值、533恢复样本、2个已排队的静音前样本，溢出0。
- 40MHz兼容验证：5024包、1591样本；833/834拍间隔；961静音、530恢复，溢出0。
- 两种模式均独立核对TERC4、包头／子包BCH、符号与填零、双声道状态和各自奇偶校验、ACR及InfoFrame。输入覆盖有符号极值和非1kHz变化序列，接收样本与发送前输入逐个一致。
- PCM和诊断音参考编码器逐周期视频／控制符号、HS/VS/DE及RGB相同，原两种时钟的测试音兼容回归仍通过。
- 真实三首ROM曲目均有非零波形、音符变化且轨道输出不同；RPG两类事件、图片双音提示相对纯背景曲改变样本，结束后回到背景曲。该快速组件用加速BPM测试音符推进，不冒充默认120BPM的实物录音。
- 原手动导航、暂停／恢复、缩放按键、模拟静音PWM和视频顶层回归通过。

新固件已经实际完成TD5.6综合、HIGH布局布线和码流生成，37源输入与冻结快照一致。三个内部逻辑时钟和5个CDC数据组无setup/hold错误，资源15605/19600 LUT、5809reg、9K RAM45/64、32K RAM16/16、DSP17/29、PLL2/4。参考／转发时钟没有端点不等于外部器件时序证明。

**实物边界**：没有自动下载FPGA或写Flash。新的音乐、音效音量与分离器实际听感仍需上板确认。先用SRAM，测试长K3静音／恢复、普通短K3手动转自动、缩放下切图及RPG事件声，再考虑Flash固化。

## 构建和回归

独立新工程为 `D:/jingsai/EG4_Music/EG4_Music.al`，HIGH已保存。源码在当前仓库，原BGM／img_chime／按键／SDRAM控制逻辑没有因此改写。

```powershell
python tools/verify_hdmi_pcm.py
python tools/verify_hdmi_music_system.py --case effects
python tools/verify_hdmi_music_system.py --case top
python tools/verify_hdmi_profiles.py
python tools/verify_basic_release.py --build sim/sd/out/td_music_release --outputs D:/jingsai/EG4_Music --report-prefix EG4_Music --firmware-stem EG4_Music --cea --zoom --require-bit
```

主源冻结证据：sim/sd/out/td_music_release。PCM包证据：sim/hdmi_audio/pcm_results/verification.json。音乐与效果音组件证据：sim/sd/out/hdmi_music_system。旧缩放／固定测试音固件保留在build/zoom。

主码流756503字节，SHA256：5ed90d25fbee236978620f4e6d61bf90bc8eb5aa2658b457d7a43ad878e73e20。

原GUI工程也已从syn_1重新综合，再运行HIGH phy_1，正常下载路径D:/jingsai/EG4_Runs/phy_1/EG4.bit已经更新为音乐版（SHA501d2f20efec475ad330e4f5babb84366c4efd5f97fc4fdefb13a2e837746b8f）。它与独立音乐工程使用相同37输入，但不宣称两个.bit字节相同。日志明确elaborate AUDIO_PCM_EN=1/PCM_INPUT_EN=1，不是旧综合数据库。

rebuild_gui_phy_high.cmd调用的launch_actual_phy.tcl现已先reset/launch/wait syn_1，再重跑phy_1，避免仅重布线仍拿到旧测试音。原输出已备份到D:/jingsai/EG4_before_music_20261101，未烧写硬件。之前的交接压缩包早于本次更新，不会自动包含新音乐功能。
