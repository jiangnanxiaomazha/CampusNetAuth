# 校园网自动认证 Android 版

自动连接校园网 WiFi 并完成门户认证的 Android 应用。

## 功能
- 自动连接指定 WiFi（支持优先 5GHz/2.4GHz）
- 自动完成校园网门户认证
- 支持运营商选择（中国移动/联通/电信/校园内网）
- 一键检查更新

## 检查更新
APP 内填写更新地址（指向本仓库的 version.json），点击「检查更新」即可自动下载安装新版本。

version.json 格式：
\\\json
{
  "versionCode": 2,
  "versionName": "1.1",
  "apkUrl": "https://raw.githubusercontent.com/你的用户名/仓库名/main/CampusNetAuth-debug.apk",
  "changelog": "更新说明"
}
\\\

## 构建
用 Android Studio 打开项目，Build → Build APK。
