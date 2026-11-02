# Original TD project reference

`EG4.al` and `al_ip/` are reference copies of the project used for the 2026-11-02 local build. The original project was stored at `D:/jingsai/EG4.al` and references source files under `D:/EG4S20_RPG_Game-main`. This reference copy is not a relocatable, independently verified project: opening it from this repository requires adapting the project paths and the tool installation.

Several ROM initialization paths in `rtl/` also point to `D:/EG4S20_RPG_Game-main/rtl/gen`. Update those paths for another checkout before synthesis. Preserve the ROM data and re-run simulation, synthesis, routing, and timing verification after any relocation.

The documented build used Anlogic Tang Dynasty 5.6.71036, EG4S20BG256, and HIGH routing effort. Its bitstream and local test reports are not proof of operation on another board. Anlogic encrypted IP and generated IP remain subject to their own vendor terms; the root MIT license should not be interpreted as relicensing them.
