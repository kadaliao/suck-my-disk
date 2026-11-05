<!-- English or Chinese, either is fine. / 用中文或英文都可以。 -->

## What changed / 改了什么



## How it was tested / 怎么测试的

<!-- swift test, smd dry runs (without --yes), screenshots of the app… / swift test、smd 预演（不加 --yes）、App 截图…… -->

## Checklist / 检查清单

- [ ] `swift test` passes, and the app builds / `swift test` 通过，App 能编译
- [ ] User-facing text has both languages: `L("中文", "English")` / 界面文字中英都有
- [ ] Docs updated in both `*.md` and `*.zh-CN.md` (or noted below which one is missing) / 文档中英两份都已更新（或在下面注明缺哪份）
- [ ] `CHANGELOG.md` and `CHANGELOG.zh-CN.md` updated under *Unreleased*, if users would notice / 用户能感知的改动已写进两份 CHANGELOG 的「未发布」

**If this changes what is listed, preselected or deleted / 如果改动了列出、预选或删除的内容：**

- [ ] Deletion goes only through `Executor`; `Guards` are not weakened / 删除只经过 `Executor`，没有放松 `Guards`
- [ ] Preselected only with strong evidence; restore command and reason given / 只在证据充分时预选，并写了恢复命令和原因
- [ ] Shared data (clones, hard links) is accounted for / 考虑了克隆和硬链接共享的数据
- [ ] Privacy-prompting folders are skipped without Full Disk Access / 没有完全磁盘访问时跳过了会弹隐私提示的文件夹
- [ ] Tests cover what is found, preselected and left alone / 测试覆盖了会找到什么、预选什么、不碰什么
- [ ] `SNAP_MAGIC` bumped if the index format changed / 索引格式变了的话已更新 `SNAP_MAGIC`
