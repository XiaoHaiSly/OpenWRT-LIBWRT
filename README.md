# 目录简要说明

workflows——自定义CI配置

Scripts——自定义脚本

Config——自定义配置

# 自建软件源（feed）

固件编译的同时，另起一个 `feed` 任务，把 `Config/PACKAGES.txt` 里的插件和**全部内核模块**编成 apk，
只推送到 Cloudflare Pages（固件 Release 和之前完全一样，不多发任何文件），固件里已写好软件源地址。

## 一次性设置

1. 打开 `Scripts/Feed.sh`，把顶部的 `FEED_HOST` 改成你的域名，例如 `openwrt-feed.pages.dev`
   （项目需在 Cloudflare 提前建好，项目名取域名第一段）。
2. 仓库 Settings → Secrets and variables → Actions → Secrets 添加
   `CLOUDFLARE_ACCOUNT_ID`、`CLOUDFLARE_API_TOKEN`（权限：Cloudflare Pages Edit）。

`FEED_HOST` 没改：不推送，固件里也不写软件源。

## 日常使用

- 改 `Config/PACKAGES.txt` 即可，写法见文件头注释：`=m/=y` 都只编译不进固件，`=n` 不编译，
  只写包名也行，`CONFIG_NODEJS_26=y` 这类非插件选项原样写入。
- 设备上 `apk update && apk add luci-app-xxx` 直接装，固件已带 `/etc/apk/repositories.d/customfeeds.list`。
- 老固件手动加源：
  ```
  A=aarch64_cortex-a53; S=ipq60xx; U=https://项目名.pages.dev
  printf '%s\n%s\n' $U/packages/$A/packages.adb $U/kmods/$S/packages.adb >> /etc/apk/repositories.d/customfeeds.list
  ```

## 路径

```
/packages/<架构>/packages.adb      PACKAGES.txt 里的插件（及依赖）
/kmods/<子平台>/packages.adb       全部内核模块，ipq60xx / ipq807x 各一份
```

## 关键设计

- **固件和软件源必须同一内核**：kmod 依赖内核的 vermagic，而 vermagic 由选中的内核模块集合决定。
  所以固件（GENERAL.txt）和软件源都开 `CONFIG_ALL_KMODS=m`，发布前 `publish` 任务会逐平台比对，不一致就不发布。
- **用户态插件只编一份**：同架构通用，LIBWRT.yml 里只有 `FEED_USER: true` 的平台编译；其余平台只出 kmod。
- **只收 `=m` 的包**：固件默认的 `y` 核心包不会进软件源，避免覆盖固件里的组件。
- **单个插件编译失败不影响整体**（`IGNORE_ERRORS=m`），失败的包在软件源里缺席。
- **只在全部平台成功后才发布**，任何一个平台失败，旧软件源保持不变。
- apk 免验签沿用 `Scripts/apk-tools.sh` 的补丁，所以不需要配置签名密钥。

## 注意

- 软件源只跟随“最新固件”：内核升级后，旧固件会装不上新的 kmod（apk 会明确报依赖不满足），刷新固件即可。
- Cloudflare Pages 单文件上限 25MiB、单次部署 2 万文件，超限的大文件会被跳过。
- 首次编译慢（要编全部 kmod 和插件，有缓存后会快很多）；单任务上限 6 小时，插件太重时先注释掉几个。
