// 自动通关测试: 检查 HTML 引擎的游戏流程能否走完 5 个区域
const fs = require("fs");
const html = fs.readFileSync("rpg_player.html", "utf8");
const code = html.match(/<script>([\s\S]*)<\/script>/)[1];
global.document = { getElementById: () => null, addEventListener: () => {} };
global.window = global;

const extra = `
;(function () {
  initGame();
  press(0);            // 标题 -> 选职业
  press(0);            // 选剑士 -> 地图
  let steps = 0, battles = 0, deaths = 0;
  const seen = {};
  while (G.scene !== 6 && steps++ < 4000) {
    seen[G.scene] = (seen[G.scene] || 0) + 1;
    if (G.scene === 2) {                       // 地图
      if (G.bossDead)          press(3);       // 已击败首领 -> 下一区
      else if (G.kills >= 4) { press(3); battles++; }
      else                   { press(0); battles++; }
    } else if (G.scene === 3) {                // 战斗
      if (G.hp < G.maxhp * 0.4 && (G.pot > 0 || G.potxl > 0)) press(2);
      else if (G.mp >= [10, 14, 12][G.cls]) press(1);
      else press(0);
    } else if (G.scene === 4) {                // 商店: 先花钱再离开
      if (G.gold >= 100)      press(2);
      else if (G.gold >= 48)  press(1);
      else                    press(3);
    } else if (G.scene === 5) {                // 死亡 -> 复活
      deaths++; press(0);
    } else if (G.scene === 1) {
      press(0);
    } else break;
  }
  console.log("结果: " + (G.scene === 6 ? "通关 ✔" : "未通关 ✘") +
              "  区域 " + (G.area + 1) + "  Lv" + G.lv +
              "  战斗 " + battles + "  死亡 " + deaths + "  步数 " + steps);
  console.log("场景访问次数:", JSON.stringify(seen));
})();
`;
try { eval(code + extra); }
catch (e) { console.log("JS 异常:", e.message); }
