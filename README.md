# 云·终末地 Android 云端启动验证

第一阶段只验证以下闭环：

1. GitHub Actions 启动 Android 11 模拟器；
2. 从鹰角官方“最新版”入口下载《云·终末地》Android 客户端；
3. 安装 `com.hypergryph.cloud.endfield`；
4. 启动官方入口 Activity；
5. 等待 45 秒后确认应用进程仍然存活；
6. 上传截图、logcat、安装信息和设备信息。

## 运行方式

1. 将本目录提交到 GitHub 仓库；
2. 打开仓库的 **Actions** 页面；
3. 选择 **Cloud Endfield Android smoke test**；
4. 点击 **Run workflow**；
5. 运行结束后下载 `endfield-cloud-smoke-*` artifact 查看结果。

出现 `success.txt` 且任务为绿色，表示客户端完成安装、启动并持续存活。
`screenshot.png` 用于确认实际画面。失败时优先查看：

- `install.txt`：APK 安装与 ABI 兼容问题；
- `launch.txt`：Activity 启动结果；
- `logcat.txt`：闪退、原生库和图形/媒体错误；
- `runner.txt`：GitHub runner 与 KVM 状态。

## 安装包来源

工作流不会提交或缓存 APK。每次运行都请求鹰角的稳定最新版入口：

```text
https://launcher.hypergryph.com/game/latest/EjOB8xSdBmtLnzCX/1/1
```

该入口会重定向到带短期签名的官方 CDN 地址，因此不要把最终 CDN URL
写死在工作流中。

## 当前边界

本阶段不进行账号登录、扫码、游玩或 MAA 自动化。客户端 APK 只包含 ARM
原生库，本验证依赖 Android 11 Google APIs x86_64 系统镜像提供的 ARM
兼容能力；能否成功正是本次实验需要回答的问题。
