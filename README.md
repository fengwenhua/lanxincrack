# lanxincrack

一个基于 Theos/Logos 的蓝信 Tweak 项目。

受不了叼毛蓝信，竟然不允许我的手机越狱，必须gan它一手。

## 当前实现功能

1. 越狱检测绕过。
2. 消息防撤回。
3. 撤回角标（聊天气泡显示撤回标识 `[撤]`）。【本功能AI实现，只能勉强能用，有时候不显示角标，不过不影响防撤回功能，改天再用ai调一下】
4. 开屏页跳过（每次打开都有广告，受不了）。

<img width="345" height="688" alt="image" src="https://github.com/user-attachments/assets/f5cecfdf-a5a9-421a-81ad-d9413a064733" />


## 目录说明

- `Tweak.x`：核心 Hook 与逻辑实现。
- `Makefile`：Theos 构建配置。
- `package.sh`：推荐的构建打包脚本（会注入构建时间版本号）。
- `control`：Deb 包元数据。
- `packages/`：构建产物目录。

## 编译与打包

推荐方式：

```bash
./package.sh
```

成功后会在 `packages/` 生成 deb，例如：

```text
packages/com.lanxin.crack_0.0.1+<BUILD_ID>_iphoneos-arm64.deb
```

## 日志与排查

可用下面命令快速看关键日志：

```bash
cd /var/mobile/Containers/Data/Application/
find . -name "lanxincrack.buildid"
```

比如我的如下：

```
./F9355858-C5A0-4A2C-9E67-88BDDA464A1B/Library/Caches/lanxincrack.buildid
```

```bash
cat /var/mobile/Containers/Data/Application/F9355858-C5A0-4A2C-9E67-88BDDA464A1B/Library/Caches/lanxincrack.buildid
```

我的如下：

```
20260508233555
primary=/var/mobile/Containers/Data/Application/F9355858-C5A0-4A2C-9E67-88BDDA464A1B/Library/Caches/lanxincrack.20260508233555.log
fallback=/private/var/mobile/Containers/Data/Application/F9355858-C5A0-4A2C-9E67-88BDDA464A1B/tmp/lanxincrack.20260508233555.log
```

记住 primary 日志路径，后续排查时可用。

```bash
tail -n 2000 /var/mobile/Containers/Data/Application/F9355858-C5A0-4A2C-9E67-88BDDA464A1B/Library/Caches/lanxincrack.20260508233555.log | grep -E "\[LXBUILD\]|chat badge|setMsgState remap|IMTextMessage.text patch|recalled="
```
