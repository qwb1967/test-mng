---
name: git-flow
description: test-mng 仓库分支管理、commit、push、合并发布的操作指南。涵盖两类仓库：(1) 根目录 test-mng（个人 GitHub 仓库，简单直 push main）、(2) 子目录 test-mng-service / test-mng-web（团队 Codeup 仓库，严格 Git-Flow：feature/工单号 → develop → release → master）。用户提到"建分支 / 提交 / push / 合并 / 发 dev|fat|uat / 线上修复 / 工单 ASAIO-xxx"时触发。
---

# git-flow — test-mng 分支管理 & 提交 & 发布操作指南

## ⚠️ 第一步：先判断是哪个仓库

test-mng 目录下有**三个独立 git 仓库**，规范完全不同。**做任何 git 操作前先判断**：

| 仓库 | `.git` 位置 | 托管 | 流程 |
|------|------------|------|------|
| **根目录 `test-mng`**（个人） | `test-mng/.git` | **GitHub** `qwb1967/test-mng` | 简单：直接 commit + push `main`，**不挂工单、不建分支、不走 develop/release** |
| **`test-mng-service`**（团队后端） | `test-mng-service/.git` | **Codeup** | 严格 **Git-Flow**：见下文（feature/工单号 → develop → release → master）|
| **`test-mng-web`**（团队前端） | `test-mng-web/.git` | **Codeup** | 严格 **Git-Flow**：同上 |

**判断方式**：

```bash
# 看用户改动的文件路径在哪个仓库下
# 改 CLAUDE.md / .claude/skills/* / docs/* / script/*  → 根目录仓库（个人）
# 改 test-mng-service/**  → 团队后端仓库（Codeup）
# 改 test-mng-web/**       → 团队前端仓库（Codeup）

# 验证：
git -C <仓库根> remote -v   # github.com → 个人；codeup → 团队
```

> ⚠️ **不要混淆**：根目录的 `CLAUDE.md` / `.claude/` 是个人仓库的；`test-mng-service/CLAUDE.md`、`test-mng-web/CLAUDE.md` 是团队仓库的（团队共享，**我们不改**）。

---

## 一、根目录 test-mng（个人 GitHub 仓库）

**用途**：维护我们自己的 CLAUDE.md、`.claude/` 下的 skills 与 scripts、docs/ 跨模块文档、script/ 启动脚本。

**规则（很简单）**：

- 分支：直接在 `main` 上工作
- 不挂工单号、不建 feature 分支
- commit message：简短中文 / `<type>: 说明` 即可，参考最近 commit 风格（`完善md` / `新增AGENTS.md` / `docs: 测试计划定时任务设计同步`）
- 直接 `git push origin main`，没人 review

**典型流程**：

```bash
cd /Users/qianwenbo/IdeaProjects/test-mng    # 仓库根（即 test-mng/）
git status                                    # 看改动
git add CLAUDE.md .claude/skills/xxx.md       # 按具体文件 add，不要 git add .
git commit -m "完善 CLAUDE.md xxx"
git push origin main
```

**注意事项**：

- **`.DS_Store`** 不要 add（macOS 系统文件，应忽略）
- 这个仓库**不追踪**子目录内容：`test-mng-service/` 和 `test-mng-web/` 在根仓库眼里是被忽略的（它们有自己的 `.git`）。所以改了子目录的文件，`git -C test-mng status` 看不到，要 `git -C test-mng-service status` 或 `git -C test-mng-web status`

---

## 二、团队仓库（test-mng-service / test-mng-web，Codeup）

> 📌 团队采用 **Git-Flow** 分支模型，配套云效工单。仓库托管在 **Codeup**（**不是** GitHub，`gh` CLI 不可用）。
> 📌 操作时务必先 `cd` 到对应子目录（或用 `git -C test-mng-service ...`）。

## 何时触发

用户出现以下意图时调用本 skill：

- "新需求开始开发了 / 帮我建个分支 / 拉 feature 分支"
- "这次 commit message 怎么写 / 帮我提交"（**先判断是哪个仓库**，根目录走简化流程）
- "把这个 push 上去 / 推到远端"
- "合并到 develop / release / master"
- "发 dev / fat / uat 环境怎么走"
- "线上出问题了，要 hotfix"
- "fat 上发现 bug 怎么改"
- 出现 `ASAIO-xxx` 这类云效工单号

