# 彩虹渐变网格频谱外框

SRAM下载EG4_Neon.bit。进入RPG战斗后，外框采用参考图风格：连续渐变色块、细亮网格、暖粉色内沿，替代之前的碎小频谱柱。

实际FFT控制各段亮度和内侧光带；静音后回到低亮彩框。没有按定时器乱跳，颜色位置固定渐变。生命条、文字和怪物内容区不变，长K1旋转／长K2镜像／长K3声音开关保留，播放器缩放缓存不改。

frame_preview.png是实际RTL公开RGB生成的代表性游戏测试画面，不是板上截图。新边框仍占原16逻辑像素，不加宽盖住内容。

原GUI已重新综合并HIGH布线完成，内部时钟和5个CDC组0setup/hold错，37源码一致。路由LUT17193/19600、DSP20/29、RAM9K48/64、32K16/16、PLL2/4。未自动FPGA下载／Flash，实际显示器色彩待上板。

BIT759995B，SHA25692bf9099781efe313a1755297a185db079aae4e36ffe4f4a9b86ca3d27cddb14，与当前D:/jingsai/EG4_Runs/phy_1/EG4.bit相同。旧build/spectrum仍可回退。

完整说明：项目docs/彩虹网格频谱外框.md。当前视觉回归：tools/verify_neon_frame.py；预览加--preview-only。release_validation.json、source_sha256.json及preserved_inputs.json记录构建与保留内容。
