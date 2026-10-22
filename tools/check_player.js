// 用 Node 跑 HTML 里的游戏引擎(不碰 DOM), 导出三屏格子数据供比对
const fs = require("fs");
const html = fs.readFileSync("rpg_player.html", "utf8");
const m = html.match(/<script>([\s\S]*)<\/script>/);
if (!m) { console.log("找不到 script"); process.exit(1); }

// DOM 桩: getElementById 返回 null -> boot() 里会直接返回
global.document = { getElementById: () => null, addEventListener: () => {} };
global.window = global;

let code = m[1];
code += `
;(function(){
  const out = {};
  initGame();
  renderScene(); out.title = Array.from(cells);
  press(0);                 // TITLE -> CLASS
  renderScene(); out.cls = Array.from(cells);
  press(0);                 // CLASS -> MAP(剑士)
  renderScene(); out.map = Array.from(cells);
  out.state = {scene:G.scene, hp:G.hp, maxhp:G.maxhp, atk:G.atk, def:G.def, gold:G.gold, lv:G.lv};
  fs.writeFileSync("sim/player_cells.json", JSON.stringify(out));
  console.log("引擎输出: scene=" + G.scene + " hp=" + G.hp + " gold=" + G.gold);
})();
`;
eval(code);
