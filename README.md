# hakimi-mc-server

部署于境内宿主机 `/opt/hakimi-mc-server/` 的 Paper 服务端编排与运维脚本集合，配合独立仓库 `FireOpalus/hakimi-mc-agent` 实现按需唤醒、无人自动休眠与定时世界备份。

## 组件说明

- `mc-powerd.py`：零外部依赖受控 HTTP 守护进程，仅监听私网桥接 IP（拒绝 `0.0.0.0`），提供 `/status`、`/start`、`/stop`（Bearer 鉴权）、可用内存闸门与无人闲置自动休眠。
- `compose.yaml`：Paper 服务端容器编排模板（默认通过 `MC_SERVER_PORT` 暴露游戏端口，加入 `hakimi-node-agent_hakimi_cn_net` 私网供 `mc-agent` 内网直连）。
- `mc-ctl.sh` / `mc-cmd.sh` / `backup.sh` / `mc-chunky.sh` / `mc-friend.sh` / `mc-skin.sh`：启停检查、RCON 命令、在线安全刷盘备份、区块预生成、好友白名单与 SkinsRestorer 皮肤管理脚本。

## 皮肤功能（SkinsRestorer）

服务端内置 Paper 插件 **SkinsRestorer**（`data/plugins/SkinsRestorer.jar`，零客户端 Mod 依赖）：

- **游戏内指令**（白名单内全部玩家可用）：
  - `/skin <正版玩家名>`：切换为指定 Mojang 正版皮肤
  - `/skin url <图片直链> [slim|classic]`：通过 PNG 直链换肤
  - `/skin set <自定义皮肤名>`：应用服内已注册的自定义皮肤
  - `/skin clear` / `/skins`：恢复默认皮肤或打开可视化皮肤菜单
- **宿主机运维脚本**（`mc-skin.sh`，开服/关服离线状态均可操作）：
  - `mc-skin.sh status` / `mc-skin.sh list`：查看插件配置、自定义皮肤库与玩家绑定
  - `mc-skin.sh upload <皮肤名> <本地.png> [--variant slim|classic] [--apply <玩家名>]`：本地 64×64 PNG 经 MineSkin 签名后永久写入服内自定义皮肤库，并可选立刻绑定给指定玩家
  - `mc-skin.sh create-url <皮肤名> <图片URL> [--variant slim|classic] [--apply <玩家名>]`：通过 URL 创建永久自定义皮肤
  - `mc-skin.sh set <玩家名> <自定义皮肤名|正版玩家名|URL>` / `mc-skin.sh clear <玩家名>` / `mc-skin.sh delete <皮肤名>`：绑定、清除或删除皮肤
- `backup.sh` 已自动包含 `plugins/SkinsRestorer`，定时备份会一并保存自定义皮肤与绑定记录。

## 配置与部署

1. 复制 `.env.powerd.example` 至 `/opt/hakimi-mc-server/.env.powerd`（`chmod 600`），填入强随机 `MC_POWERD_TOKEN`（与 `/opt/hakimi-node-agent/.env.mc` 保持一致）。
2. 安装 systemd 服务：`cp hakimi-mc-powerd.service.example /etc/systemd/system/hakimi-mc-powerd.service && systemctl daemon-reload && systemctl enable --now hakimi-mc-powerd.service`。
3. 运行 `mc-friend.sh` 时，可通过环境变量 `MC_SERVER_ADDR`（如 `example.com:25565`）与 `MC_PROTECTED_ACCOUNTS`（逗号分隔受保护玩家名）注入本机参数，勿将真实地址或密码写入仓库。
