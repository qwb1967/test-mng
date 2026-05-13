---
name: git-flow
description: test-mng 项目分支管理、commit、push、合并发布的操作指南。基于团队《研发迭代规范》(Git-Flow 模型)，覆盖 feature/develop/release/master/hotfix 全流程，含分支命名、commit message 格式、各仓库 Owner、与环境映射、Codeup PR 流程。用户提到"建分支 / 提交 / push / 合并 / 发 dev/fat/uat / 线上修复 / 工单 ASAIO-xxx"时触发。
---

# git-flow — test-mng 分支管理 & 提交 & 发布操作指南

> 📌 团队采用 **Git-Flow** 分支模型，配套云效工单 + Codeup 仓库（**不是** GitHub，`gh` CLI 不可用）。
> 📌 test-mng 是聚合 monorepo，但 `test-mng-service/` 和 `test-mng-web/` **各自有独立 .git**，操作时务必先 `cd` 到对应子目录。

## 何时触发

用户出现以下意图时调用本 skill：

- "新需求开始开发了 / 帮我建个分支 / 拉 feature 分支"
- "这次 commit message 怎么写 / 帮我提交"
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
| `release` | 版本发布 | **fat** | 例 `release/v0.4` | develop 自测通过 → 自行合入，**无需审核** |
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

# === 6. dev 自测通过 → 合入对应版本的 release（fat 环境）===
git checkout release/v0.4
git pull origin release/v0.4
git merge feature/ASAIO-259
git push origin release/v0.4
# 此步无需审核，发布 fat 后通知 QA

# === 7. fat 发现 bug ===
# 方式 A：从 release 拉 bugfix 分支（命名同 feature）
git checkout release/v0.4
git checkout -b bugfix/ASAIO-301
# ...改完...
git commit -m "fix: #ASAIO-301 修复 xxx"
git push -u origin bugfix/ASAIO-301
# 合回 release
# 方式 B：确认一把过的小修复，可直接在 release 改完 push

# === 8. release 测试完成 → 通知 QA，QA 通知余晨合并 master ===
# 余晨：git checkout master; git merge release/v0.4; git push origin master
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
| "发 fat" | 合到对应 `release/vX.Y` 分支（无需审核），push 后通知 QA |
| "线上挂了/紧急修一下" | 提示按 hotfix 流程走，且这是**余晨**的事，从 master 拉 `hotfix/ASAIO-XXX` |
| "fat 上有 bug" | 从 `release` 拉 `bugfix/ASAIO-XXX`；小修复也可直接在 release 上改 |
| 没工单号但想提交 | 停下，请用户去云效让陈霁/扬帆/聂淮生/小杨/余晨 之一补建需求卡片 |
