# HDMI背景音乐与效果音

SRAM下载本目录EG4_Music.bit，原TF图片和分离器/音箱接线不变，无需另加音乐文件。旧的持续1kHz测试音已在生产模式中替换为真实PSG混音：背景曲、RPG事件音、图片切换双音。

- 长K3：声音开/关，播放器/设置/RPG通用。
- 普通短K3：图片暂停/恢复自动；K1/K2手动切图后按它回自动，音乐不因图片暂停而停止。
- 设置短K3：1×/2×/4×缩放。缩放和四帧缓存均保留。

现有三首合成曲按场景选择。HDMI48kHz采集原有约32kHz、8位PSG保持样本，转换有符号PCM并装入24位LPCM容器，左右同音。未声称24位源音质，未变更原音高/效果音时长。

已验证独立TMDS/PCM解码、三首ROM旋律与事件效果、实际顶层音乐采样、长短K3隔离、视频时序；独立音乐工程及原GUI从综合至HIGH布线/bitgen均通过。新实际听感仍需上板；没有自动下载或写Flash。

主.bit756503B，SHA2565ed90d25fbee236978620f4e6d61bf90bc8eb5aa2658b457d7a43ad878e73e20。
原GUI D:/jingsai/EG4_Runs/phy_1/EG4.bit也已更新为音乐版，SHA501d2f20efec475ad330e4f5babb84366c4efd5f97fc4fdefb13a2e837746b8f。
新独立工程D:/jingsai/EG4_Music/EG4_Music.al；同目录rebuild_full.cmd可重建。原GUI一键重建也已改为先重新综合，再跑物理实现，避免旧测试音数据库。

完整说明：项目docs/HDMI背景音乐与效果音.md。验证材料：release_validation.json、gui_release_validation.json、pcm_verification.json、music_top.json、music_effects.json及日志。旧版build/zoom保留作回退。
