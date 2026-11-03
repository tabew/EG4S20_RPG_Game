# 上下张加速版

优先SRAM下载EG4_FastHigh.bit，保持现有640×48024bitBMP、分离器与音箱接线。

- 首次访问：SPI12.5MHz，线级仿真相对6.25MHz加速1.9409倍，实际卡仍需测量。
- 缓存命中：最近四幅完整RGB888留在8MiB SDRAM，不重读TF；采样时序模型最大确认16.350ms。
- 连续K1/K2：保留最新目标，加载中不再丢按键；手动选图会暂停自动播放，K3恢复。
- 已经消除竖线的SDRAM控制器及异步FIFO源码保持一致，HDMI48k/1kHz测试音和RPG保留。

验证方式：先让A显示，K2首次加载B；B完成后K1回A、K2回B，观察缓存命中区别。再连续访问四幅确认颜色/无竖线。新的实际速度与稳定性待用户上板确认，不自动烧Flash。

实际可重建工程：D:/jingsai/EG4_FastHigh/EG4_FastHigh.al。请在TD打开新工程，窗口标题应EG4_FastHigh；旧D:/jingsai/EG4.al仍保留。新工程由TD原生保存HIGH路线配置，已实际执行rebuild_full.cmd完成综合→布局→布线→码流返回0，无PHY8023/RUN8102。该目录也有一键重建脚本和完整日志。

完整说明：项目docs/上下张加速与高强度工程.md。

BIT756503字节，SHA25690bc5aa20d792f125d3f47911da49322fc605ad3466639682b4892be87353741。

同目录release_validation.json核对37源、三内部逻辑时钟及4CDC组零错误；gui_project_validation.json记录实际工程。路由LUT15395/19600，reg5747，RAM9k45/64+32k16/16，DSP17/29，PLL2/4。外部器件IO与新加速体验仍需实物，不用参考/转发时钟0端点替代器件时序证明。