## 分支模型一览

| 分支 | 用途 | 对应环境 | 命名 | 合入规则 |
|------|------|---------|------|---------|
| `feature/<工单ID>` | 单需求开发 | local | `feature/ASAIO-259` | 自测通过 → 合入 `develop`（需 Owner 评审）|
| `develop` | 开发集成 | **dev** | 固定名 | feature → develop **需 Owner 评审** |
| `release` | 版本发布 | **fat** | 固定名 | develop 自测通过 → 自行合入，**无需审核** |
| `bugfix/<工单ID>` | fat 上发现的 bug | fat | `bugfix/ASAIO-301` | 从 `release` 拉，修复后合回 `release`；简单 bug 也可直接在 release 上改 |
| `master` | 已发布基线 | **uat** | 固定名 | QA 通过 → **通知余晨**合入 |
| `hotfix/<工单ID>` | 线上严重缺陷临时修复 | 生产 | `hotfix/ASAIO-400` | **余晨**从 master 拉，修复后合回 `develop` 和 `master` |

🔁 流向：`feature` → `develop` → `release` → `master`；`hotfix` 旁路从 `master` 出，回到 `develop` + `master`。

## Commit Message 格式（强制）

```
<type>: #<云效工单ID> <一句话说明>
```

- **type**：`feat` / `fix` / `refactor` / `docs` / `test` / `chore` / `style` / `perf`
- **#工单号必填**，否则进 DEV 的代码会被打回（团队硬规则：进 DEV 分支必须挂需求卡片）
- 示例：
  - `feat: #ASAIO-259 将space和item转换为多对多的关系`
  - `fix: #ASAIO-301 修复用例列表分页越界`
  - `refactor: #ASAIO-310 拆分 ApiCaseService 的执行逻辑`

> ⚠️ 如果当前改动没有对应工单：**先停下来**，提示用户去云效申请补建一张需求卡片（只有 陈霁 / 扬帆 / 聂淮生 / 小杨 / 余晨 可以新建），不要随便编个工单号或省略。

## 各仓库 Owner（合 develop 时找谁评审）

| 仓库 | Owner |
|------|-------|
| `test-mng-service`（后端）| **余晨** |
| `test-mng-web`（前端）| **段忠志**、**余晨** |
| `test-mng-ai-service` | 刘淼、暴鹏程 |
| `testclaw` | 熊林涛 |
| `stress-mng` | 熊林涛 |

- `release` → `master` 由 **余晨** 操作；
- UAT 发布由 **聂淮生** 操作；
- Demo 发布只能由 **聂淮生** 操作。

## 标准开发流程（feature → dev → fat → uat）

```bash
# === 0. 前置：确认在正确的子仓库 ===
cd test-mng-service     # 或 test-mng-web
git status              # 根目录 git status 无效，必须进子目录

# === 1. 从 develop 拉 feature 分支 ===
git checkout develop
git pull origin develop
git checkout -b feature/ASAIO-259    # 工单号严格按云效卡片来

# === 2. 本地开发 + 自测 ===
# ... 写代码 ...

# === 3. commit（消息格式见上文）===
git add <具体文件>                      # 避免 git add . 误带入 .env / 大文件
git commit -m "feat: #ASAIO-259 将space和item转换为多对多的关系"

# === 4. push 到远端 feature 分支 ===
git push -u origin feature/ASAIO-259    # 首次 push 加 -u

# === 5. dev 环境自测：合入 develop ===
# 团队没强制走 Codeup MR，两种做法都行：
#   A) 在 Codeup 网页发"合并请求"，指派给 Owner 评审、Owner 合入（规范推荐）
#   B) 本地操作并通知 Owner（团队实际灵活做法）
# 合入后由各模块部署到 dev 环境

# === 6. dev 自测通过 → 合入 release（fat 环境）===
git checkout release
git pull origin release
git merge feature/ASAIO-259
git push origin release
# 此步无需审核，发布 fat 后通知 QA

# === 7. fat 发现 bug ===
# 方式 A：从 release 拉 bugfix 分支（命名同 feature）
git checkout release
git checkout -b bugfix/ASAIO-301
# ...改完...
git commit -m "fix: #ASAIO-301 修复 xxx"
git push -u origin bugfix/ASAIO-301
# 合回 release
# 方式 B：确认一把过的小修复，可直接在 release 改完 push

# === 8. release 测试完成 → 通知 QA，QA 通知余晨合并 master ===
# 余晨：git checkout master; git merge release; git push origin master
# 聂淮生：发 UAT
```

