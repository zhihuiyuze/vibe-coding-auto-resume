# vibe-coding-auto-resume

自动恢复 Claude Code 长任务：hit 5 小时 rate limit 或 weekly limit 后自动续接，无需手动盯 reset 时间，专为 vibe coding、长 agentic loop、SSH 远程开发场景设计。

[English](README.md) | [***中文***](README.zh.md) | [Français](README.fr.md) | [Русский](README.ru.md)

## 问题背景

如果你真的在用 Claude Code (`claude`) 跑活——长 agentic 任务、几小时的重构、SSH 上的 vibe coding——迟早会撞墙：

- 5 小时 rate limit 窗口会在任务中段切断。你得记住 reset 时间然后手动 `claude --continue`。
- Weekly limit 同样麻烦，只是周期更长。
- SSH 一断进程直接死。吃完午饭回来，session 没了。
- 没有内置方式看当前 block 烧了多少。
- 已有的依赖文案 regex 的 wrapper（比如 terryso/claude-auto-resume）在 Claude 改 TUI 文案后立刻坏掉。

`vibe-coding-auto-resume` 是一组小巧的 bash 脚本，在不引入重型依赖的前提下解决以上所有问题。

## 这个工具做什么

- **把 `claude` 跑在 tmux 里**，SSH 掉线、关终端、笔记本休眠都不会杀掉 session。
- **三层 rate limit 检测**：L1 解析 `~/.claude/projects/*.jsonl` 算用量；L2 用 regex 抓 tmux pane 里的 verbatim TUI 文案；L3 可选 LLM 精判（应对文案变化和边缘 case）。
- **Reset 后自动续接**：sleep 到抽到的 reset 时间 + 小 buffer，然后用 `claude --resume <session-uuid>`（优选，保留 cache）或 `claude --continue`（fallback）重启。
- **自动捕获 session UUID**：后台监听 JSONL 目录的新文件，resume 精确命中原 session，避开 `--continue` 的 cache 失效 bug。
- **`HANDOFF.md` 续接文件**：跨 session 上下文即使完全重启也不丢。
- **L1+L2 零外部依赖**（只需 `bash`、`jq`、`tmux`、`curl`）。L3 默认关闭，需手动 opt-in。

后台软上限监控 daemon（v2）——在接近限额时主动提示 Claude checkpoint 进度——**已规划但暂未实现**。

## 安装

```bash
git clone https://github.com/zhihuiyuze/vibe-coding-auto-resume.git ~/dev/claude-auto-continue
cd ~/dev/claude-auto-continue
./install.sh
sudo apt install tmux  # 如未装
source ~/.bashrc
```

安装脚本幂等：把 `vibe-run` 和 `vibe-session-capture` 软链到 `~/.local/bin/`，往 `~/.tmux.conf` 追加一小段 tmux 配置，往 `~/.bashrc` 追加 `vibe work` 函数。不会动 `~/.claude/` 下任何文件。

## 日常用法

典型工作流：

```bash
vibe work            # 进入名为 "claude" 的 tmux session，cwd 是你的项目
vibe-run      # 用它替代 `claude`——参数一致，行为一致
# Ctrl+b d 离开。SSH 可以断；session 继续跑。
# 之后：再 vibe work 即可重新 attach。
```

当 `claude` 因 rate limit 退出时，`vibe-run` 抽出 reset 时间，sleep 到点（+60s pad），然后用原 session UUID 续接。当 `claude` 正常退出或遇到真错误时，wrapper 用同样的 exit code 退出——**不**会瞎重试。

## L3 LLM 可选启用

L1（JSONL 解析）和 L2（pane regex）在常见场景下零外部调用就够用。如果想更稳地应对 TUI 文案变化、抽 L2 regex 抓不到的 reset 时间，可以 opt-in L3 LLM 精判。

支持的 provider：

- **DeepSeek**（`DEEPSEEK_API_KEY`，model `deepseek-chat`）——最便宜
- **Anthropic Claude**（`ANTHROPIC_API_KEY`，model `claude-haiku-4-5`）
- **OpenAI**（`OPENAI_API_KEY`，model `gpt-4o-mini`）
- **Ollama**（本地，`OLLAMA_HOST`）——接口已实现，当前 `[untested]`，等 GPU 环境验证

启用方式：

```bash
export DEEPSEEK_API_KEY=sk-...   # 加进 ~/.bashrc 持久化
./install.sh                     # 重跑；检测到 key 后会提示 opt-in
source ~/.bashrc
```

**隐私说明**：L3 启用后，tmux pane 末尾约 30 行（对话尾、文件预览）会被发到所选 provider 做分类。默认开启基础脱敏（`sk-*`、`Bearer *`、`*_SECRET=*`、长 base64），但**不保证**全覆盖。如果 pane 里有你不想贴进该 provider 聊天界面的内容，就不要启用 L3。即使设了 API key，opt-in 时选 no 也能继续走 L1+L2 模式。

## 检测原理（TL;DR）

三层按顺序工作。**L1** 持续算当前 5 小时 block 烧了多少——sum 当前项目 JSONL 里的 `message.usage.{input,output,cache_read}_tokens`，驱动 pre-flight 软上限拒绝。**L2** 在 `claude` 退出时跑 `tmux capture-pane`，grep 尾部的 verbatim 限额文案（`5-hour limit reached ∙ resets ...`、`weekly limit reached`、`Approaching 5-hour limit`），并抽出 reset 时间。**L3**（如启用）把同样的 pane 尾部发给 LLM，拿到结构化 `{status, reset_time, idle, modal_open}` JSON，处理 L2 解析不了的情况。

完整动机见 [`docs/architecture.md`](docs/architecture.md) 和 [`docs/design/001-three-layer-detection.md`](docs/design/001-three-layer-detection.md)。

## 环境变量

| 变量 | 默认值 | 用途 |
|---|---|---|
| `CC_LLM_PROVIDER` | 自动探测，或 `none` | 选 L3 provider（`deepseek` / `claude` / `openai` / `ollama` / `none`）。`none` 强制只走 L1+L2，即使有 key。 |
| `CC_USAGE_THRESHOLD` | `0.75` | 软上限比例。Pre-flight 在超过此值时拒绝起新 query。 |
| `CC_RESUME_MODE` | `auto` | `auto` = 先 `--resume <sid>`，失败 fallback `--continue`。`session-id` = 严格 UUID。`continue` = 总走 `--continue`。 |
| `CC_RESUME_MAX_CYCLES` | `1` | 每次 wrapper 调用允许多少次自动续接（`0` = 无限）。 |
| `CC_COMPACTION_CHOICE` | `keep` | resume 后偶尔出现的 context-过大 compaction prompt：`keep`（保留完整上下文）或 `compact`（让 Claude 自动总结）。 |

其他不常用的开关（`CC_SLEEP_PAD`、`CC_LLM_REDACT`、`CC_PANE_TAIL_LINES`、`CC_PEAK_FALLBACK`、`CC_SESSION_FILE`、`CC_LLM_MODEL`）在 `bin/vibe-run` 文件头部有注释。

## 参与贡献

先读 [`AGENTS.md`](AGENTS.md)——它是贡献者的唯一入口。本项目用 **spec-first 工作流**：每个 feature 先写设计文档 `docs/design/00X-<name>.md`（模板在 [`docs/design/README.md`](docs/design/README.md)），评审通过再写代码。小修小补和 bug fix 可直接提 PR。

特别欢迎补 TUI 样本：如果 Claude Code 哪天吐出我们还没匹配到的限额或 modal 文案，verbatim 贴到 `tests/fixtures/<name>.txt` 然后开 PR。

## License

MIT。
