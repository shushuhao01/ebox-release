# eBox 发行仓库

本仓库是 eBox 客户端的**公开发行产物仓库**，不含任何源码。

- `dist/update.json`：客户端自动更新清单（主源为 https://abc222.cn/download/update.json，本文件供 jsDelivr / raw.githubusercontent 兜底）
- Releases：各版本安装包 `eBox.exe`（tag 与版本号一致，如 `v3.3.3`）

由私有源码仓库的发布流水线（`.github/workflows/auto-update.yml`）在每次发布 Release 后自动同步，请勿手工修改。