## Hotfix 流程（线上严重缺陷）

```bash
# 由余晨发起
git checkout master
git pull origin master
git checkout -b hotfix/ASAIO-400
# 修复 + 验证
git commit -m "fix: #ASAIO-400 紧急修复线上 xxx"
git push -u origin hotfix/ASAIO-400
# 修复发布生产后，**两边都要合**：
git checkout master  && git merge hotfix/ASAIO-400 && git push
git checkout develop && git merge hotfix/ASAIO-400 && git push
```

## test-mng 项目特殊性（必读）

1. **前后端是两个独立 git 仓库**
   - `test-mng-service/.git`（后端）、`test-mng-web/.git`（前端）
   - 根目录 `git status` / `git log` **无意义**，必须 `cd` 到子目录
   - 一个需求同时改前后端 → 两个仓库各拉一条 `feature/ASAIO-XXX`，commit message 都带同一个工单号

2. **托管在阿里云 Codeup，不是 GitHub**
   - `gh` CLI 不可用，**不要**执行 `gh pr create` 等命令
   - 需要发 PR → 引导用户去 Codeup 网页"合并请求"页面
   - 团队没强制走 MR；规范上 develop 合入要 Owner 评审，实际操作中 Owner 本地直 merge + push 也接受

3. **不要乱碰 release/master**
   - 不能未经允许把 feature 直接合到 master
   - master ← release 的合并是余晨的工作，**不要替他做**
   - 涉及向 release/master push 前，先和用户确认

## 版本号规则（顺带提一句）

`V{主}.{特性}.{缺陷}.{发布时间MMDD}`，示例：`V1.12.31.1220`

- 主 + 特性版本号 由迭代设置定（云效 Sprint 卡片上写）
- 缺陷版本号 每周发布递增
- 时间版本号 取最终发布日期（如 12 月 20 日 → `1220`）

> ⚠️ 版本号只用于发布标识（部署、tag、云效记录），**不进入分支名**。`release` 是固定分支，**不要**写成 `release/v0.4` / `release/v1.12.31` 之类的形式。

## 不该做的事

- ❌ `git push --force` 到 develop / release / master（除非用户明确要求并知晓后果）
- ❌ `git commit --no-verify` 跳过 hook（除非用户明确要求）
- ❌ 替余晨/聂淮生执行 release → master、UAT 发布等操作
- ❌ 在根目录运行 `git` 命令（无效，要进子仓库）
- ❌ 生造工单号；没工单先让用户去云效补
- ❌ commit 时 `git add .` / `git add -A`（用具体文件路径，避免 .env、临时文件被带入）

## 速查：用户常见问题对应做法

| 用户说 | 你该做的 |
|--------|---------|
| "我要开发 ASAIO-259" | `cd` 进对应子仓 → 从 develop 拉 `feature/ASAIO-259` |
| "帮我提交一下" | 检查改动 → 写符合 `<type>: #ASAIO-xxx 说明` 格式的 message → 让用户确认后再 commit |
| "推上去" | `git push -u origin <当前分支名>`；如果是 develop/release/master，**先停下来确认** |
| "合到 develop" | 说明需 Owner 评审（后端找余晨 / 前端找段忠志或余晨），引导走 Codeup MR |
| "发 fat" | 合到 `release` 分支（固定名，**不是** `release/vX.Y`），无需审核，push 后通知 QA |
| "线上挂了/紧急修一下" | 提示按 hotfix 流程走，且这是**余晨**的事，从 master 拉 `hotfix/ASAIO-XXX` |
| "fat 上有 bug" | 从 `release` 拉 `bugfix/ASAIO-XXX`；小修复也可直接在 release 上改 |
| 没工单号但想提交 | 停下，请用户去云效让陈霁/扬帆/聂淮生/小杨/余晨 之一补建需求卡片 |
